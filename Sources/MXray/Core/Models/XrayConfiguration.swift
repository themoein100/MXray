//
//  XrayConfiguration.swift
//  MXray
//
//  Copyright 2026 Moein
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation

/// How an Xray outbound configuration is supplied to MXray.
///
/// You can bring a config from anywhere — a subscription server, a QR code, a
/// pasted share link, or a fully hand-written JSON document.
public enum XrayConfiguration: Sendable, Equatable {
    /// A complete Xray JSON configuration string (at least the `outbounds` array).
    ///
    /// MXray injects its own `tun` inbound, so the `inbounds` you provide are replaced.
    case json(String)

    /// A share link (`vless://`, `vmess://`, `trojan://`, `ss://`, …) that MXray
    /// converts to JSON via LibXray before use.
    case url(String)
}

/// Traffic sniffing options passed to Xray's `tun` inbound.
public struct SniffingConfiguration: Codable, Sendable, Equatable {
    public let destOverride: [String]
    public let enabled: Bool
    public let routeOnly: Bool
    public let domainsExcluded: [String]
    public let metadataOnly: Bool

    public init(
        destOverride: [String],
        enabled: Bool,
        routeOnly: Bool,
        domainsExcluded: [String],
        metadataOnly: Bool
    ) {
        self.destOverride = destOverride
        self.enabled = enabled
        self.routeOnly = routeOnly
        self.domainsExcluded = domainsExcluded
        self.metadataOnly = metadataOnly
    }

    /// A sensible default: sniff HTTP/TLS/QUIC for routing without rewriting the destination.
    public static let `default` = SniffingConfiguration(
        destOverride: ["http", "tls", "quic"],
        enabled: true,
        routeOnly: true,
        domainsExcluded: [],
        metadataOnly: false
    )
}
