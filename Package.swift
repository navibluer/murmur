// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "murmur",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.28.0")
    ],
    targets: [
        .target(name: "MurmurCore", dependencies: [.product(name: "Hummingbird", package: "hummingbird")]),
        .executableTarget(
            name: "murmur",
            dependencies: ["MurmurCore"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/murmur/Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "MurmurCoreTests",
            dependencies: ["MurmurCore", .product(name: "HummingbirdTesting", package: "hummingbird")]),
    ]
)
