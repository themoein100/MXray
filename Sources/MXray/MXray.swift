//
//  MXray.swift
//  MXray
//
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation

/// The public entry point for MXray.
///
/// `MXray` groups the stateless, non-tunnel helpers — version lookup, share-link conversion,
/// free-port allocation and latency probing. To actually route traffic, subclass
/// ``XrayPacketTunnelProvider`` in your Network Extension, or drive ``XrayBridge`` directly.
///
/// ```swift
/// import MXray
///
/// let version = try MXray.xrayVersion()
/// let json    = try MXray.shareLinkToJSON("vless://…")
/// ```
public enum MXray {

    /// The MXray package version.
    public static let version = "1.0.0"

    /// Returns the bundled Xray-core version string.
    public static func xrayVersion() throws -> String {
        try XrayCore.xrayVersion()
    }

    /// Allocates `count` free local TCP ports.
    public static func freePorts(_ count: Int) throws -> [Int] {
        try XrayCore.getFreePorts(count)
    }

    /// Converts an Xray share link (`vless://`, `vmess://`, `trojan://`, `ss://`, …) to a JSON
    /// configuration string.
    public static func shareLinkToJSON(_ link: String) throws -> String {
        try XrayCore.shareLinkToJSON(url: link)
    }

    /// Measures latency by asking Xray to fetch `url` through `proxy`.
    ///
    /// - Parameters:
    ///   - configPath: Path to an Xray config that exposes a local proxy inbound.
    ///   - dataDir: Directory containing the geo files.
    ///   - timeout: Probe timeout in seconds.
    ///   - url: The URL to fetch (defaults to a Cloudflare 204 endpoint).
    ///   - proxy: The local proxy address to route the probe through (e.g. `socks5://127.0.0.1:10808`).
    /// - Returns: The probe result, including round-trip latency in milliseconds.
    public static func ping(
        configPath: URL,
        dataDir: URL,
        timeout: Int = 8,
        url: String = "https://cp.cloudflare.com/generate_204",
        proxy: String
    ) throws -> XrayPingResponse {
        try XrayCore.ping(
            dataDir: dataDir.path,
            configPath: configPath.path,
            timeout: timeout,
            url: url,
            proxy: proxy
        )
    }
}
