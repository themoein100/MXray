//
//  TunnelResourceInstaller.swift
//  MXray
//
//  Copyright 2026 Moein
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation

/// Ensures `geoip.dat` / `geosite.dat` are present in the Xray data directory.
///
/// Geo files can be several megabytes. Reading and rewriting them on every `startTunnel` produces
/// a memory spike that is a common cause of Network Extension jetsam kills, so this installer skips
/// the copy when an up-to-date file already sits at the destination (matched by byte size).
public struct TunnelResourceInstaller {

    /// Extra source locations (beyond `Bundle.main`) to search for bundled geo files —
    /// e.g. an App Group container the host app downloaded them into.
    public var additionalSourceDirectories: [URL]

    public init(additionalSourceDirectories: [URL] = []) {
        self.additionalSourceDirectories = additionalSourceDirectories
    }

    /// Installs `geoip.dat` and `geosite.dat` into `directory` if a source is available and the
    /// destination is missing or stale. Returns which files ended up present.
    @discardableResult
    public func installGeoFilesIfNeeded(into directory: URL) -> (geoIP: Bool, geoSite: Bool) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        copyIfNeeded(named: "geoip", ext: "dat", to: directory)
        copyIfNeeded(named: "geosite", ext: "dat", to: directory)

        let fm = FileManager.default
        let geoIP = fm.fileExists(atPath: directory.appendingPathComponent("geoip.dat").path)
        let geoSite = fm.fileExists(atPath: directory.appendingPathComponent("geosite.dat").path)
        return (geoIP, geoSite)
    }

    private func copyIfNeeded(named name: String, ext: String, to directory: URL) {
        let fm = FileManager.default
        let dst = directory.appendingPathComponent("\(name).\(ext)")

        guard let src = resolveSource(named: name, ext: ext) else { return }

        // Skip the copy when destination already matches the source size — avoids the ~30 MB peak
        // that reading + writing a geo file causes on every start.
        if fm.fileExists(atPath: dst.path), sameSize(src, dst) { return }

        do {
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
        } catch {
            // Non-fatal: Xray still starts, geo-based routing rules just won't resolve.
        }
    }

    private func sameSize(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        guard
            let aSize = (try? fm.attributesOfItem(atPath: a.path))?[.size] as? Int,
            let bSize = (try? fm.attributesOfItem(atPath: b.path))?[.size] as? Int
        else { return false }
        return aSize == bSize
    }

    private func resolveSource(named name: String, ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext) {
            return url
        }
        #if !os(macOS)
        if let url = Bundle(for: BundleMarker.self).url(forResource: name, withExtension: ext) {
            return url
        }
        #endif
        for dir in additionalSourceDirectories {
            let candidate = dir.appendingPathComponent("\(name).\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

private final class BundleMarker {}
