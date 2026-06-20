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
            dependencies: ["StellarScopeNative"],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOKit")
            ]
        ),
        .target(
            name: "StellarScopeNative",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-std=c++17"])
            ],
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit"),
                .linkedLibrary("IOReport")
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
