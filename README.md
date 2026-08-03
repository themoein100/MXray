<div align="center">

# MXray

**A batteries-included Swift package for building Xray-powered VPNs on iOS & macOS.**

Bring your own config, `import MXray`, and connect. The hard parts — the packet-tunnel
bridge, the memory budget that keeps a Network Extension alive, geo-file installation and
the app↔extension plumbing — are already solved inside.

[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2015%2B%20%7C%20macOS%2012%2B-blue.svg)](https://developer.apple.com)
[![License](https://img.shields.io/badge/License-Apache%202.0-lightgrey.svg)](LICENSE)

</div>

---

## Why MXray?

Building a VPN on Apple platforms with Xray-core normally means gluing together a static
Go library, a `NEPacketTunnelProvider`, a hand-rolled packet bridge, geo-file management,
and a fragile memory budget — and then discovering that the Network Extension gets killed
under load. MXray packages all of that into one dependency:

- **Add your config from anywhere** — a subscription server, a QR code, a pasted share
  link (`vless://`, `vmess://`, `trojan://`, `ss://`), or hand-written JSON.
- **Subclass one class** for the tunnel, **call one controller** from the app.
- **No iOS gotchas to relearn.** The gVisor `tun` bridge, batched packet I/O, the Go heap
  ceiling tuned for the NE memory limit, and the geo-copy that avoids startup memory spikes
  are baked in.
- **Nothing proprietary.** No analytics, no ad logic, no server lists, no time limits, no
  embedded credentials. Just the transport core.

## Features

| | |
|---|---|
| 🚀 **`XrayTunnelController`** | App-side connect / disconnect / status / live stats in a few lines. |
| 🧩 **`XrayPacketTunnelProvider`** | A ready `NEPacketTunnelProvider` base class — subclass and you're done. |
| 🔌 **`XrayBridge`** | The low-level `NEPacketTunnelFlow ↔ Xray gVisor tun` engine, if you want direct control. |
| 🧠 **`XrayTuningPreset`** | Memory/throughput presets tuned for the iOS NE limit (`.mobile`) and desktop (`.desktop`). |
| 🌍 **`GeoFilesLoader`** | Async, concurrent `geoip.dat` / `geosite.dat` downloads with progress. |
| 🛠 **`MXray` facade** | Xray version, share-link → JSON conversion, free-port allocation, latency ping. |

## Architecture

```
┌──────────────────────────── Your App ────────────────────────────┐
│  XrayTunnelController                                              │
│    .connect(configuration:)  .disconnect()  .stats()  .status     │
└───────────────┬───────────────────────────────────────────────────┘
                │  NETunnelProviderManager / sendProviderMessage
┌───────────────▼──────────── Your Network Extension ───────────────┐
│  final class PacketTunnelProvider: XrayPacketTunnelProvider {}     │
│    · resolves your config     · installs geo files                │
│    · applies tuning preset    · sets full-tunnel network settings │
│                                                                    │
│  XrayBridge  ── socketpair ──▶  Xray-core (LibXray.xcframework)    │
│    packetFlow.readPackets ─[AF header + IP packet]─▶ gVisor tun    │
│    packetFlow.writePackets ◀── batched downlink ◀── outbound proxy │
└────────────────────────────────────────────────────────────────────┘
```

## Requirements

- iOS 15+ / macOS 12+
- Xcode 16+ (Swift 6 toolchain)
- Your app must have the **Network Extensions** capability (Packet Tunnel) and an
  associated Packet Tunnel Provider extension target.

## Installation

### 1. Add the package

In Xcode: **File → Add Package Dependencies…** and enter the repository URL, or add it to
your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/themoein100/MXray.git", from: "1.0.0")
]
```

Add the `MXray` product to **both** your app target and your Packet Tunnel extension target.

### 2. Provide the `LibXray` binary

`LibXray.xcframework` is ~500 MB uncompressed — far above GitHub's 100 MB per-file limit —
so it is **not** committed to the repository. `Package.swift` expects it via a
`binaryTarget`. Two supported options:

- **Release (recommended):** the framework ships as a zipped GitHub Release asset and
  `Package.swift` references it with `.binaryTarget(url:checksum:)`. This is transparent to
  consumers — SwiftPM downloads it automatically.
- **Local development:** drop `LibXray.xcframework` into `Frameworks/` (git-ignored) and
  use the local `.binaryTarget(path:)`. See the comments at the top of `Package.swift`.

See [Cutting a release](#cutting-a-release) for how to produce the zip + checksum.

## Quick start

### Step 1 — The extension (one line)

In your Packet Tunnel extension target:

```swift
import MXray

final class PacketTunnelProvider: XrayPacketTunnelProvider {}
```

That's a complete, working provider. It reads the config the app hands it, installs geo
files, applies the `.mobile` tuning preset, sets full-tunnel routing, and starts Xray.

### Step 2 — The app

```swift
import MXray

let vpn = XrayTunnelController(tunnelBundleIdentifier: "com.example.app.tunnel")

vpn.onStatusChange = { status in
    print("VPN status:", status.rawValue)   // .connecting, .connected, .disconnected …
}

// Connect with a share link …
try await vpn.connect(configuration: .url("vless://uuid@host:443?...#MyServer"))

// … or with full JSON:
try await vpn.connect(configuration: .json(myXrayJSON))

// Live traffic counters (bytes since the last call):
let usage = try await vpn.stats()
print("↓ \(usage.received)  ↑ \(usage.sent)")

// Disconnect:
vpn.disconnect()
```

### Step 3 — Capabilities

In both targets, add the **Network Extensions** capability. For the extension, enable the
**Packet Tunnel** provider. If your app pre-downloads geo files for the extension, add an
**App Group** shared between the two targets and point the provider at it (see below).

## Customization

Every default is overridable. A more opinionated provider:

```swift
final class PacketTunnelProvider: XrayPacketTunnelProvider {

    // Fetch a fresh config at connect time instead of trusting the saved profile.
    override func resolveConfiguration(options: [String: NSObject]?) throws -> XrayConfiguration {
        let json = try MyKeychain.currentServerJSON()
        return .json(json)
    }

    // Route geo files from a shared App Group your app downloaded into.
    override var dataDirectory: URL {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.example.app")!
            .appendingPathComponent("xraydata")
    }

    // Tune the interface (defaults shown).
    override var tunnelSettings: XrayTunnelSettings {
        XrayTunnelSettings(dnsServers: ["1.1.1.1", "8.8.8.8"], mtu: 1400)
    }

    // Enable sniffing for domain-based routing rules.
    override var sniffing: SniffingConfiguration? { .default }
}
```

Downloading geo files from the app (e.g. on first launch):

```swift
let loader = GeoFilesLoader()
try await loader.loadGeoFiles(into: sharedContainerURL) { progress in
    print("geo files:", Int(progress * 100), "%")
}
```

Stateless helpers via the `MXray` facade:

```swift
let version = try MXray.xrayVersion()
let json    = try MXray.shareLinkToJSON("vless://…")
let ports   = try MXray.freePorts(2)
```

## Public API at a glance

| Type | Where it runs | Purpose |
|------|---------------|---------|
| `XrayTunnelController` | App | Install / connect / disconnect / status / stats. |
| `XrayPacketTunnelProvider` | Extension | Batteries-included `NEPacketTunnelProvider` base class. |
| `XrayBridge` | Extension | Low-level packet-flow ↔ Xray tun engine. |
| `XrayCore` | Both | Thin, direct wrapper over the LibXray C API. |
| `MXray` | Both | Stateless helpers (version, share-link, ports, ping). |
| `GeoFilesLoader` | App | Downloads `geoip.dat` / `geosite.dat`. |
| `XrayConfiguration` | Both | `.json(String)` or `.url(String)` config input. |
| `XrayTuningPreset` | Extension | `.mobile` / `.desktop` runtime tuning. |
| `XrayTunnelSettings` | Extension | IP / DNS / MTU / routing for the tunnel interface. |

## Cutting a release

Produce the binary asset and its checksum:

```bash
# From the folder containing LibXray.xcframework
ditto -c -k --sequesterRsrc --keepParent LibXray.xcframework LibXray.xcframework.zip
swift package compute-checksum LibXray.xcframework.zip
```

Upload `LibXray.xcframework.zip` to a GitHub Release, then switch `Package.swift` to the
`.binaryTarget(url:checksum:)` variant with that release URL and checksum.

## Security

Full-tunnel by default, no telemetry, no embedded secrets. See [SECURITY.md](SECURITY.md)
for the reporting process and important notes on how configuration and credentials are
handled.

## License

Copyright © 2026 Moein. MXray is licensed under the [Apache License 2.0](LICENSE).

It embeds and builds on third-party software — most importantly **Xray-core / LibXray**
(© XTLS, MIT). See [NOTICE](NOTICE) for full attribution. Vulnerabilities in Xray-core
itself should be reported to [XTLS/Xray-core](https://github.com/XTLS/Xray-core).
