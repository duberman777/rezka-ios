// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RezkaScraping",
    platforms: [.macOS(.v13)],
    products: [.library(name: "RezkaScraping", targets: ["RezkaPort"])],
    dependencies: [.package(url: "https://github.com/scinfu/SwiftSoup", exact: "2.14.1")],
    targets: [
        .target(name: "RezkaPort", dependencies: ["SwiftSoup"], path: "StreamingApp",
                exclude: ["App", "Assets.xcassets", "Core", "Features", "Data/Rezka/RezkaBrowserSession.swift"],
                sources: ["Domain", "Data/ContentSource.swift", "Data/DemoContentSource.swift", "Data/Rezka"]),
        .testTarget(name: "RezkaScrapingTests", dependencies: ["RezkaPort"], path: "StreamingAppTests")
    ]
)
