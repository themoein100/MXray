//
//  GeoFilesLoader.swift
//  MXray
//
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation

/// Downloads and manages Xray geo files (`geoip.dat` and `geosite.dat`).
///
/// These files are downloaded at runtime rather than bundled, so they can be refreshed
/// independently of app releases. Prefer the lightweight community builds (the defaults below)
/// to keep VPN setup fast and memory use low.
public final class GeoFilesLoader: @unchecked Sendable {
    /// Default `geoip.dat` source. Uses a lightweight community build for fast setup.
    public var geoIPUrl = URL(string: "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat")!
    /// Default `geosite.dat` source. Uses a lightweight community build for fast setup.
    public var geoSiteUrl = URL(string: "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat")!

    private var geoIPProgress: Double = 0.0
    private var geoSiteProgress: Double = 0.0
    private var progressCallback: ((Double) -> Void)?
    private var observers: [NSKeyValueObservation] = []

    public init() {}

    /// Downloads `geoip.dat` and `geosite.dat` concurrently into `directory`.
    ///
    /// - Parameters:
    ///   - directory: Destination directory (created if missing). Existing files are replaced.
    ///   - geoSiteURL: Optional override for the geosite source; falls back to ``geoSiteUrl``.
    ///   - geoIPURL: Optional override for the geoip source; falls back to ``geoIPUrl``.
    ///   - progressCallback: Optional combined progress (0.0 … 1.0) across both files.
    public func loadGeoFiles(
        into directory: URL,
        geoSiteURL: URL? = nil,
        geoIPURL: URL? = nil,
        progressCallback: ((Double) -> Void)? = nil
    ) async throws {
        let finalGeoIPURL = geoIPURL ?? self.geoIPUrl
        let finalGeoSiteURL = geoSiteURL ?? self.geoSiteUrl

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        self.progressCallback = progressCallback
        let geoIPDestination = directory.appendingPathComponent("geoip.dat")
        let geoSiteDestination = directory.appendingPathComponent("geosite.dat")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.downloadFile(
                    from: finalGeoIPURL,
                    to: geoIPDestination,
                    progressCallback: { [weak self] progress in
                        self?.updateProgress(geoIPProgress: progress)
                    }
                )
            }
            group.addTask {
                try await self.downloadFile(
                    from: finalGeoSiteURL,
                    to: geoSiteDestination,
                    progressCallback: { [weak self] progress in
                        self?.updateProgress(geoSiteProgress: progress)
                    }
                )
            }
            try await group.waitForAll()
            observers.forEach { $0.invalidate() }
            observers.removeAll()
        }
    }

    private func updateProgress(geoIPProgress: Double? = nil, geoSiteProgress: Double? = nil) {
        if let geoIPProgress { self.geoIPProgress = geoIPProgress }
        if let geoSiteProgress { self.geoSiteProgress = geoSiteProgress }
        let total = (self.geoIPProgress + self.geoSiteProgress) / 2.0
        progressCallback?(total)
    }

    private func downloadFile(
        from url: URL,
        to destination: URL,
        progressCallback: @Sendable @escaping (Double) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { [weak self] (continuation: CheckedContinuation<Void, Error>) in
            try? FileManager.default.removeItem(at: destination)

            let downloadTask = URLSession.shared.downloadTask(with: URLRequest(url: url)) { tempURL, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                guard let tempURL else {
                    continuation.resume(throwing: URLError(.cannotCreateFile))
                    return
                }
                do {
                    try FileManager.default.moveItem(at: tempURL, to: destination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            self?.subscribeForProgress(task: downloadTask, callback: progressCallback)
            downloadTask.resume()
        }
    }

    private func subscribeForProgress(task: URLSessionDownloadTask, callback: @escaping @Sendable (Double) -> Void) {
        let observer = task.progress.observe(\.fractionCompleted) { progress, _ in
            DispatchQueue.main.async { callback(progress.fractionCompleted) }
        }
        observers.append(observer)
    }
}
