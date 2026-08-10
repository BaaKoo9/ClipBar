// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipBar",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "ClipboardManagerCore",
            path: "Sources/ClipboardManagerCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices")
            ]
        ),
        .executableTarget(
            name: "ClipBar",
            dependencies: ["ClipboardManagerCore"],
            path: "Sources/ClipboardManager",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Carbon"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .executableTarget(
            name: "CoreTests",
            dependencies: ["ClipboardManagerCore"],
            path: "Tests/ClipboardManagerCoreTests",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
