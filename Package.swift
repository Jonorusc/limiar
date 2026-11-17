// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Limiar",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Limiar", targets: ["Limiar"]),
        .executable(name: "limiard", targets: ["limiard"]),
    ],
    targets: [
        .target(
            name: "CSMC",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .target(
            name: "LimiarCore",
            dependencies: ["CSMC"],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "limiard",
            dependencies: ["LimiarCore", "CSMC"]
        ),
        .executableTarget(
            name: "Limiar",
            dependencies: ["LimiarCore"]
        ),
        .testTarget(
            name: "LimiarCoreTests",
            dependencies: ["LimiarCore"]
        ),
    ]
)
