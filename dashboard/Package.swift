// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Dashboard",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Dashboard", path: "Sources/Dashboard"),
        .testTarget(
            name: "DashboardTests",
            dependencies: ["Dashboard"],
            path: "Tests/DashboardTests",
            // Loaded from disk via #filePath at its source location, not bundled
            // as a resource; exclude it so SPM doesn't flag it as unhandled.
            exclude: ["Fixtures/oauth-usage-real.json", "Fixtures/codex-usage-real.json", "Fixtures/gemini-quota-real.json"]
        ),
    ]
)
