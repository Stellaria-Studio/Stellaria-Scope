// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StellarScope",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "StellarScope", targets: ["StellarScope"]),
        .executable(name: "StellarScopeSMCProbe", targets: ["StellarScopeSMCProbe"])
    ],
    targets: [
        .executableTarget(
            name: "StellarScope",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "StellarScopeSMCProbe",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        )
    ]
)
