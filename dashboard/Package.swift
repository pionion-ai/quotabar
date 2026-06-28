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
            path: "Tests/DashboardTests"
        ),
    ]
)
