// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SteamTV",
    platforms: [.macOS(.v13), .tvOS(.v17)],
    products: [.library(name: "SteamProtocolCore", targets: ["SteamProtocolCore"]),
               .executable(name: "steam-probe", targets: ["SteamProbe"])],
    targets: [.target(name: "SteamCrypto", publicHeadersPath: "include"),
              .target(name: "SteamProtocolCore", dependencies: ["SteamCrypto"],
                      linkerSettings: [.linkedFramework("Security")]),
              .executableTarget(name: "SteamProbe", dependencies: ["SteamProtocolCore"]),
              .testTarget(name: "SteamProtocolCoreTests", dependencies: ["SteamProtocolCore"])]
)
