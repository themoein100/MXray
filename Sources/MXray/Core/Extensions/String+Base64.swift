//
//  String+Base64.swift
//  MXray
//
//  Copyright 2026 Moein
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation

extension String {
    /// Decodes a base64-encoded string to plain UTF-8 text, or `nil` on failure.
    func fromBase64() -> String? {
        guard let data = Data(base64Encoded: self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Encodes the string's UTF-8 bytes to base64.
    func toBase64() -> String {
        Data(self.utf8).base64EncodedString()
    }
}
