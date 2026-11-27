import Darwin
import XCTest
@testable import TerminalCore

final class PessimisticTwinGitPathTests: XCTestCase {
    // Implements: FR-TWIN-2, FR-TWIN-9
    func testCanonicalPrivateFilesystemPathsRetainTheirPhysicalPrefix() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("trano-twin-path-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let pointer = try XCTUnwrap(realpath(fixture.path, nil)); defer { free(pointer) }
        let physical = String(cString: pointer)
        XCTAssertEqual(try WorktreeGitParser.absolute(physical), physical)
        XCTAssertEqual(try WorktreeGitParser.absolute("/private/var/tmp/project"), "/private/var/tmp/project")
        XCTAssertEqual(try WorktreeGitParser.absolute("/private/var/tmp/../project/./"), "/private/var/project")
        XCTAssertEqual(try WorktreeGitParser.absolute("/../../repo//tree"), "/repo/tree")
        XCTAssertThrowsError(try WorktreeGitParser.absolute("relative/path"))
        XCTAssertThrowsError(try WorktreeGitParser.absolute("/repo/\0/path"))
    }
}
