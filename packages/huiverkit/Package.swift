// swift-tools-version: 6.0
import PackageDescription

// Everything that is not a view lives in HuiverKit, so it can be built and
// tested with `swift test` on the Mac rather than only inside a simulator.
// The Xcode app target is a thin shell around it.
let package = Package(
    name: "HuiverKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "HuiverKit", targets: ["HuiverKit"])
    ],
    dependencies: [
        // The multilingual decode loop. Only the Mac app links MLX — the iOS
        // project compiles these same sources without it, and every use is
        // behind `#if canImport(MLX)`.
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.31.6")
    ],
    targets: [
        .target(
            name: "HuiverKit",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
            ]
        ),
        .testTarget(
            name: "HuiverKitTests",
            dependencies: ["HuiverKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
