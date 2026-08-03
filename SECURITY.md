# Security Policy

## Reporting a vulnerability

If you discover a security issue in MXray, please report it privately rather than
opening a public issue. Use GitHub's **"Report a vulnerability"** (Security → Advisories)
on this repository. You will receive an acknowledgement, and we ask that you give a
reasonable window for a fix before any public disclosure.

Please include:

- A description of the issue and its impact.
- Steps to reproduce or a proof of concept.
- The MXray version / commit and the platform (iOS / macOS version).

## Scope

MXray is a transport library: it wires the OS packet tunnel to Xray-core. Security
reports most relevant to this project include:

- Traffic leaking **outside** the tunnel (e.g. the device's real IP being exposed).
- Memory-safety issues in the packet bridge (`XrayBridge` / `DownlinkPump`).
- Configuration handling that could expose credentials.

Vulnerabilities in **Xray-core** itself should be reported upstream to
[XTLS/Xray-core](https://github.com/XTLS/Xray-core/security).

## Handling credentials and configuration

MXray never logs full configurations or credentials, and it does not transmit any
telemetry. A few things integrators should know:

- **Full-tunnel by default.** `XrayTunnelSettings.default` routes *all* traffic into
  the tunnel. Any excluded route reaches the network from the device's real IP —
  only narrow the routes if you understand that trade-off.
- **`providerConfiguration` is not a secret store.** Config passed through
  `NETunnelProviderProtocol.providerConfiguration` is persisted by the system in the
  VPN profile. This is the standard mechanism for NE VPNs, but treat it accordingly:
  don't put anything there you would not put in a saved VPN profile. For sensitive
  deployments, fetch the config at connect time by overriding
  `XrayPacketTunnelProvider.resolveConfiguration(options:)` and reading from the
  Keychain or a shared App Group instead.
- **Geo files are downloaded over HTTPS** from the URL you configure in
  `GeoFilesLoader`. Point it at a source you trust.

## What is intentionally *not* in this library

MXray is a clean transport core. It contains **no** analytics, ad-network logic,
session/time-limit policy, server lists, or embedded credentials. Any such policy
belongs in your application, not here.
