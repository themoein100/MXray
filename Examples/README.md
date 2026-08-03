# MXray examples

Reference snippets you can copy into a real project. These files are **not** compiled by
the package — they document a typical two-target setup (app + Packet Tunnel extension).

## `PacketTunnelProvider.swift` — in your extension target

```swift
import MXray

/// The simplest possible provider: the app supplies the config, MXray does the rest.
final class PacketTunnelProvider: XrayPacketTunnelProvider {}
```

A customized provider:

```swift
import MXray
import NetworkExtension

final class PacketTunnelProvider: XrayPacketTunnelProvider {

    private let appGroup = "group.com.example.app"

    // Store geo files + config in the App Group the host app writes to.
    override var dataDirectory: URL {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)!
            .appendingPathComponent("xraydata", isDirectory: true)
    }

    override var sniffing: SniffingConfiguration? { .default }

    // Re-read the current server at connect time.
    override func resolveConfiguration(options: [String: NSObject]?) throws -> XrayConfiguration {
        let defaults = UserDefaults(suiteName: appGroup)
        guard let link = defaults?.string(forKey: "currentServer") else {
            throw MXrayError.tunnelSetupError("No server selected")
        }
        return .url(link)
    }
}
```

## App-side connection manager

```swift
import MXray
import NetworkExtension
import SwiftUI

@MainActor
final class VPNModel: ObservableObject {
    @Published var status: NEVPNStatus = .invalid
    @Published var received: Int64 = 0
    @Published var sent: Int64 = 0

    private let vpn = XrayTunnelController(
        tunnelBundleIdentifier: "com.example.app.tunnel",
        localizedDescription: "Example VPN"
    )

    init() {
        vpn.onStatusChange = { [weak self] in self?.status = $0 }
        Task { try? await vpn.prepare() }
    }

    func connect(link: String) async {
        do { try await vpn.connect(configuration: .url(link)) }
        catch { print("connect failed:", error) }
    }

    func disconnect() { vpn.disconnect() }

    func refreshStats() async {
        guard let usage = try? await vpn.stats() else { return }
        received += usage.received
        sent += usage.sent
    }
}
```

## Downloading geo files on first launch

```swift
let loader = GeoFilesLoader()
let container = FileManager.default
    .containerURL(forSecurityApplicationGroupIdentifier: "group.com.example.app")!
    .appendingPathComponent("xraydata", isDirectory: true)

try await loader.loadGeoFiles(into: container) { progress in
    print("geo:", Int(progress * 100), "%")
}
```
