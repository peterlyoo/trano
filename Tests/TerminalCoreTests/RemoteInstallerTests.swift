import XCTest
@testable import TerminalCore

final class RemoteInstallerTests: XCTestCase {
    // Implements: FR-REMOTE-INSTALL-1
    func testNestedServiceUsesEnclosingAppResources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Trano.app")
        let resources = app.appendingPathComponent("Contents/Resources/Remote")
        let service = app.appendingPathComponent("Contents/Helpers/Trano Service.app")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: service.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("#!/bin/sh\n".utf8).write(to: resources.appendingPathComponent("install-remote.sh"))
        XCTAssertEqual(RemoteInstaller.bundledResources(bundleURL: service, executableURL: service.appendingPathComponent("Contents/MacOS/TranoApp")).path, resources.path)
        XCTAssertEqual(RemoteInstaller.bundledResources(bundleURL: app, executableURL: app.appendingPathComponent("Contents/MacOS/trano")).path, resources.path)
    }

    // Implements: FR-REMOTE-INSTALL-1
    func testProbeRejectsUnsupportedAndSeparatesUnmanagedInstallation() throws {
        let ready = try RemoteInstallationStatus.parse("os=Linux\narch=aarch64\ntmux=1\nhelper=managed\n")
        XCTAssertEqual(ready.architecture, "arm64")
        XCTAssertEqual(ready.state, .ready)
        let conflict = try RemoteInstallationStatus.parse("os=Linux\narch=x86_64\ntmux=1\nhelper=unmanaged\n")
        XCTAssertEqual(conflict.state, .conflict)
        XCTAssertEqual(try RemoteInstallationStatus.parse("os=Darwin\narch=arm64\ntmux=1\nhelper=missing\n").state, .unsupported)
        XCTAssertThrowsError(try RemoteInstallationStatus.parse("random login output"))
    }

    // Implements: FR-REMOTE-INSTALL-1
    func testBundledInstallerChecksHashBeforeSSHMutation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("linux-arm64"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("binary".utf8).write(to: root.appendingPathComponent("linux-arm64/trano-server"))
        try Data(String(repeating: "0", count: 64).utf8).write(to: root.appendingPathComponent("linux-arm64/trano-server.sha256"))
        try Data("#!/bin/sh\n".utf8).write(to: root.appendingPathComponent("install-remote.sh"))
        XCTAssertThrowsError(try RemoteInstaller(resources: root).verifiedPackage(architecture: "arm64"))
        XCTAssertThrowsError(try RemoteInstaller(resources: root).verifiedPackage(architecture: "../arm64"))
    }
}
