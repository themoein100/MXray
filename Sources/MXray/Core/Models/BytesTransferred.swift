//
//  BytesTransferred.swift
//  MXray
//
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation

/// A snapshot of traffic that flowed through the tunnel over some interval.
public struct BytesTransferred: Sendable, Equatable, Codable {
    /// Bytes delivered from the remote toward the device (download).
    public var received: Int64
    /// Bytes sent from the device toward the remote (upload).
    public var sent: Int64

    public init() {
        self.received = 0
        self.sent = 0
    }

    public init(received: Int64, sent: Int64) {
        self.received = received
        self.sent = sent
    }
}
