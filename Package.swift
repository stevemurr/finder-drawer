// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FinderDrawer",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FinderDrawerKit", targets: ["FinderDrawerKit"]),
        .executable(name: "FinderDrawer", targets: ["FinderDrawer"]),
    ],
    targets: [
        .target(name: "FinderDrawerKit", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "FinderDrawer", dependencies: ["FinderDrawerKit"]),
        .testTarget(name: "FinderDrawerKitTests", dependencies: ["FinderDrawerKit"]),
    ],
    swiftLanguageModes: [.v5]
)
