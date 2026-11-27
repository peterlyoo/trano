import Foundation
import XCTest
@testable import TerminalCore

final class ManagedAccountPathTests: XCTestCase {
    // Implements: FR-ORG-3
    func testBareGUIEnvironmentAppendsKnownInstallLocations() {
        let digest = String(repeating: "a", count: 64)
        let runtime = URL(fileURLWithPath: "/private/tmp/synthetic-runtime")
        let reader = ClaudeAuthenticationIdentityReader(environment: { ["PATH": "/usr/bin:/bin"] },
            keychain: { _, _ in ClaudeKeychainMetadata(exists: true, digest: digest) }, executable: { _, _ in digest })
        let path = reader.effectiveEnvironment(accountID: "fixture", root: runtime, runtimeRoot: runtime)["PATH"]!
        XCTAssertEqual(path, "/usr/bin:/bin:" + FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path + ":/opt/homebrew/bin:/usr/local/bin")
    }

    // Implements: FR-ORG-3
    func testDefaultsAndExistingOrderDeduplicateKnownLocations() {
        let root = URL(fileURLWithPath: "/private/tmp/path-fixture"), home = root.appendingPathComponent("home")
        let expected = "/usr/bin:/bin:" + home.appendingPathComponent(".local/bin").path + ":/opt/homebrew/bin:/usr/local/bin"
        XCTAssertEqual(ManagedAccountPath.normalized(nil, runtimeRoot: root, home: home), expected)
        XCTAssertEqual(ManagedAccountPath.normalized("", runtimeRoot: root, home: home), expected)
        XCTAssertEqual(ManagedAccountPath.normalized("/custom/first:/opt/homebrew/bin:/usr/bin:/custom/first", runtimeRoot: root, home: home),
            "/custom/first:/opt/homebrew/bin:/usr/bin:" + home.appendingPathComponent(".local/bin").path + ":/usr/local/bin")
        XCTAssertEqual(ManagedAccountPath.normalized(expected, runtimeRoot: root, home: home), expected)
    }
    // Implements: FR-ORG-3
    func testCanonicalShimAliasesAreRemovedAndFirstCustomSpellingPreserved() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let shim = root.appendingPathComponent("runtime/bin"), custom = root.appendingPathComponent("custom"), alias = root.appendingPathComponent("alias"), customAlias = root.appendingPathComponent("custom-alias")
        for path in [shim, custom] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: shim)
        try FileManager.default.createSymbolicLink(at: customAlias, withDestinationURL: custom)
        let home = root.appendingPathComponent("home")
        let path = ManagedAccountPath.normalized([alias.path, customAlias.path, shim.path, custom.path, "/usr/bin"].joined(separator: ":"), runtimeRoot: root.appendingPathComponent("runtime"), home: home)
        XCTAssertEqual(path, customAlias.path + ":/usr/bin:" + home.appendingPathComponent(".local/bin").path + ":/opt/homebrew/bin:/usr/local/bin")
    }
    // Implements: FR-ORG-3
    func testKnownInstallLocationPointingAtShimIsNotReintroduced() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("runtime"), home = root.appendingPathComponent("home"), shim = runtime.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: shim, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".local"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".local/bin"), withDestinationURL: shim)
        XCTAssertEqual(ManagedAccountPath.normalized("/usr/bin:/bin", runtimeRoot: runtime, home: home), "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin")
    }
    // Implements: FR-ORG-3
    func testBareGUIPathFindsFakeOwnedExecutableWithoutLaunchingIt() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("runtime"), home = root.appendingPathComponent("home"), binary = home.appendingPathComponent(".local/bin/claude")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic executable never launched".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let path = ManagedAccountPath.normalized("/usr/bin:/bin", runtimeRoot: runtime, home: home)
        var calls = 0
        let identity = try ClaudeAuthenticationIdentityReader.nativeExecutableIdentity(environment: ["PATH": path], allowVersion: true) { observed, environment in
            calls += 1
            XCTAssertEqual(observed, binary.resolvingSymlinksInPath().standardizedFileURL.path)
            XCTAssertEqual(environment["PATH"], path)
            return "2.1.322 (Claude Code)"
        }
        XCTAssertEqual(identity.count, 64)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try ClaudeAuthenticationIdentityReader.nativeExecutableIdentity(environment: ["PATH": path], allowVersion: false, version: { _, _ in XCTFail("Pure check must not probe version"); return "" }), identity)
    }
    private func directory() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/trano-path-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
