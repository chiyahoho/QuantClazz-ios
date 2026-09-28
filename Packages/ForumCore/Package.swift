// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "ForumCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ForumCore", targets: ["ForumCore"])],
    dependencies: [.package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0")],
    targets: [.target(name: "ForumCore", dependencies: [.product(name: "Markdown", package: "swift-markdown")]), .testTarget(name: "ForumCoreTests", dependencies: ["ForumCore"])],
    swiftLanguageVersions: [.v5]
)
