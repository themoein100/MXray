//
//  XrayPacketTunnelProvider.swift
//  MXray
//
//  Copyright 2026 Moein
//  SPDX-License-Identifier: Apache-2.0
//

#if canImport(NetworkExtension)
import Foundation
@preconcurrency import NetworkExtension
import os

/// Keys MXray uses inside `NETunnelProviderProtocol.providerConfiguration` and the
/// `startTunnel` options dictionary. The app-side ``XrayTunnelController`` sets these for you.
public enum XrayProviderKeys {
    /// The Xray configuration payload — either a JSON document or a share link.
    public static let config = "MXrayConfig"
    /// The kind of ``config``: `"json"` or `"url"`. Optional; auto-detected when absent.
    public static let configKind = "MXrayConfigKind"
}

/// A ready-to-use `NEPacketTunnelProvider` that runs Xray for you.
///
/// Subclass it in your Network Extension target and, in the simplest case, ship your app without
/// writing any tunnel plumbing at all — the config arrives from the host app via
/// ``XrayTunnelController``:
///
/// ```swift
/// import MXray
///
/// final class PacketTunnelProvider: XrayPacketTunnelProvider {}
/// ```
///
/// Every moving part is an overridable hook: ``tunnelSettings``, ``tuningPreset``, ``sniffing``,
/// ``dataDirectory``, ``resolveConfiguration(options:)`` and ``configTransform(_:)``.
open class XrayPacketTunnelProvider: NEPacketTunnelProvider {

    /// The live packet bridge for the current session, or `nil` when not connected.
    public private(set) var bridge: XrayBridge?

    private let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "MXray",
        category: "XrayPacketTunnelProvider"
    )

    // MARK: - Overridable configuration

    /// IP / DNS / MTU parameters for the tunnel interface. Defaults to full-tunnel.
    open var tunnelSettings: XrayTunnelSettings { .default }

    /// Xray runtime tuning. Defaults to `.mobile` on iOS, `.desktop` on macOS.
    open var tuningPreset: XrayTuningPreset { .default }

    /// Optional sniffing options for the injected `tun` inbound. Defaults to `nil`.
    open var sniffing: SniffingConfiguration? { nil }

    /// Directory used for geo files and the assembled config. Override to point at an App Group
    /// container if your host app pre-downloads geo files there. Defaults to the extension's own
    /// Application Support directory.
    open var dataDirectory: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("MXray", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Extra directories (e.g. an App Group container) to search for bundled geo files.
    open var additionalGeoSourceDirectories: [URL] { [] }

    /// Resolves the Xray configuration for this session.
    ///
    /// The default reads ``XrayProviderKeys/config`` from the `startTunnel` options first, then from
    /// `providerConfiguration`. Override to fetch a fresh config from your own store (subscription
    /// API, Keychain, disk, …).
    open func resolveConfiguration(options: [String: NSObject]?) throws -> XrayConfiguration {
        if let value = options?[XrayProviderKeys.config] as? String {
            return Self.makeConfiguration(from: value, kind: options?[XrayProviderKeys.configKind] as? String)
        }
        if let provider = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
           let value = provider[XrayProviderKeys.config] as? String {
            return Self.makeConfiguration(from: value, kind: provider[XrayProviderKeys.configKind] as? String)
        }
        throw MXrayError.tunnelSetupError("No Xray configuration was provided")
    }

    /// Last-mile hook to mutate the assembled Xray config dictionary before it is written. Default
    /// is a pass-through. Use it for routing tweaks — but keep any app-specific policy in your app.
    open func configTransform(_ dict: [String: Any]) -> [String: Any] { dict }

    // MARK: - Lifecycle

    open override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let dataDir = dataDirectory
        FileManager.default.changeCurrentDirectoryPath(dataDir.path)

        let configuration: XrayConfiguration
        do {
            configuration = try resolveConfiguration(options: options)
        } catch {
            os_log("startTunnel: %{public}@", log: log, type: .error, "\(error)")
            return completionHandler(error)
        }

        let settings = tunnelSettings
        setTunnelNetworkSettings(settings.makeNetworkSettings()) { [weak self] err in
            guard let self else { return completionHandler(nil) }
            if let err {
                os_log("setTunnelNetworkSettings failed: %{public}@", log: self.log, type: .error, "\(err)")
                return completionHandler(err)
            }

            // Bring Xray up off the network-settings callback thread so a slow start never stalls it.
            DispatchQueue.global(qos: .userInitiated).async {
                TunnelResourceInstaller(additionalSourceDirectories: self.additionalGeoSourceDirectories)
                    .installGeoFilesIfNeeded(into: dataDir)

                let bridge = XrayBridge(packetFlow: self.packetFlow)
                bridge.tunMTU = settings.mtu
                // A dead packet path cannot be repaired in place, and it does not look like a
                // failure from the outside: Xray stays up and the session stays `.connected` while
                // nothing is delivered. Ending the session is what lets iOS (or the user) start a
                // new one; subclasses that would rather reconnect can override `packetPathDidFail`.
                bridge.onPacketPathFailure = { [weak self] reason in
                    guard let self else { return }
                    os_log("packet path failed: %{public}@", log: self.log, type: .error, reason)
                    self.packetPathDidFail(reason: reason)
                }
                self.bridge = bridge

                do {
                    try bridge.start(
                        config: configuration,
                        dataDir: dataDir,
                        finalConfigPath: dataDir.appendingPathComponent("config_final.json"),
                        sniffing: self.sniffing,
                        preset: self.tuningPreset,
                        configTransform: { self.configTransform($0) }
                    )
                    os_log("Xray tunnel started", log: self.log, type: .info)
                    completionHandler(nil)
                } catch {
                    os_log("Xray start failed: %{public}@", log: self.log, type: .error, "\(error)")
                    self.bridge = nil
                    completionHandler(error)
                }
            }
        }
    }

    /// Called when a packet direction has stopped carrying traffic and cannot recover.
    ///
    /// The default ends the session with `.unrecoverableNetworkChange`, so the tunnel stops
    /// claiming to be connected. Override to reconnect instead, or to report it first — the
    /// bridge is already unusable by the time this runs, in either direction.
    open func packetPathDidFail(reason: String) {
        cancelTunnelWithError(MXrayError.packetPathFailed(reason))
    }

    open override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        os_log("stopTunnel reason=%{public}d", log: log, type: .info, reason.rawValue)
        bridge?.stop()
        bridge = nil
        completionHandler()
    }

    open override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let request = TunnelRequest.decode(messageData) else {
            completionHandler?(nil)
            return
        }
        switch request {
        case .stats:
            let stats = bridge?.getAndClearStats() ?? BytesTransferred()
            completionHandler?(TunnelResponse.stats(stats).encoded())
        case .xrayVersion:
            let version = (try? XrayCore.xrayVersion()) ?? ""
            completionHandler?(TunnelResponse.xrayVersion(version).encoded())
        }
    }

    // MARK: - Helpers

    static func makeConfiguration(from value: String, kind: String?) -> XrayConfiguration {
        switch kind?.lowercased() {
        case "json": return .json(value)
        case "url", "link", "sharelink": return .url(value)
        default:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return .json(value) }
            if trimmed.contains("://") { return .url(value) }
            return .json(value)
        }
    }
}
#endif
