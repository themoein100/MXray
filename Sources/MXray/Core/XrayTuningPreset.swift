//
//  XrayTuningPreset.swift
//  MXray
//
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation

/// A set of Xray runtime tuning parameters. Apply it (via `apply()`) before starting Xray.
///
/// The single knob that is actually enforced by the current Xray-core TUN package is the Go
/// heap soft ceiling (`memoryLimitMB`). The remaining fields document the intended per-session
/// resource budget for the policy layer of your Xray config; they are retained so a preset
/// fully describes the memory posture of a session.
public struct XrayTuningPreset: Sendable, Equatable {
    /// Go heap ceiling in MB (passed to `debug.SetMemoryLimit` inside Go).
    public var memoryLimitMB: Int
    /// Max TCP RX/TX buffer per connection in KB (documentation for the config policy layer).
    public var tcpBufMaxKB: Int
    /// Max concurrent TCP connections (documentation for the config policy layer).
    public var tcpMaxInFlight: Int
    /// Max concurrent UDP sessions (documentation for the config policy layer).
    public var udpMaxConns: Int
    /// Inbound idle timeout in seconds (documentation for the config policy layer).
    public var idleTimeoutSec: Int

    public init(
        memoryLimitMB: Int,
        tcpBufMaxKB: Int,
        tcpMaxInFlight: Int,
        udpMaxConns: Int,
        idleTimeoutSec: Int
    ) {
        self.memoryLimitMB = memoryLimitMB
        self.tcpBufMaxKB = tcpBufMaxKB
        self.tcpMaxInFlight = tcpMaxInFlight
        self.udpMaxConns = udpMaxConns
        self.idleTimeoutSec = idleTimeoutSec
    }

    /// Applies the enforceable tuning parameters via the Go-side API. Call before starting Xray.
    public func apply() {
        XrayCore.setMemoryLimitMB(Int64(memoryLimitMB))
    }
}

public extension XrayTuningPreset {
    /// Tuned for the memory-constrained iOS Network Extension environment.
    ///
    /// The Go heap ceiling is a *soft* GC target, not Apple's process limit — native and socket
    /// memory live outside it. It is deliberately set above Xray's real working set (TLS buffers +
    /// gVisor netstack + parsed geo tables): a soft target below the working set doesn't save
    /// memory, it just makes Go collect continuously and burn CPU in the packet path. The value
    /// leaves headroom for Swift, socket queues and native allocations that this figure never counts.
    static let mobile = XrayTuningPreset(
        memoryLimitMB: 36,
        tcpBufMaxKB: 32,
        tcpMaxInFlight: 16,
        udpMaxConns: 8,
        idleTimeoutSec: 20
    )

    /// Tuned for macOS / desktop, where memory pressure is not a concern.
    static let desktop = XrayTuningPreset(
        memoryLimitMB: 50,
        tcpBufMaxKB: 4096,
        tcpMaxInFlight: 8192,
        udpMaxConns: 4096,
        idleTimeoutSec: 300
    )

    /// Platform-adaptive: `.mobile` on iOS, `.desktop` on macOS.
    static var `default`: XrayTuningPreset {
        #if os(macOS)
        return .desktop
        #else
        return .mobile
        #endif
    }
}
