// swift-tools-version: 6.2
import PackageDescription

// La logica pura di Charland: forma dell'isola, molle, stati, schema dell'API.
// Niente AppKit e niente SwiftUI, così si prova con `swift test` in un attimo.
let package = Package(
    name: "CharlandCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CharlandCore", targets: ["CharlandCore"]),
    ],
    targets: [
        .target(name: "CharlandCore"),
        .testTarget(name: "CharlandCoreTests", dependencies: ["CharlandCore"]),
    ],
    swiftLanguageModes: [.v6]
)
