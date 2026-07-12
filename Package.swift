// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SonoGlass",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "SonosKit", targets: ["SonosKit"]),
        .library(name: "PandoraKit", targets: ["PandoraKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "1.8.0"),
    ],
    targets: [
        .target(name: "SonosKit"),
        .target(
            name: "PandoraKit",
            dependencies: [.product(name: "CryptoSwift", package: "CryptoSwift")]
        ),
        .executableTarget(
            name: "SonoGlass",
            dependencies: ["SonosKit", "PandoraKit"],
            path: "Sources/App"
        ),
        .executableTarget(
            name: "sonoglass-diag",
            dependencies: ["SonosKit", "PandoraKit"],
            path: "Sources/DiagCLI"
        ),
        .executableTarget(
            name: "pandora-probe",
            dependencies: ["SonosKit", "PandoraKit"],
            path: "Sources/ProbeCLI"
        ),
        .testTarget(
            name: "SonoGlassTests",
            dependencies: ["SonosKit", "PandoraKit"],
            path: "Tests/SonoGlassTests"
        ),
    ]
)
