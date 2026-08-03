// swift-tools-version: 6.0
import PackageDescription

// MARK: - LibXray binary
//
// `LibXray.xcframework` is ~500 MB uncompressed, which is far above GitHub's
// 100 MB-per-file limit, so it is NOT committed to the repository. There are two
// supported ways to supply it:
//
//   1. Release (recommended): host `LibXray.xcframework.zip` as a GitHub Release
//      asset and reference it with `.binaryTarget(url:checksum:)`. Compute the
//      checksum with:  swift package compute-checksum LibXray.xcframework.zip
//
//   2. Local development: drop `LibXray.xcframework` into `Frameworks/` (already
//      in `.gitignore`) and use the local `.binaryTarget(path:)` below.
//
// Toggle by commenting/uncommenting the two `libXrayTarget` definitions.

let libXrayTarget: Target = .binaryTarget(
    name: "LibXray",
    url: "https://github.com/themoein100/MXray/releases/download/v1.0.1/LibXray.xcframework.zip",
    checksum: "b146048124d0083d88548a5f398b68d25ca73a702be97cc6a6479c0ce293ae7e"
)

// Local development variant — drop LibXray.xcframework into Frameworks/ (git-ignored)
// and use this instead of the remote binary above:
//
// let libXrayTarget: Target = .binaryTarget(
//     name: "LibXray",
//     path: "Frameworks/LibXray.xcframework"
// )

let package = Package(
    name: "MXray",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "MXray",
            targets: ["MXray"]
        )
    ],
    dependencies: [],
    targets: [
        libXrayTarget,
        .target(
            name: "MXray",
            dependencies: ["LibXray"],
            path: "Sources/MXray",
            swiftSettings: [
                // MXray bridges non-Sendable Apple frameworks (NetworkExtension) and a C library
                // (LibXray). The Swift 6 concurrency checker flags the detached packet-pump threads
                // and NE callbacks even though they are correct by construction, so the target opts
                // into the Swift 5 language mode. Callers remain free to build in Swift 6 mode.
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                // Xray's Go runtime resolves DNS through the system resolver.
                .linkedLibrary("resolv")
            ]
        ),
        .testTarget(
            name: "MXrayTests",
            dependencies: ["MXray"],
            path: "Tests/MXrayTests"
        )
    ]
)
