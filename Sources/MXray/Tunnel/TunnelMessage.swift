//
//  TunnelMessage.swift
//  MXray
//
//  Copyright 2026 Moein
//  SPDX-License-Identifier: Apache-2.0
//
//  A tiny request/response protocol carried over
//  `NETunnelProviderSession.sendProviderMessage`, so the host app can query the
//  running tunnel (traffic stats, Xray version) without its own IPC plumbing.
//

import Foundation

/// Requests the host app can send to a running ``XrayPacketTunnelProvider``.
public enum TunnelRequest: Codable, Sendable, Equatable {
    /// Fetch bytes transferred since the last `stats` query (the provider resets its counters).
    case stats
    /// Fetch the running Xray-core version string.
    case xrayVersion

    /// Encodes this request to the `Data` payload `sendProviderMessage` expects.
    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    /// Decodes a request from a `handleAppMessage` payload.
    public static func decode(_ data: Data) -> TunnelRequest? {
        try? JSONDecoder().decode(TunnelRequest.self, from: data)
    }
}

/// Replies the provider returns for a ``TunnelRequest``.
public enum TunnelResponse: Codable, Sendable, Equatable {
    case stats(BytesTransferred)
    case xrayVersion(String)
    case error(String)

    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    public static func decode(_ data: Data) -> TunnelResponse? {
        try? JSONDecoder().decode(TunnelResponse.self, from: data)
    }
}
