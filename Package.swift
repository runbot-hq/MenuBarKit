// swift-tools-version:6.2
// MenuBarKit — standalone package, consumed via SPM URL branch: "main".
// Zero dependencies on RunBot or RunBotCore.
import PackageDescription

let package = Package(
    name: "MenuBarKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(
            name: "MenuBarKit",
            targets: ["MenuBarKit"]
        ),
    ],
    targets: [
        .target(
            name: "MenuBarKit",
            dependencies: [],
            path: "Sources/MenuBarKit",
            // README.md is a developer reference doc — not a bundleable resource.
            // Exclude it to silence the SPM unhandled-resource warning.
            exclude: ["README.md"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
    ]
)
