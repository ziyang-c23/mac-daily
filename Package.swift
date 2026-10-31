// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "MacDaily",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacDaily", targets: ["MacDailyApp"]), .library(name: "MacDailyCore", targets: ["MacDailyCore"]), .executable(name: "MacDailyPractice", targets: ["MacDailyPractice"])],
    targets: [
        .target(name: "MacDailyCore", resources: [.process("Resources")]),
        .target(name: "PointerBridge", publicHeadersPath: "include", linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]),
        .target(name: "TrackpadBridge", publicHeadersPath: "include", linkerSettings: [.linkedFramework("CoreFoundation")]),
        .executableTarget(name: "MacDailyApp", dependencies: ["MacDailyCore", "PointerBridge", "TrackpadBridge"], swiftSettings: [.swiftLanguageMode(.v5)], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ApplicationServices"), .linkedFramework("IOKit")]),
        .executableTarget(name: "MacDailyPractice", dependencies: ["MacDailyCore"], swiftSettings: [.swiftLanguageMode(.v5)], linkerSettings: [.linkedFramework("AppKit")]),
        .testTarget(name: "MacDailyCoreTests", dependencies: ["MacDailyCore"])
    ]
)
