import XCTest
@testable import TerminalCore

final class ActivityInboxTests: XCTestCase {
    // Implements: FR-ACTIVITY-1
    func testSectionsGroupStatesAndKeepNewestFirst() {
        var rows: [TerminalSession] = []
        for (i, state) in [ActivityState.idle, .done, .blocked, .running, .error, .done, .unknown].enumerated() {
            var row = TerminalSession(id: "pane-\(i)", title: "Pane \(i)", cwd: "/tmp", pid: 0)
            row.activity.state = state
            row.activity.updatedAt = Date(timeIntervalSince1970: Double(i))
            rows.append(row)
        }
        let sections = ActivityInbox.sections(rows)
        XCTAssertEqual(sections.map(\.title), ["Done", "Error", "Blocked", "Working", "Idle"],
                       "The section holding the newest item that needs attention comes first")
        XCTAssertEqual(sections.map { $0.sessions.map(\.id) }, [["pane-5", "pane-1"], ["pane-4"], ["pane-2"], ["pane-3"], ["pane-6", "pane-0"]])
        XCTAssertEqual(sections.first?.sessions.first?.id, "pane-5", "Newest unread completion is the top row")
        XCTAssertTrue(ActivityInbox.sections([]).isEmpty)
        let read = ActivityInbox.sections(rows, readAt: ["pane-5": Date(timeIntervalSince1970: 10)])
        XCTAssertEqual(read.map(\.title), ["Error", "Blocked", "Done", "Working", "Idle"], "Rex program activity status names")
        XCTAssertEqual(read.first?.sessions.first?.id, "pane-4", "Once read, the newest remaining attention item leads")
        XCTAssertEqual(read.first { $0.id == "done" }?.sessions.map(\.id), ["pane-1", "pane-5"], "A read completion sorts after unread ones")
        var quiet = rows.filter { [.running, .idle, .unknown].contains($0.activity.state) }
        quiet.sort { $0.id < $1.id }
        XCTAssertEqual(ActivityInbox.sections(quiet).map(\.title), ["Working", "Idle"], "Without attention items the status order stays")
    }

    // Implements: FR-ACTIVITY-1
    func testFilterMatchesTitleDetailStatusAgentAndKoreanLayout() {
        var rows: [TerminalSession] = []
        for (i, state) in [ActivityState.blocked, .done, .running].enumerated() {
            var row = TerminalSession(id: "pane-\(i)", title: ["deploy", "review", "build"][i], cwd: "/tmp", pid: 0, agent: i == 0 ? .claude : .shell)
            row.activity.state = state
            row.activity.updatedAt = Date(timeIntervalSince1970: 100)
            rows.append(row)
        }
        let sections = ActivityInbox.sections(rows)
        let describe: (TerminalSession) -> (title: String, detail: String) = { ($0.title, $0.id == "pane-1" ? "프로젝트 alpha" : "") }
        func ids(_ query: String) -> [String] { ActivityInbox.filter(sections, query: query, describe: describe).flatMap { $0.sessions.map(\.id) } }
        XCTAssertEqual(ids(""), ["pane-0", "pane-1", "pane-2"])
        XCTAssertEqual(ids("  "), ["pane-0", "pane-1", "pane-2"])
        XCTAssertEqual(ids("BUILD"), ["pane-2"])
        XCTAssertEqual(ids("blocked"), ["pane-0"])
        XCTAssertEqual(ids("working"), ["pane-2"])
        XCTAssertEqual(ids("claude"), ["pane-0"])
        XCTAssertEqual(ids("프로젝트"), ["pane-1"])
        XCTAssertEqual(ids("ㅡ"), [], "A lone vowel maps to m; no row contains m")
        XCTAssertEqual(ids("ㄱㄷ퍋ㅈ"), ["pane-1"], "Hangul typed on a Latin layout maps to 'review'")
        XCTAssertEqual(ActivityInbox.filter(sections, query: "build", describe: describe).map(\.id), ["working"])
    }

    // Implements: FR-ACTIVITY-1
    func testReadReceiptPersistsAndCannotAcknowledgeANewerCompletion() throws {
        let root = URL(fileURLWithPath: "/tmp/trano-inbox-" + UUID().uuidString.prefix(6))
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try TerminalRuntime(root: root)
        var row = TerminalSession(id: UUID().uuidString.lowercased(), title: "Codex", cwd: root.path, pid: 0, agent: .codex, alive: false)
        row.activity.state = .done
        row.activity.updatedAt = Date(timeIntervalSince1970: 100)
        try runtime.update { $0.sessions = [row] }
        XCTAssertTrue(ActivityInbox.needsAttention(row, readAt: nil))
        try runtime.acknowledgeActivity(row.id, updatedAt: row.activity.updatedAt)
        let reloaded = try TerminalRuntime(root: root).state()
        XCTAssertFalse(ActivityInbox.needsAttention(row, readAt: reloaded.activityReadAt[row.id]))
        row.activity.updatedAt = Date(timeIntervalSince1970: 200)
        try runtime.update { $0.sessions = [row] }
        try runtime.acknowledgeActivity(row.id, updatedAt: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(ActivityInbox.needsAttention(row, readAt: try runtime.state().activityReadAt[row.id]))
        row.activity.state = .blocked
        XCTAssertTrue(ActivityInbox.needsAttention(row, readAt: Date.distantFuture))
        row.activity.state = .running
        XCTAssertFalse(ActivityInbox.needsAttention(row, readAt: nil))
        XCTAssertTrue(try runtime.state().events.isEmpty)
    }

    // Implements: FR-ACTIVITY-1
    func testLegacyStateLoadsWithoutReadReceipts() throws {
        let data = try JSONEncoder().encode(RuntimeState())
        var payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        payload.removeValue(forKey: "activityReadAt")
        let state = try JSONDecoder().decode(RuntimeState.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertTrue(state.activityReadAt.isEmpty)
    }
}
