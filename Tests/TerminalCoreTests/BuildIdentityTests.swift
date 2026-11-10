import XCTest
@testable import TerminalCore

final class BuildIdentityTests: XCTestCase {
    // Implements: FR-UPDATE-2
    func testSameVersionDifferentSourceRequiresHelperReplacement() {
        let first = BuildIdentity(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1", "TranoBuildID": String(repeating: "a", count: 64)])
        let next = BuildIdentity(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1", "TranoBuildID": String(repeating: "b", count: 64)])
        XCTAssertNotEqual(first, next)
        XCTAssertEqual(ServiceHandoffPolicy.action(expected: next, running: first, kind: "background"), .replace)
        XCTAssertEqual(ServiceHandoffPolicy.action(expected: next, running: next, kind: "background"), .keep)
        XCTAssertEqual(ServiceHandoffPolicy.action(expected: next, running: first, kind: "cli"), .keep)
        XCTAssertEqual(ServiceHandoffPolicy.action(expected: next, running: nil, kind: nil), .manualRestart)
    }

    // Implements: FR-UPDATE-2
    func testCapturedIdentitySurvivesBundleMetadataReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trano-build-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Info.plist")
        func write(_ id: String) throws {
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "2", "TranoBuildID": id], format: .xml, options: 0).write(to: url)
        }
        try write(String(repeating: "a", count: 64))
        let captured = try BuildIdentity(metadataURL: url)
        try write(String(repeating: "b", count: 64))
        XCTAssertEqual(captured.buildID, String(repeating: "a", count: 64))
        XCTAssertNotEqual(captured, try BuildIdentity(metadataURL: url))
        XCTAssertEqual(captured.version, "0.2.0")
        XCTAssertEqual(captured.buildNumber, "2")
    }

    // Implements: FR-UPDATE-2
    func testBuildNumberChangeAlsoRequiresReplacementAndUnknownMetadataFailsClosed() {
        let info: [String: Any] = ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1", "TranoBuildID": String(repeating: "a", count: 64)]
        var other = info; other["CFBundleVersion"] = "2"
        XCTAssertEqual(ServiceHandoffPolicy.action(expected: BuildIdentity(info: other), running: BuildIdentity(info: info), kind: "background"), .replace)
        XCTAssertEqual(ServiceHandoffPolicy.action(expected: BuildIdentity(info: [:]), running: BuildIdentity(info: info), kind: "background"), .manualRestart)
    }
}
