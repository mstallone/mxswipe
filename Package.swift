// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MXSwipe",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/mstallone/menuhub", exact: "0.5.1"),
    ],
    targets: [
        .executableTarget(
            name: "MXSwipe",
            dependencies: [
                "SystemEvents",
                .product(name: "MenuHub", package: "menuhub"),
                .product(name: "MenuHubSparkle", package: "menuhub"),
            ],
            path: "Sources/MXSwipe",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .target(
            name: "SystemEvents",
            path: "Sources/SystemEvents",
            linkerSettings: [.linkedFramework("ApplicationServices")]
        ),
        .testTarget(
            name: "MXSwipeTests",
            dependencies: ["MXSwipe"],
            path: "Tests/MXSwipeTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SystemEventsTests",
            dependencies: ["SystemEvents"],
            path: "Tests/SystemEventsTests"
        ),
    ]
)
