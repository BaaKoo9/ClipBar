// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipboardManager",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "ClipboardManager",
            path: "Sources/ClipboardManager",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Carbon"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        )
    ]
)
