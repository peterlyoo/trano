import XCTest
@testable import TerminalCore

final class ScrollbackTests: XCTestCase {
    // Implements: FR-RECOVERY-SCROLLBACK-1
    func testBoundedUnicodeArchiveAndControlSafeReplay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScrollbackStore(runtimeRoot: root), pane = UUID().uuidString.lowercased()
        let text = String(repeating: "한글 line\n", count: 12_000) + "끝\u{1B}]52;c;clipboard\u{7}\u{009B}31m\n"
        try store.save(paneID: pane, text: text)
        let replay = try store.replay(paneID: pane)
        XCTAssertTrue(replay.contains("한글"))
        XCTAssertTrue(replay.contains("끝"))
        XCTAssertFalse(replay.contains("\u{1B}"))
        XCTAssertFalse(replay.contains("\u{009B}"))
        XCTAssertLessThanOrEqual(replay.split(separator: "\n", omittingEmptySubsequences: false).count, 10_000)
        let metadata = try XCTUnwrap(store.metadata(paneID: pane))
        XCTAssertEqual(metadata.byteCount, replay.utf8.count)
        XCTAssertLessThanOrEqual(metadata.byteCount, 4 * 1024 * 1024)
        XCTAssertEqual(metadata.paneID, pane)
        try store.remove(paneID: pane)
        XCTAssertEqual(try store.replay(paneID: pane), "")
        XCTAssertNil(try store.metadata(paneID: pane))
    }

    // Implements: FR-RECOVERY-SCROLLBACK-1
    func testArchiveRefusesSymlinksAndResanitizesTamperedPayload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScrollbackStore(runtimeRoot: root), pane = UUID().uuidString.lowercased()
        try store.save(paneID: pane, text: "abc")
        let file = root.appendingPathComponent("scrollback/" + pane + ".snapshot")
        var data = try Data(contentsOf: file)
        data.replaceSubrange(data.count - 3..<data.count, with: [27, 91, 109])
        try data.write(to: file)
        XCTAssertEqual(try store.replay(paneID: pane), "[m")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("private"))
        XCTAssertThrowsError(try store.replay(paneID: pane))
        XCTAssertThrowsError(try store.save(paneID: "../escape", text: "data"))
    }
}
