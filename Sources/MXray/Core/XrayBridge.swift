//
//  XrayBridge.swift
//  MXray
//
//  Copyright 2026 Moein
//  SPDX-License-Identifier: Apache-2.0
//
//  Bridges NEPacketTunnelFlow ↔ Xray's built-in gVisor `tun` inbound.
//  Xray is configured with a "tun" protocol inbound whose fd is one end of a
//  SOCK_STREAM socketpair. No hev or SOCKS5 layer is involved.
//
//  Data flow:
//    packetFlow.readPackets → [4-byte AF header][IP packet] → socketpair fd[1]
//        → fd[0] → Xray gVisor → outbound proxy → remote
//    remote → outbound proxy → Xray gVisor → fd[0]
//        → fd[1] recv → [4-byte AF header][IP packet] → packetFlow.writePackets
//

import Foundation
@preconcurrency import NetworkExtension
import Darwin
import os

/// Bridges an `NEPacketTunnelFlow` to a running Xray instance's `tun` inbound.
///
/// Create one per session, call ``start(config:dataDir:finalConfigPath:sniffing:preset:configTransform:)``
/// to bring the tunnel up, and ``stop()`` to tear it down.
public final class XrayBridge {

    /// Link MTU handed to Xray's gVisor `tun` inbound.
    ///
    /// This MUST match the MTU the host sets on `NEPacketTunnelNetworkSettings`. gVisor sizes the
    /// segments it writes toward the app from this value, and `writePackets` cannot deliver a
    /// packet larger than the utun interface MTU — it is dropped with no error and no ICMP. When
    /// this reads high, small responses still fit and large ones vanish, which looks like "chat
    /// apps work but images and video never load".
    public var tunMTU: Int = 1500

    /// Called when a packet path stops carrying traffic for good, with a human-readable reason.
    ///
    /// Both directions are framed as `[4-byte AF][IP packet]` over a SOCK_STREAM socketpair, and a
    /// stream socket has no delimiter to resynchronise on: one truncated frame or one hard socket
    /// error and every following byte is misread. The reader cannot recover from that, so it stops.
    ///
    /// The failure this reports is invisible from the outside, which is what makes it worth
    /// reporting. Xray keeps running, the uplink keeps accepting packets, `NEVPNStatus` stays
    /// `.connected` — the tunnel just never delivers another byte to the app. On screen that is a
    /// video frozen on its first frame, a feed stuck half-loaded, a page that never finishes:
    /// whatever had already arrived stays, and nothing new does.
    ///
    /// Handle it by tearing the tunnel down and reconnecting; nothing can repair the framing in
    /// place. The callback runs on the reader thread.
    public var onPacketPathFailure: ((String) -> Void)?

    private static let bridgeLog = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "MXray.XrayBridge",
        category: "XrayBridge"
    )

    private weak var packetFlow: NEPacketTunnelFlow?
    private var swiftFd: Int32 = -1
    private var xrayFd: Int32 = -1
    private var isRunning = false

    private let statsLock = NSLock()
    private var _bytesReceived: Int64 = 0
    private var _bytesSent: Int64 = 0
    private var udp443RejectLogCount = 0

    /// Drops every UDP/443 packet and answers with an ICMP port-unreachable, so QUIC-first
    /// clients fall back to TCP.
    ///
    /// This is a hard block that happens before Xray sees the packet, so no routing rule can
    /// undo it. It costs QUIC everywhere — a real difference from clients that carry UDP — so
    /// most sessions should leave it off. It exists for environments where a QUIC stream that
    /// connects but never delivers data leaves the app wedged (e.g. a non-dismissible fullscreen
    /// web view), where forcing TCP fallback is the lesser evil.
    public var rejectsUDP443: Bool = false

    public init(packetFlow: NEPacketTunnelFlow) {
        self.packetFlow = packetFlow
    }

    deinit {
        if xrayFd >= 0 { Darwin.close(xrayFd) }
        if swiftFd >= 0 { Darwin.close(swiftFd) }
    }

    /// Starts Xray, building the final config from `config`.
    ///
    /// - Parameters:
    ///   - config: The outbound configuration, as JSON or a share link.
    ///   - dataDir: Directory containing `geoip.dat` / `geosite.dat`.
    ///   - finalConfigPath: Where MXray writes the fully-assembled config it hands to Xray.
    ///   - sniffing: Optional sniffing options for the injected `tun` inbound.
    ///   - preset: Runtime tuning applied before Xray starts.
    ///   - configTransform: Optional last-mile hook to mutate the assembled config dictionary.
    public func start(
        config: XrayConfiguration,
        dataDir: URL,
        finalConfigPath: URL,
        sniffing: SniffingConfiguration? = nil,
        preset: XrayTuningPreset = .default,
        configTransform: (([String: Any]) -> [String: Any])? = nil
    ) throws {
        let json: String
        switch config {
        case .json(let s): json = s
        case .url(let link): json = try XrayCore.shareLinkToJSON(url: link)
        }
        try openSocketPairAndApplyPreset(preset)
        var dict = try buildConfigDict(json: json, sniffing: sniffing)
        if let transform = configTransform { dict = transform(dict) }
        try writeAndRun(dict: dict, dataDir: dataDir, finalConfigPath: finalConfigPath)
    }

    /// Starts Xray with a fully pre-built config file — no inbound patching applied.
    public func startWithRawConfig(
        rawConfigPath: URL,
        dataDir: URL,
        preset: XrayTuningPreset = .default
    ) throws {
        try openSocketPairAndApplyPreset(preset)
        try XrayCore.run(dataDir: dataDir.path, configPath: rawConfigPath.path)
        isRunning = true
        launchReadThread(fd: swiftFd)
        readFromPacketFlow()
    }

    /// Returns the config dictionary that `start(config:…)` would produce, without running Xray.
    public func buildConfig(
        config: XrayConfiguration,
        sniffing: SniffingConfiguration? = nil,
        configTransform: (([String: Any]) -> [String: Any])? = nil
    ) throws -> [String: Any] {
        let json: String
        switch config {
        case .json(let s): json = s
        case .url(let link): json = try XrayCore.shareLinkToJSON(url: link)
        }
        var dict = try buildConfigDict(json: json, sniffing: sniffing)
        if let transform = configTransform { dict = transform(dict) }
        return dict
    }

    /// Stops Xray and closes the socketpair.
    public func stop() {
        isRunning = false
        let x = xrayFd, s = swiftFd
        xrayFd = -1
        swiftFd = -1
        if x >= 0 { Darwin.close(x) }
        if s >= 0 { Darwin.close(s) }
        try? XrayCore.stop()
    }

    /// Returns bytes transferred since the last call and resets the counters.
    public func getAndClearStats() -> BytesTransferred {
        statsLock.lock()
        let r = _bytesReceived
        let s = _bytesSent
        _bytesReceived = 0
        _bytesSent = 0
        statsLock.unlock()
        return BytesTransferred(received: max(0, r), sent: max(0, s))
    }

    // MARK: - Private

    private func openSocketPairAndApplyPreset(_ preset: XrayTuningPreset) throws {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw MXrayError.socketPairFailed
        }
        xrayFd = fds[0]
        swiftFd = fds[1]

        // A socketpair buffer is charged to the Network Extension process. This is deliberately
        // not 1 MiB, and no longer 128 KiB either: with the batched reader below the bridge drains
        // fast enough to use the headroom, and a queue this size keeps a burst from back-pressuring
        // gVisor mid-transfer.
        var bufSize: Int32 = 256 * 1024
        setsockopt(swiftFd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(swiftFd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(xrayFd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(xrayFd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))

        XrayCore.setTunFd(xrayFd)
        preset.apply()
    }

    private func buildConfigDict(json: String, sniffing: SniffingConfiguration?) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              var config = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MXrayError.invalidConfig
        }
        var inbound: [String: Any] = [
            "protocol": "tun",
            "settings": ["name": "utun", "MTU": tunMTU],
            "tag": "in_proxy"
        ]
        if let sniffing {
            inbound["sniffing"] = [
                "destOverride": sniffing.destOverride,
                "enabled": sniffing.enabled,
                "routeOnly": sniffing.routeOnly,
                "metadataOnly": sniffing.metadataOnly,
                "domainsExcluded": sniffing.domainsExcluded
            ]
        }
        config["inbounds"] = [inbound]
        return config
    }

    private func writeAndRun(dict: [String: Any], dataDir: URL, finalConfigPath: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted)
        let json = String(decoding: data, as: UTF8.self)
        try json.write(to: finalConfigPath, atomically: true, encoding: .utf8)
        try XrayCore.run(dataDir: dataDir.path, configPath: finalConfigPath.path)
        isRunning = true
        launchReadThread(fd: swiftFd)
        readFromPacketFlow()
    }

    // MARK: - Packet I/O threads

    /// Staging buffer for the downlink reader. Sized so several full-MTU frames — or one
    /// maximum-size frame — always fit, which is what lets a single `recv` pick up a burst.
    private static let downlinkBufferBytes = 256 * 1024

    /// Packets handed to `writePackets` in one call. Batching is the whole point: `writePackets`
    /// takes an array because it is a boundary crossing, not a cheap call.
    private static let maxPacketsPerBatch = 64

    private func launchReadThread(fd: Int32) {
        guard let flow = packetFlow else { return }
        let pump = DownlinkPump(
            fd: fd,
            flow: flow,
            capacity: Self.downlinkBufferBytes,
            maxPacketsPerBatch: Self.maxPacketsPerBatch
        )
        Thread.detachNewThread { [weak self] in
            var deliveredTotal: Int64 = 0
            let stop = pump.run { delivered in
                deliveredTotal += delivered
                guard let self else { return }
                self.statsLock.lock()
                self._bytesReceived += delivered
                self.statsLock.unlock()
            }
            guard let self else { return }
            let reason = "downlink reader stopped: \(stop.description) afterBytes=\(deliveredTotal)"
            os_log("%{public}@", log: Self.bridgeLog, type: .error, reason)
            // Only a clean EOF is expected here, and only while tearing the tunnel down.
            if case .endOfStream = stop, !self.isRunning { return }
            self.onPacketPathFailure?(reason)
        }
    }

    private func readFromPacketFlow() {
        guard isRunning, let packetFlow else { return }
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self, self.isRunning, self.swiftFd >= 0 else { return }
            autoreleasepool {
                let fd = self.swiftFd

                // `readPackets` already hands us a batch, so the framing for the whole batch is
                // assembled into one buffer and pushed with a single write.
                var frame = [UInt8]()
                var rejects: [Data] = []
                var sentBytes: Int64 = 0
                frame.reserveCapacity(packets.reduce(0) { $0 + $1.count + 4 })

                for (packet, proto) in zip(packets, protocols) {
                    if let reject = self.makeIPv4UDP443PortUnreachable(for: packet, addressFamily: proto.uint32Value) {
                        self.logUDP443RejectIfNeeded()
                        rejects.append(reject)
                        continue
                    }

                    let af = proto.uint32Value
                    frame.append(UInt8((af >> 24) & 0xff))
                    frame.append(UInt8((af >> 16) & 0xff))
                    frame.append(UInt8((af >> 8) & 0xff))
                    frame.append(UInt8(af & 0xff))
                    frame.append(contentsOf: packet)
                    sentBytes += Int64(packet.count)
                }

                if !rejects.isEmpty {
                    packetFlow.writePackets(
                        rejects,
                        withProtocols: Array(repeating: NSNumber(value: AF_INET), count: rejects.count)
                    )
                }

                if !frame.isEmpty {
                    // A stream socket may accept less than the whole buffer, and a short write here
                    // would desynchronise the framing the reader on the Xray side depends on — so
                    // keep going until it is all in.
                    var writeFailure: String?
                    frame.withUnsafeBytes { raw in
                        guard let base = raw.baseAddress else { return }
                        var written = 0
                        while written < raw.count {
                            let n = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                            if n > 0 {
                                written += n
                            } else if n < 0 && (errno == EINTR || errno == EAGAIN) {
                                continue
                            } else {
                                // Giving up mid-buffer leaves a partial frame in the stream, and
                                // Xray's reader has no delimiter to resynchronise on either — from
                                // here on it misreads every packet the device sends. Nothing can
                                // repair that in place, so report it rather than let the tunnel
                                // carry on looking connected.
                                writeFailure = "uplink write failed: errno=\(errno) written=\(written)/\(raw.count)"
                                break
                            }
                        }
                    }

                    if let writeFailure {
                        os_log("%{public}@", log: Self.bridgeLog, type: .error, writeFailure)
                        self.onPacketPathFailure?(writeFailure)
                    }

                    self.statsLock.lock()
                    self._bytesSent += sentBytes
                    self.statsLock.unlock()
                }
            }
            self.readFromPacketFlow()
        }
    }

    private func logUDP443RejectIfNeeded() {
        statsLock.lock()
        defer { statsLock.unlock() }

        guard udp443RejectLogCount < 5 else { return }
        udp443RejectLogCount += 1
        let line = "[XrayBridge] UDP/443 rejected with ICMP port-unreachable to force TCP fallback count=\(udp443RejectLogCount)"
        os_log("%{public}@", log: Self.bridgeLog, type: .default, line)
    }

    private func makeIPv4UDP443PortUnreachable(for packet: Data, addressFamily: UInt32) -> Data? {
        guard rejectsUDP443,
              addressFamily == UInt32(AF_INET),
              packet.count >= 28,
              packet[0] >> 4 == 4 else {
            return nil
        }

        let ipHeaderLength = Int(packet[0] & 0x0f) * 4
        guard ipHeaderLength >= 20,
              packet.count >= ipHeaderLength + 8,
              packet[9] == UInt8(IPPROTO_UDP) else {
            return nil
        }

        let destinationPortOffset = ipHeaderLength + 2
        let destinationPort = (UInt16(packet[destinationPortOffset]) << 8) | UInt16(packet[destinationPortOffset + 1])
        guard destinationPort == 443 else { return nil }

        let quotedLength = ipHeaderLength + 8
        let icmpLength = 8 + quotedLength
        let responseLength = 20 + icmpLength
        var response = Data(repeating: 0, count: responseLength)

        response[0] = 0x45
        response[1] = 0
        writeUInt16(UInt16(responseLength), to: &response, at: 2)
        writeUInt16(0, to: &response, at: 4)
        writeUInt16(0, to: &response, at: 6)
        response[8] = 64
        response[9] = UInt8(IPPROTO_ICMP)
        response[12] = packet[16]
        response[13] = packet[17]
        response[14] = packet[18]
        response[15] = packet[19]
        response[16] = packet[12]
        response[17] = packet[13]
        response[18] = packet[14]
        response[19] = packet[15]

        response[20] = 3
        response[21] = 3
        response.replaceSubrange(28..<(28 + quotedLength), with: packet.prefix(quotedLength))

        let icmpChecksum = internetChecksum(response, range: 20..<responseLength)
        writeUInt16(icmpChecksum, to: &response, at: 22)

        let ipChecksum = internetChecksum(response, range: 0..<20)
        writeUInt16(ipChecksum, to: &response, at: 10)

        return response
    }

    private func writeUInt16(_ value: UInt16, to data: inout Data, at offset: Int) {
        data[offset] = UInt8((value >> 8) & 0xff)
        data[offset + 1] = UInt8(value & 0xff)
    }

    private func internetChecksum(_ data: Data, range: Range<Int>) -> UInt16 {
        var sum: UInt32 = 0
        var index = range.lowerBound

        while index + 1 < range.upperBound {
            sum += (UInt32(data[index]) << 8) | UInt32(data[index + 1])
            index += 2
        }

        if index < range.upperBound {
            sum += UInt32(data[index]) << 8
        }

        while (sum >> 16) != 0 {
            sum = (sum & 0xffff) + (sum >> 16)
        }

        return UInt16(~sum & 0xffff)
    }
}

/// Drains Xray's side of the socketpair and delivers packets to the tunnel in batches.
///
/// The framing on the wire is `[4-byte big-endian address family][IP packet]`, repeated, over a
/// SOCK_STREAM socket — so frames are not aligned to reads. This holds partial-frame state between
/// reads, which is what makes it possible to pick a burst up with a single `recv` instead of the
/// two or three blocking reads per packet a naive reader needs.
private final class DownlinkPump {
    private let fd: Int32
    private let flow: NEPacketTunnelFlow
    private let capacity: Int
    private let maxPacketsPerBatch: Int
    private let buf: UnsafeMutablePointer<UInt8>

    /// Bytes of valid data at the front of `buf`.
    private var filled = 0
    private var packets: [Data] = []
    private var protocols: [NSNumber] = []

    init(fd: Int32, flow: NEPacketTunnelFlow, capacity: Int, maxPacketsPerBatch: Int) {
        self.fd = fd
        self.flow = flow
        self.capacity = capacity
        self.maxPacketsPerBatch = maxPacketsPerBatch
        self.buf = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        packets.reserveCapacity(maxPacketsPerBatch)
        protocols.reserveCapacity(maxPacketsPerBatch)
    }

    deinit {
        buf.deallocate()
    }

    /// Why the reader stopped. Every case is terminal: the framing cannot be resynchronised.
    enum StopReason {
        /// The socket reported EOF — expected only while the tunnel is being torn down.
        case endOfStream
        /// A frame header that cannot be parsed, so every following byte is misaligned.
        case desynchronised(detail: String)
        /// `recv` failed with something other than EINTR/EAGAIN.
        case socketError(code: Int32)

        var description: String {
            switch self {
            case .endOfStream:
                return "end-of-stream"
            case .desynchronised(let detail):
                return "framing-desynchronised(\(detail))"
            case .socketError(let code):
                return "recv-failed(errno=\(code))"
            }
        }
    }

    func run(recordReceived: (Int64) -> Void) -> StopReason {
        while true {
            var stop: StopReason?
            autoreleasepool {
                stop = step(recordReceived: recordReceived)
            }
            if let stop { return stop }
        }
    }

    /// One pass: parse what is buffered, then either top up without blocking or park on the
    /// socket. Returns a reason once the stream has ended or desynchronised, nil to keep going.
    private func step(recordReceived: (Int64) -> Void) -> StopReason? {
        var offset = 0
        var consumed: Int64 = 0
        while packets.count < maxPacketsPerBatch {
            guard let length = frameLength(at: offset) else { break }
            guard length > 0 else {
                let af = addressFamily(at: offset)
                flush()
                return .desynchronised(detail: "af=\(af) offset=\(offset) filled=\(filled)")
            }
            packets.append(Data(bytes: buf + offset + 4, count: length - 4))
            protocols.append(NSNumber(value: addressFamily(at: offset)))
            consumed += Int64(length - 4)
            offset += length
        }

        if offset > 0 {
            filled -= offset
            if filled > 0 {
                memmove(buf, buf + offset, filled)
            }
            recordReceived(consumed)
        }

        if packets.count >= maxPacketsPerBatch {
            flush()
            return nil
        }

        // Nothing more can be parsed. Top the buffer up without blocking so a burst already sitting
        // in the socket joins this batch.
        if filled < capacity {
            let n = Darwin.recv(fd, buf + filled, capacity - filled, Int32(MSG_DONTWAIT))
            if n > 0 {
                filled += n
                return nil
            }
            if n == 0 {
                flush()
                return .endOfStream
            }
            let err = errno
            if err == EINTR {
                return nil
            }
            if err != EAGAIN && err != EWOULDBLOCK {
                flush()
                return .socketError(code: err)
            }
        }

        // The socket is drained: deliver what we have before parking on it.
        flush()

        // A frame is at most 4 + 65535 bytes, far below `capacity`, so a full buffer with nothing
        // parseable means the stream desynchronised and cannot be recovered.
        guard filled < capacity else {
            return .desynchronised(detail: "buffer-full-unparseable filled=\(filled)")
        }

        let n = Darwin.recv(fd, buf + filled, capacity - filled, 0)
        if n > 0 {
            filled += n
            return nil
        }
        if n == 0 {
            return .endOfStream
        }
        let err = errno
        return (err == EINTR || err == EAGAIN) ? nil : .socketError(code: err)
    }

    private func addressFamily(at offset: Int) -> UInt32 {
        (UInt32(buf[offset]) << 24) | (UInt32(buf[offset + 1]) << 16)
            | (UInt32(buf[offset + 2]) << 8) | UInt32(buf[offset + 3])
    }

    /// Length of the complete frame at `offset`, nil if more bytes are needed, or 0 for a frame
    /// that cannot be parsed at all — unrecoverable on a stream socket, since there is no delimiter
    /// to resynchronise on.
    private func frameLength(at offset: Int) -> Int? {
        guard filled - offset >= 4 else { return nil }
        let af = addressFamily(at: offset)
        let body = offset + 4

        if af == UInt32(AF_INET) {
            guard filled - body >= 20 else { return nil }
            let total = (Int(buf[body + 2]) << 8) | Int(buf[body + 3])
            guard total >= 20 else { return 0 }
            return filled - body >= total ? 4 + total : nil
        } else if af == UInt32(AF_INET6) {
            guard filled - body >= 40 else { return nil }
            let payload = (Int(buf[body + 4]) << 8) | Int(buf[body + 5])
            return filled - body >= 40 + payload ? 4 + 40 + payload : nil
        }
        return 0
    }

    private func flush() {
        guard !packets.isEmpty else { return }
        flow.writePackets(packets, withProtocols: protocols)
        packets.removeAll(keepingCapacity: true)
        protocols.removeAll(keepingCapacity: true)
    }
}
