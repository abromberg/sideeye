// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FocusCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "FocusCore", targets: ["FocusCore"]),
        .executable(name: "focuseval", targets: ["focuseval"]),
    ],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")],
    targets: [
        .target(name: "FocusCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "focuseval", dependencies: ["FocusCore", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "FocusCoreTests", dependencies: ["FocusCore"]),
    ]
)
