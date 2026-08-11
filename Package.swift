// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MuxBeacon",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MuxBeaconCore", targets: ["MuxBeaconCore"]),
        .executable(name: "mux-beacon", targets: ["MuxBeaconCLI"]),
        .executable(name: "MuxBeaconApp", targets: ["MuxBeaconApp"]),
        .executable(name: "mux-beacon-self-test", targets: ["MuxBeaconSelfTest"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(
            name: "MuxBeaconCore",
            dependencies: ["CSQLite"]
        ),
        .executableTarget(
            name: "MuxBeaconCLI",
            dependencies: ["MuxBeaconCore"]
        ),
        .executableTarget(
            name: "MuxBeaconApp",
            dependencies: ["MuxBeaconCore"]
        ),
        .executableTarget(
            name: "MuxBeaconSelfTest",
            dependencies: ["MuxBeaconCore"]
        ),
    ]
)
