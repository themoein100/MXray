//
//  XrayTunnelController.swift
//  MXray
//
//  SPDX-License-Identifier: Apache-2.0
//

#if canImport(NetworkExtension)
import Foundation
@preconcurrency import NetworkExtension

/// App-side controller that installs, connects, disconnects and queries an MXray tunnel.
///
/// This is the counterpart to ``XrayPacketTunnelProvider``: it lives in your **main app** and hides
/// the `NETunnelProviderManager` bookkeeping so connecting is a single call.
///
/// ```swift
/// import MXray
///
/// let vpn = XrayTunnelController(tunnelBundleIdentifier: "com.example.app.tunnel")
/// vpn.onStatusChange = { print("VPN status:", $0.rawValue) }
///
/// try await vpn.connect(configuration: .url("vless://…"))
/// let usage = try await vpn.stats()
/// vpn.disconnect()
/// ```
@MainActor
public final class XrayTunnelController {

    /// The bundle identifier of your Packet Tunnel extension target.
    public let tunnelBundleIdentifier: String

    /// The name shown for the VPN configuration in iOS Settings.
    public let localizedDescription: String

    /// Called on the main actor whenever the VPN connection status changes.
    public var onStatusChange: ((NEVPNStatus) -> Void)?

    private var manager: NETunnelProviderManager?
    private nonisolated(unsafe) var statusObserver: NSObjectProtocol?

    public init(tunnelBundleIdentifier: String, localizedDescription: String = "MXray VPN") {
        self.tunnelBundleIdentifier = tunnelBundleIdentifier
        self.localizedDescription = localizedDescription
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    /// The current VPN connection status, or `.invalid` before the manager is loaded.
    public var status: NEVPNStatus {
        manager?.connection.status ?? .invalid
    }

    /// Loads the existing MXray VPN configuration if one exists, so ``status`` and observation work
    /// before the first connect. Safe to call multiple times.
    public func prepare() async throws {
        _ = try await loadOrCreateManager()
    }

    /// Installs (if needed) and starts the tunnel with the given configuration.
    ///
    /// - Parameters:
    ///   - configuration: The Xray outbound config, as JSON or a share link.
    ///   - serverAddress: The address shown in the VPN configuration. Cosmetic — the real remote is
    ///     resolved by Xray from `configuration`.
    public func connect(configuration: XrayConfiguration, serverAddress: String = "MXray") async throws {
        let manager = try await loadOrCreateManager()

        let (value, kind): (String, String)
        switch configuration {
        case .json(let json): (value, kind) = (json, "json")
        case .url(let link):  (value, kind) = (link, "url")
        }

        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = tunnelBundleIdentifier
        proto.serverAddress = serverAddress
        proto.providerConfiguration = [
            XrayProviderKeys.config: value,
            XrayProviderKeys.configKind: kind
        ]
        manager.protocolConfiguration = proto
        manager.localizedDescription = localizedDescription
        manager.isEnabled = true

        // A save must be followed by a fresh load, or startVPNTunnel rejects the stale in-memory copy.
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()

        try manager.connection.startVPNTunnel(options: [
            XrayProviderKeys.config: value as NSString,
            XrayProviderKeys.configKind: kind as NSString
        ])
    }

    /// Stops the tunnel.
    public func disconnect() {
        manager?.connection.stopVPNTunnel()
    }

    /// Removes the MXray VPN configuration from the device.
    public func removeConfiguration() async throws {
        guard let manager else { return }
        try await manager.removeFromPreferences()
        self.manager = nil
    }

    /// Fetches traffic transferred since the previous call (the provider resets its counters).
    public func stats() async throws -> BytesTransferred {
        let response = try await send(.stats)
        if case .stats(let bytes) = response { return bytes }
        return BytesTransferred()
    }

    /// Fetches the running Xray-core version from the extension.
    public func xrayVersion() async throws -> String {
        let response = try await send(.xrayVersion)
        if case .xrayVersion(let version) = response { return version }
        return ""
    }

    // MARK: - Private

    private func send(_ request: TunnelRequest) async throws -> TunnelResponse {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            throw MXrayError.tunnelSetupError("Tunnel is not running")
        }
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(request.encoded()) { data in
                    let response = data.flatMap(TunnelResponse.decode) ?? .error("No response")
                    continuation.resume(returning: response)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
        if let manager { return manager }

        let all = try await NETunnelProviderManager.loadAllFromPreferences()
        let existing = all.first { manager in
            (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                == tunnelBundleIdentifier
        }

        let manager = existing ?? NETunnelProviderManager()
        self.manager = manager
        observeStatus(of: manager)
        return manager
    }

    private func observeStatus(of manager: NETunnelProviderManager) {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.onStatusChange?(self.status)
            }
        }
    }
}
#endif
