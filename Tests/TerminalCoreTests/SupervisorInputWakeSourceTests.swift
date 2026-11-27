import Darwin
import Foundation
import XCTest
@testable import TerminalCore

final class SupervisorInputWakeSourceTests: XCTestCase {
    // Implements: FR-SUP-7
    func testOwnedChildMetadataWriteIsAnInputOnlyWake() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("input-state")
        XCTAssertEqual(Darwin.mkdir(child.path, 0o700), 0)
        let file = child.appendingPathComponent("terminal-input.json")
        try Data("{}".utf8).write(to: file)
        let source = try SupervisorDirectoryWakeSource(root: root)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { try? Data("{\"changed\":true}".utf8).write(to: file, options: .atomic) }
        XCTAssertTrue(try source.wait(timeout: 1))
        XCTAssertTrue(source.inputOnlyWake)
    }

    // Implements: FR-SUP-7
    func testRootWakeRegistersInitiallyAbsentChildWithoutAdoptingSymlinks() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try SupervisorDirectoryWakeSource(root: root)
        let child = root.appendingPathComponent("input-state")
        XCTAssertEqual(Darwin.mkdir(child.path, 0o700), 0)
        XCTAssertTrue(try source.wait(timeout: 1))
        XCTAssertFalse(source.inputOnlyWake)
        let file = child.appendingPathComponent("terminal-input.json")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { try? Data("{}".utf8).write(to: file, options: .atomic) }
        XCTAssertTrue(try source.wait(timeout: 1))
        XCTAssertTrue(source.inputOnlyWake)
        let unsafe = try directory()
        defer { try? FileManager.default.removeItem(at: unsafe) }
        try FileManager.default.createSymbolicLink(at: unsafe.appendingPathComponent("input-state"), withDestinationURL: child)
        XCTAssertThrowsError(try SupervisorDirectoryWakeSource(root: unsafe))
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trano-wake-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
}
