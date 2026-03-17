// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Resolve absolute path to Rust FFI library
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let rustLibDir = "\(packageDir)/core/target/debug"

let package = Package(
    name: "Wrenflow",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.9"),
    ],
    targets: [
        // C headers for the Rust UniFFI library
        .systemLibrary(
            name: "wrenflow_ffiFFI",
            path: "FFIModule"
        ),
        .executableTarget(
            name: "Wrenflow",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                "wrenflow_ffiFFI",
            ],
            path: "Sources",
            linkerSettings: [
                .unsafeFlags([
                    "-L\(rustLibDir)",
                    "-lwrenflow_ffi",
                ]),
            ]
        ),
        .executableTarget(
            name: "WrenflowCLI",
            path: "CLI"
        ),
    ]
)
