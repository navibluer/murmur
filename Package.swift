// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "murmur",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "MurmurCore"),
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
        .testTarget(name: "MurmurCoreTests", dependencies: ["MurmurCore"]),
    ]
)
