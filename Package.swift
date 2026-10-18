// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexBarIOS",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CodexBarIOS",
            targets: ["CodexBarIOS"]
        ),
        .executable(
            name: "CodexBarIOSSmokeTests",
            targets: ["CodexBarIOSSmokeTests"]
        ),
        .executable(
            name: "GitHubBillingFixtureTests",
            targets: ["GitHubBillingFixtureTests"]
        ),
        .executable(
            name: "UsageHistoryBenchmark",
            targets: ["UsageHistoryBenchmark"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/SimplyDanny/SwiftLintPlugins",
            exact: "0.65.1"
        ),
    ],
    targets: [
        // StoreKit state-machine regressions run locally, never in automatic PR CI.
        .testTarget(
            name: "ProEntitlementTests",
            dependencies: ["CodexBarIOS"],
            path: "ProEntitlementTests",
            plugins: [
                .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
            ]
        ),
        // Local-only regressions; automatic CI continues running its existing smoke executable.
        .testTarget(
            name: "CodexUsageTests",
            dependencies: ["CodexBarIOS"],
            path: "CodexUsageTests",
            plugins: [
                .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
            ]
        ),
        .testTarget(
            name: "ClaudeUsageTests",
            dependencies: ["CodexBarIOS"],
            path: "ClaudeUsageTests",
            plugins: [
                .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
            ]
        ),
        .testTarget(
            name: "SettingsPresentationTests",
            dependencies: ["CodexBarIOS"],
            path: "SettingsPresentationTests",
            plugins: [
                .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
            ]
        ),
        .testTarget(
            name: "MetricTileContentTests",
            dependencies: ["CodexBarIOS"],
            path: "MetricTileContentTests",
            plugins: [
                .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
            ]
        ),
        .testTarget(
            name: "GreptilePaginationTests",
            dependencies: ["CodexBarIOS"],
            path: "GreptilePaginationTests",
            plugins: [
                .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
            ]
        ),
        .testTarget(
            name: "GeminiAuthTests",
            dependencies: ["CodexBarIOS"],
            path: "GeminiAuthTests",
            plugins: [
                .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
            ]
        ),
        .testTarget(
            name: "OpenCodeAuthTests",
            dependencies: ["CodexBarIOS"],
            path: "OpenCodeAuthTests",
            plugins: [
                .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
            ]
        ),
        .testTarget(
            name: "GrokAuthTests",
            dependencies: ["CodexBarIOS"],
            path: "GrokAuthTests",
            plugins: [
                .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
            ]
        ),
        .executableTarget(
            name: "UsageHistoryBenchmark",
            dependencies: ["CodexBarIOS"],
            path: "PerformanceBenchmarks",
            plugins: [
                .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
            ]
        ),
        .target(
            name: "CodexBarIOS",
            path: "CodexBarIOS",
            exclude: [
                "CodexBarIOSApp.swift",
                "CodexBarIOS.entitlements",
                "ContentView.swift",
                "Info.plist",
                "PrivacyInfo.xcprivacy",
                "Resources",
                "Services/UITestFixtures.swift",
                "Views",
            ],
            plugins: [
                .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
            ]
        ),
        .executableTarget(
            name: "CodexBarIOSSmokeTests",
            dependencies: ["CodexBarIOS"],
            path: "SmokeTests",
            plugins: [
                .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
            ]
        ),
        .executableTarget(
            name: "GitHubBillingFixtureTests",
            dependencies: ["CodexBarIOS"],
            path: "GitHubBillingFixtureTests",
            plugins: [
                .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
            ]
        ),
    ]
)
