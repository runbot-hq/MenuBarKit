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
        )
    ],
    targets: [
        .target(
            name: "MenuBarKit",
            dependencies: [],
            path: "Sources/MenuBarKit",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .testTarget(
            name: "MenuBarKitTests",
            dependencies: ["MenuBarKit"],
            path: "Tests/MenuBarKitTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        )
    ]
)
