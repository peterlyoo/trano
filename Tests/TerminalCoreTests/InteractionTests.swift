import XCTest
@testable import TerminalCore

final class InteractionTests: XCTestCase {
    // Implements: FR-ACTIVITY-1
    func testActivityFramesSplitAtEveryByteAndDiscardOversizedPayload() throws {
        var scanner = ActivityScanner()
        let frame = "\u{1b}]7501;state=blocked:app=claude:kind=permission:msg=\(Data("승인 요청".utf8).base64EncodedString())\u{7}"
        var reports: [ActivityReport] = []
        for byte in frame.utf8 { reports += scanner.feed(Data([byte])) }
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].state, .blocked)
        XCTAssertEqual(reports[0].agent, .claude)
        XCTAssertEqual(reports[0].reason, "승인 요청")
        XCTAssertTrue(scanner.feed(Data(("\u{1b}]7501;state=done:msg=" + String(repeating: "A", count: 10_000) + "\u{7}").utf8)).isEmpty)
        XCTAssertTrue(scanner.feed(Data("\u{1b}]7501;state=done:msg=/w==\u{7}".utf8)).isEmpty)
        XCTAssertTrue(scanner.feed(Data("\u{1b}]7501;state=oops\u{7}".utf8)).isEmpty)
        let next = scanner.feed(Data("\u{1b}]7501;state=working:app=codex\u{1b}\\".utf8))
        XCTAssertEqual(next.first?.state, .running)
        XCTAssertEqual(next.first?.agent, .codex)
        XCTAssertTrue(scanner.feed(Data("ordinary output: done".utf8)).isEmpty)
    }

    // Implements: FR-ACTIVITY-1, FR-ACTIVITY-2
    func testEventCursorReplayAndEvictionAreExplicit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("at-events-" + UUID().uuidString.prefix(6))
        let runtime = try TerminalRuntime(root: root)
        defer {
            for session in (try? runtime.list()) ?? [] { try? runtime.terminate(session.id) }
            try? FileManager.default.removeItem(at: root)
        }
        let session = try runtime.create(title: "event test", cwd: root.path, shell: "/bin/zsh", arguments: ["-f"])
        for index in 0..<260 { try runtime.report(session.id, state: index % 2 == 0 ? .running : .done, reason: "", agent: .codex) }
        let events = try runtime.events(since: 0)
        XCTAssertEqual(events.events.count, 256)
        XCTAssertTrue(events.resetRequired)
        let current = try runtime.events(since: events.revision)
        XCTAssertTrue(current.events.isEmpty)
        XCTAssertFalse(current.resetRequired)
        try runtime.report(session.id, state: .done, reason: "", agent: .codex)
        XCTAssertEqual(try runtime.events(since: 0).revision, events.revision)
        XCTAssertEqual(try TerminalRuntime(root: root).events(since: 0).revision, events.revision)
    }

    // Implements: FR-INPUT-3
    func testAttachmentLimitsPermissionsAndQuotedPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("at-image-'" + UUID().uuidString.prefix(6))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10]) + Data(repeating: 0, count: 16)
        let saved = try AttachmentStore(root: root).savePNG(png)
        XCTAssertEqual(try Data(contentsOf: saved), png)
        let mode = try FileManager.default.attributesOfItem(atPath: saved.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
        XCTAssertEqual(ShellQuote.quote("a'b"), "'a'\\''b'")
        XCTAssertFalse(ShellQuote.quote(saved.path).contains("\n"))
        XCTAssertThrowsError(try AttachmentStore(root: root).savePNG(Data("not png".utf8)))
        XCTAssertThrowsError(try AttachmentStore(root: root).savePNG(png + Data(repeating: 0, count: 20 * 1024 * 1024)))
    }
}
