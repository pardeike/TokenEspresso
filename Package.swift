// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenEspresso",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TokenEspresso", targets: ["TokenEspresso"]),
        .library(name: "TokenEspressoProviders", targets: ["TokenEspressoProviders"]),
        .library(name: "TokenEspressoUI", targets: ["TokenEspressoUI"]),
    ],
    targets: [
        .target(name: "TokenEspresso"),
        .target(name: "TokenEspressoProviders", dependencies: ["TokenEspresso"]),
        .target(name: "TokenEspressoUI", dependencies: ["TokenEspresso"]),
        .testTarget(name: "TokenEspressoTests", dependencies: ["TokenEspresso"], resources: [.process("Fixtures")]),
        .testTarget(name: "TokenEspressoProviderTests", dependencies: ["TokenEspresso", "TokenEspressoProviders"]),
        .testTarget(name: "TokenEspressoAPITests", dependencies: ["TokenEspresso", "TokenEspressoUI"]),
    ],
    swiftLanguageModes: [.v6]
)
