// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "VeilStudio", platforms: [.macOS(.v14)],
    products: [.executable(name: "VeilStudio", targets: ["VeilStudio"])],
    targets: [.executableTarget(name: "VeilStudio"), .testTarget(name: "VeilStudioTests", dependencies: ["VeilStudio"])]
)
