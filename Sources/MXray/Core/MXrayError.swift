//
//  MXrayError.swift
//  MXray
//
//  Copyright 2026 Moein
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation

/// Errors thrown by MXray's Xray operations.
public enum MXrayError: Error, LocalizedError {
    /// The LibXray call returned a payload MXray could not parse or that reported failure.
    case invalidResponse(String)

    /// The supplied Xray configuration was empty or not valid JSON.
    case invalidConfig

    /// Failed to allocate a free local port.
    case portAllocationError

    /// A tunnel setup step failed. The associated value carries a human-readable reason.
    case tunnelSetupError(String)

    /// The `socketpair()` backing the packet bridge could not be created.
    case socketPairFailed

    public var errorDescription: String? {
        switch self {
        case .invalidResponse(let response):
            return "Invalid response from Xray: \(response)"
        case .invalidConfig:
            return "Invalid Xray configuration provided"
        case .portAllocationError:
            return "Failed to allocate a free local port"
        case .tunnelSetupError(let message):
            return "Tunnel setup error: \(message)"
        case .socketPairFailed:
            return "Failed to create the packet bridge socket pair"
        }
    }
}
