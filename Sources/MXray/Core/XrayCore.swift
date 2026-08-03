//
//  XrayCore.swift
//  MXray
//
//  Copyright 2026 Moein
//  SPDX-License-Identifier: Apache-2.0
//
//  Thin, direct bridge over the LibXray C API. These are the lowest-level
//  primitives; most callers should use `MXray` (facade) or `XrayBridge`
//  (packet tunnel) instead.
//

import Foundation
import LibXray

/// Low-level wrapper over the `LibXray` static library.
public enum XrayCore {

    /// Allocates `count` free local TCP ports.
    public static func getFreePorts(_ count: Int) throws -> [Int] {
        let base64JsonResponse = LibXrayGetFreePorts(count)
        let portsResponse = try XrayPortsResponse(base64String: base64JsonResponse)
        guard let ports = portsResponse.data?.ports else {
            throw MXrayError.invalidResponse(base64JsonResponse)
        }
        return ports
    }

    /// Sets the TUN file descriptor used by Xray's `tun` inbound. Must be called before `run(...)`.
    public static func setTunFd(_ fd: Int32) {
        LibXraySetTunFd(fd)
    }

    /// Sets the Go heap soft ceiling in megabytes. Must be called before `run(...)`.
    public static func setMemoryLimitMB(_ mb: Int64) {
        LibXraySetMemoryLimitMB(mb)
    }

    /// Runs Xray with the configuration at `configPath`, using `dataDir` for geo files.
    public static func run(dataDir: String, configPath: String) throws {
        let jsonRequest = try JSONEncoder().encode(
            XrayRunRequest(datDir: dataDir, configPath: configPath)
        )
        let base64JsonResponse = LibXrayRunXray(jsonRequest.base64EncodedString())
        let runResponse = try XrayBoolResponse(base64String: base64JsonResponse)
        if !runResponse.success {
            throw MXrayError.invalidResponse(base64JsonResponse)
        }
    }

    /// Stops the running Xray instance.
    public static func stop() throws {
        let base64JsonResponse = LibXrayStopXray()
        let runResponse = try XrayBoolResponse(base64String: base64JsonResponse)
        if !runResponse.success {
            throw MXrayError.invalidResponse(base64JsonResponse)
        }
    }

    /// Returns the bundled Xray-core version string.
    public static func xrayVersion() throws -> String {
        let base64JsonResponse = LibXrayXrayVersion()
        let runResponse = try XrayVersionResponse(base64String: base64JsonResponse)
        guard runResponse.success, let version = runResponse.data else {
            throw MXrayError.invalidResponse(base64JsonResponse)
        }
        return version
    }

    /// Measures latency by asking Xray to fetch `url` through `proxy`.
    public static func ping(
        dataDir: String,
        configPath: String,
        timeout: Int,
        url: String,
        proxy: String
    ) throws -> XrayPingResponse {
        let request = XrayPingRequest(
            datDir: dataDir,
            configPath: configPath,
            timeout: timeout,
            url: url,
            proxy: proxy
        )
        let encodedRequest = try JSONEncoder().encode(request).base64EncodedString()
        let encodedResponse = LibXrayPing(encodedRequest)
        guard let response = try? XrayPingResponse(base64String: encodedResponse) else {
            throw MXrayError.invalidResponse(encodedResponse)
        }
        return response
    }

    /// Converts an Xray share link (`vless://`, `vmess://`, …) to a JSON configuration string.
    public static func shareLinkToJSON(url: String) throws -> String {
        let base64JsonResponse = LibXrayConvertShareLinksToXrayJson(
            Data(url.utf8).base64EncodedString()
        )

        guard let jsonResponse = base64JsonResponse.fromBase64(),
              let respData = jsonResponse.data(using: .utf8) else {
            throw MXrayError.invalidResponse(base64JsonResponse)
        }
        guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
            throw MXrayError.invalidResponse(base64JsonResponse)
        }
        guard (json["success"] as? Bool) == true else {
            throw MXrayError.invalidResponse(json.description)
        }
        guard let nestedObj = json["data"] as? [String: Any] else {
            throw MXrayError.invalidResponse(json.description)
        }
        guard let dt = try? JSONSerialization.data(withJSONObject: nestedObj),
              let str = String(data: dt, encoding: .utf8) else {
            throw MXrayError.invalidResponse(base64JsonResponse)
        }
        return str
    }
}
