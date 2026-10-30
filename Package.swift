// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PowerWatch", platforms: [.macOS(.v15)],
    products: [.executable(name: "PowerWatch", targets: ["PowerWatch"]),
               .executable(name: "PowerWatchHelper", targets: ["PowerWatchHelper"]),
               .executable(name: "PowerWatchProbe", targets: ["PowerWatchProbe"])],
    targets: [.target(name: "PowerWatchCore", linkerSettings: [.linkedLibrary("sqlite3"), .linkedFramework("IOKit")]),
              .executableTarget(name: "PowerWatch", dependencies: ["PowerWatchCore"]),
              .executableTarget(name: "PowerWatchHelper", dependencies: ["PowerWatchCore"]),
              .executableTarget(name: "PowerWatchProbe", dependencies: ["PowerWatchCore"]),
              .testTarget(name: "PowerWatchCoreTests", dependencies: ["PowerWatchCore"], resources: [.copy("Fixtures")])],
    swiftLanguageModes: [.v5]
)
