// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NitsSync",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "NitsCtrlCore", targets: ["NitsCtrlCore"]),
        .library(name: "NitsCtrlHardware", targets: ["NitsCtrlHardware"]),
        .executable(name: "NitsSync", targets: ["NitsCtrlApp"]),
    ],
    targets: [
        .target(name: "NitsCtrlCore"),
        .target(
            name: "CNitsCtrlDDC",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("IOKit"),
            ]
        ),
        .target(
            name: "NitsCtrlHardware",
            dependencies: ["CNitsCtrlDDC", "NitsCtrlCore"],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "NitsCtrlApp",
            dependencies: ["NitsCtrlCore", "NitsCtrlHardware"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "NitsCtrlCoreTests",
            dependencies: ["NitsCtrlCore"]
        ),
        .testTarget(
            name: "NitsCtrlHardwareTests",
            dependencies: ["NitsCtrlHardware"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
