// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PRPing", platforms: [.macOS(.v13)], products: [.executable(name: "PRPing", targets: ["PRPing"])], targets: [.target(name: "PRPingCore"), .executableTarget(name: "PRPing", dependencies: ["PRPingCore"]), .testTarget(name: "PRPingCoreTests", dependencies: ["PRPingCore"])])
