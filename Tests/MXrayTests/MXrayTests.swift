//
//  MXrayTests.swift
//  MXray
//
//  SPDX-License-Identifier: Apache-2.0
//

import XCTest
@testable import MXray

final class MXrayTests: XCTestCase {

    func testBase64RoundTrip() {
        let original = "vless://example?query=1#tag"
        XCTAssertEqual(original.toBase64().fromBase64(), original)
    }

    func testConfigurationDetectionJSON() {
        let config = XrayPacketTunnelProvider.makeConfiguration(from: "{\"outbounds\":[]}", kind: nil)
        XCTAssertEqual(config, .json("{\"outbounds\":[]}"))
    }

    func testConfigurationDetectionURL() {
        let config = XrayPacketTunnelProvider.makeConfiguration(from: "vless://abc@host:443", kind: nil)
        XCTAssertEqual(config, .url("vless://abc@host:443"))
    }

    func testConfigurationExplicitKindWins() {
        // Looks like a link, but explicitly declared JSON.
        let config = XrayPacketTunnelProvider.makeConfiguration(from: "vless://abc", kind: "json")
        XCTAssertEqual(config, .json("vless://abc"))
    }

    func testTuningPresetMobileMemory() {
        XCTAssertEqual(XrayTuningPreset.mobile.memoryLimitMB, 36)
    }

    func testBytesTransferredCodableRoundTrip() throws {
        let original = BytesTransferred(received: 1024, sent: 2048)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BytesTransferred.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testTunnelRequestRoundTrip() {
        XCTAssertEqual(TunnelRequest.decode(TunnelRequest.stats.encoded()), .stats)
        XCTAssertEqual(TunnelRequest.decode(TunnelRequest.xrayVersion.encoded()), .xrayVersion)
    }

    /// Smoke test that the LibXray binary links and responds.
    func testXrayVersionLinks() throws {
        let version = try XrayCore.xrayVersion()
        XCTAssertFalse(version.isEmpty, "Expected a non-empty Xray version string")
    }
}
