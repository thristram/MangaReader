// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MangaCore", platforms: [.macOS(.v15), .iOS(.v18)], products: [.library(name: "MangaCore", targets: ["MangaCore"])], targets: [.target(name: "MangaCore"), .testTarget(name: "MangaCoreTests", dependencies: ["MangaCore"])])
