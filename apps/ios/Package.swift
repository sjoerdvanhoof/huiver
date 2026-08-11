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
    targets: [
        .target(name: "HuiverKit"),
        .testTarget(
            name: "HuiverKitTests",
            dependencies: ["HuiverKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
