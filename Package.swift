// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DJLibrary",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DJLibrary", targets: ["DJLibrary"]),
        .executable(name: "djcheck", targets: ["djcheck"]),
    ],
    targets: [
        .target(name: "DJCore"),
        .executableTarget(name: "DJLibrary", dependencies: ["DJCore"]),
        .executableTarget(name: "djcheck", dependencies: ["DJCore"]),
    ]
)
