// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Trano",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TranoApp", targets: ["TranoApp"]),
        .executable(name: "trano", targets: ["TranoCLI"]),
        .library(name: "TerminalCore", targets: ["TerminalCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.1"),
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2"),
        .package(url: "https://github.com/apple/swift-docc-plugin", exact: "1.5.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-symbolkit", exact: "1.0.0"),
        .package(url: "https://github.com/tayloraswift/swift-png", exact: "4.5.2"),
        .package(url: "https://github.com/rarestype/h", exact: "1.0.1"),
        .package(url: "https://github.com/ordo-one/dollup", exact: "1.3.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(name: "TerminalCore"),
        .executableTarget(name: "TranoApp", dependencies: ["TerminalCore", "SwiftTerm", "Sparkle"], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../../Frameworks"])]),
        .executableTarget(name: "TranoCLI", dependencies: ["TerminalCore"]),
        .testTarget(name: "TerminalCoreTests", dependencies: ["TerminalCore"]),
        .testTarget(name: "TranoCLITests", dependencies: ["TranoCLI", "TerminalCore"]),
        .testTarget(name: "TerminalUITests", dependencies: ["SwiftTerm", "TranoApp", "TerminalCore"])
    ],
    swiftLanguageModes: [.v5]
)
