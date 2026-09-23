// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FinderDrawer",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FinderDrawerKit", targets: ["FinderDrawerKit"]),
        .executable(name: "FinderDrawer", targets: ["FinderDrawer"]),
    ],
    // SwiftTerm 1.20.0 plus upstream PR #636 (Metal row cache survives scrolls)
    // and a scrollTo fix, so scrolling back no longer rebuilds every row.
    // Return to upstream once #636 ships in a release.
    dependencies: [.package(url: "https://github.com/stevemurr/SwiftTerm.git", revision: "d74e91a6e46d237c71976dcfba50772d83f3ed80")],
    targets: [
        .target(name: "FinderDrawerKit", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "FinderDrawer", dependencies: ["FinderDrawerKit"]),
        .testTarget(name: "FinderDrawerKitTests", dependencies: ["FinderDrawerKit"]),
    ],
    swiftLanguageModes: [.v5]
)
