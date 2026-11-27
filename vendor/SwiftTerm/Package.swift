// swift-tools-version:6.2

import PackageDescription
import Foundation

let environment = ProcessInfo.processInfo.environment
let embeddedCheck = environment["SWIFTTERM_EMBEDDED_CHECK"] == "1"
let wasmSmokeBuild = environment["SWIFTTERM_WASM"] == "1"
let webWasmBuild = environment["SWIFTTERM_WEB_WASM"] == "1"
let webWasmTests = environment["SWIFTTERM_WEB_WASM_TESTS"] == "1"
let embeddedWasmBuild = environment["SWIFTTERM_EMBEDDED_WASM"] == "1"
let documentationBuild = environment["SWIFTTERM_DOCC"] == "1"

// A package manifest is compiled and run on the HOST, so `os(Linux)` is false
// when cross-compiling from macOS to Linux. Allow Apple sources to be excluded
// explicitly for that case.
let excludeAppleSources =
    environment["SWIFTTERM_EXCLUDE_APPLE"] == "1"
#if os(Linux) || os(Windows)
let platformExcludes = ["Apple", "Mac", "iOS"]
#else
let platformExcludes: [String] = excludeAppleSources ? ["Apple", "Mac", "iOS"] : []
#endif

let buildInfoTargets: [Target] = [
    .executableTarget(
        name: "SwiftTermBuildInfoGenerator",
        path: "Sources/SwiftTermBuildInfoGenerator"
    ),
    .plugin(
        name: "SwiftTermBuildInfoPlugin",
        capability: .buildTool(),
        dependencies: ["SwiftTermBuildInfoGenerator"]
    )
]

let graphicsDependencies: [Target.Dependency] = [
    .product(
        name: "PNG",
        package: "swift-png",
        condition: .when(platforms: [.linux, .windows, .wasi, .android], traits: ["PortableGraphics"])
    ),
    .product(
        name: "LZ77",
        package: "swift-png",
        condition: .when(platforms: [.linux, .windows, .wasi, .android], traits: ["PortableGraphics"])
    ),
]

var portableTraitSettings: [SwiftSetting] = [
    .define("SWIFTTERM_EMBEDDED", .when(traits: ["Embedded"])),
    .define("SWIFTTERM_WASM", .when(traits: ["Wasm"])),
]

#if compiler(>=6.3)
// SwiftPM 6.3+ still forwards trait-conditioned Embedded feature settings to
// WASM executable link steps. Full-runtime WASI builds must not see that
// setting, while native and explicitly Embedded WASM builds still need it.
if (!wasmSmokeBuild && !webWasmBuild && !webWasmTests) || embeddedWasmBuild {
    portableTraitSettings.append(.enableExperimentalFeature("Embedded", .when(traits: ["Embedded"])))
}
#else
// SwiftPM 6.2 treats any Embedded feature setting as active when it plans a
// target, even when the setting is trait-conditioned, and then injects the
// Embedded-only mergeable-symbols workaround into normal debug builds.
// Omit the setting on that toolchain so Xcode 26 users stay on the normal
// linker path; true Embedded trait builds require SwiftPM 6.3 or later.
portableTraitSettings.append(.define("SWIFTTERM_EMBEDDED_NEEDS_SWIFT_6_3", .when(traits: ["Embedded"])))
#endif

// SwiftPM symbol graph generation enables all package traits. Suppress the
// portable compiler modes so DocC builds the normal host API.
var swiftTermSettings: [SwiftSetting] = documentationBuild ? [] : portableTraitSettings

if embeddedCheck {
    swiftTermSettings += [
        .define("SWIFTTERM_EMBEDDED"),
        .unsafeFlags(["-Werror", "EmbeddedRestrictions"]),
    ]
}

let swiftTermTarget: Target = .target(
    name: "SwiftTerm",
    dependencies: graphicsDependencies,
    path: "Sources/SwiftTerm",
    exclude: platformExcludes + [
        "Mac/README.md",
        "Apple/Metal/Shaders.metal",
    ],
    swiftSettings: swiftTermSettings,
    plugins: [
        .plugin(name: "SwiftTermBuildInfoPlugin")
    ]
)

let package = Package(
    name: "SwiftTerm",
    platforms: [.macOS(.v11)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    traits: [.default(enabledTraits: ["PortableGraphics"]),
             .trait(name: "PortableGraphics", description: "PNG and zlib decoders for the full non-Apple core"),
             .trait(name: "Embedded", description: "Foundation-free portable core for Embedded Swift"),
             .trait(name: "Wasm", description: "Full WASI core", enabledTraits: ["PortableGraphics"])],
    dependencies: [.package(url: "https://github.com/tayloraswift/swift-png", exact: "4.5.2")],
    targets: [swiftTermTarget] + buildInfoTargets,
    swiftLanguageModes: [.v6]
)
