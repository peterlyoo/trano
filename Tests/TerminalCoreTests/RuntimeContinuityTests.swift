import XCTest
@testable import TerminalCore

final class RuntimeContinuityTests: XCTestCase {
    // Implements: FR-QUEUE-1, FR-QUEUE-3, FR-ACTIVITY-1
    func testOlderProcessStateRewriteCannotEraseQueueOrReadReceipts() throws {
        let root = URL(fileURLWithPath: "/tmp/trano-cont-" + UUID().uuidString.prefix(6))
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try TerminalRuntime(root: root)
        let pane = TerminalSession(id: UUID().uuidString.lowercased(), title: "Existing shell", cwd: root.path, pid: 0, alive: false)
        let readAt = Date(timeIntervalSince1970: 100)
        try runtime.update { $0.sessions = [pane]; $0.activityReadAt[pane.id] = readAt }
        let input = try runtime.addFollowUp(paneID: pane.id, text: "보관한 입력\n두 번째 줄")
        let primary = root.appendingPathComponent("state.json")
        var legacy = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: primary))
        for key in ["activityReadAt", "followUpInputs", "followUpTurns", "followUpPasteStates"] { legacy.removeValue(forKey: key) }
        try TerminalRuntime.atomicWrite(JSONEncoder().encode(legacy), to: primary)
        let reopened = try TerminalRuntime(root: root)
        XCTAssertEqual(try reopened.followUps(paneID: pane.id).map(\.id), [input.id])
        XCTAssertEqual(try reopened.state().activityReadAt[pane.id], readAt)
        try reopened.removeFollowUp(id: input.id)
        XCTAssertTrue(try TerminalRuntime(root: root).followUps(paneID: pane.id).isEmpty)
    }

    // Implements: FR-QUEUE-1, FR-QUEUE-3
    func testContinuitySidecarRejectsSymlinkWithoutReadingOrReplacingTarget() throws {
        let root = URL(fileURLWithPath: "/tmp/trano-cont-" + UUID().uuidString.prefix(6))
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try TerminalRuntime(root: root)
        try runtime.update { _ in }
        let target = root.appendingPathComponent("untouched")
        let bytes = Data("keep".utf8)
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("continuity.json"), withDestinationURL: target)
        XCTAssertThrowsError(try runtime.state())
        XCTAssertThrowsError(try runtime.update { $0.settings.fontSize = 18 })
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }
}
