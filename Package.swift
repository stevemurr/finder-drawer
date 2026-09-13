// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FinderDrawer",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "FinderDrawerKit", targets: ["FinderDrawerKit"]),
        .executable(name: "FinderDrawer", targets: ["FinderDrawer"]),
    ],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")],
    targets: [
        .target(name: "FinderDrawerKit", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "FinderDrawer", dependencies: ["FinderDrawerKit"]),
        .testTarget(name: "FinderDrawerKitTests", dependencies: ["FinderDrawerKit"]),
    ],
    swiftLanguageModes: [.v5]
)
