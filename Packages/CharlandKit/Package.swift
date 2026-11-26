// swift-tools-version: 6.2
import PackageDescription

// CharlandKit: il pacchetto per le altre app. Contiene lo schema delle attività
// e un cliente per il socket locale di Charland. Non dipende da niente.
let package = Package(
    name: "CharlandKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CharlandKit", targets: ["CharlandKit"]),
    ],
    targets: [
        .target(name: "CharlandKit"),
        .testTarget(name: "CharlandKitTests", dependencies: ["CharlandKit"]),
    ],
    swiftLanguageModes: [.v6]
)
