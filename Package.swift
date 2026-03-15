// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Wrenflow",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.9"),
    ],
    targets: [
        .executableTarget(
            name: "Wrenflow",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources"
        ),
        .executableTarget(
            name: "WrenflowCLI",
            path: "CLI"
        ),
    ]
)
