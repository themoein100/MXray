//
//  XrayResponses.swift
//  MXray
//
//  Copyright 2026 Moein
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation

/// Generic envelope returned by LibXray calls: a base64-encoded JSON `{ success, data }`.
struct XrayResponse<T: Decodable>: Decodable {
    let success: Bool
    let data: T?

    init(base64String: String) throws {
        let plainStr = base64String.fromBase64() ?? ""
        let selfCopy = try JSONDecoder().decode(
            XrayResponse<T>.self,
            from: plainStr.data(using: .utf8) ?? Data()
        )
        success = selfCopy.success
        data = selfCopy.data
    }
}

struct XrayPortsResponseBody: Codable {
    let ports: [Int]
}

struct XrayRunRequest: Codable {
    let datDir: String
    let configPath: String
}

struct XrayPingRequest: Codable {
    let datDir: String
    let configPath: String
    let timeout: Int
    let url: String
    let proxy: String
}

/// Result of a latency probe performed by Xray through the configured proxy.
public struct XrayPingResponse: Decodable, Sendable {
    /// Whether Xray completed the probe request.
    public let success: Bool
    /// Round-trip latency in milliseconds, when available.
    public let data: Int64?
    /// An informational message from Xray, if any.
    public let message: String?
    /// An error string from Xray, if the probe failed.
    public let error: String?

    init(base64String: String) throws {
        let plainStr = base64String.fromBase64() ?? ""
        let selfCopy = try JSONDecoder().decode(
            XrayPingResponse.self,
            from: plainStr.data(using: .utf8) ?? Data()
        )
        success = selfCopy.success
        data = selfCopy.data
        message = selfCopy.message
        error = selfCopy.error
    }
}

public extension XrayPingResponse {
    /// True when the failure message indicates a timeout / deadline rather than a hard error.
    var indicatesTimeout: Bool {
        [message, error]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains("timeout") || $0.contains("deadline") }
    }
}

typealias XrayPortsResponse = XrayResponse<XrayPortsResponseBody>
typealias XrayVersionResponse = XrayResponse<String>
typealias XrayBoolResponse = XrayResponse<Bool>
