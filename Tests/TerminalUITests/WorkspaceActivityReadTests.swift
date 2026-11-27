import AppKit
import XCTest
@testable import TerminalCore
@testable import TranoApp

@MainActor final class WorkspaceActivityReadTests: XCTestCase {
    // Implements: FR-WSACT-2, FR-ACTIVITY-1
    func testSelectingWorkspaceReadsEveryTabAndSplitWithoutReadingOtherWorkspaces() async throws {
        let f = try Fixture(); defer { f.close() }
        let before = try f.runtime.state()
        f.store.selectWorkspace(f.target)
        await drain(f.store)
        try assertTargetRead(f)
        let after = try f.runtime.state()
        XCTAssertEqual(after.sessions, before.sessions)
        XCTAssertEqual(after.layout.tabs.map(\.tree), before.layout.tabs.map(\.tree))
        XCTAssertEqual(after.settings, before.settings)
        XCTAssertEqual(after.events, before.events)
        XCTAssertEqual(after.sessions.map { $0.activity.state }, [.done, .done, .blocked, .error])
    }

    // Implements: FR-WSACT-2, FR-ACTIVITY-1
    func testReselectingCurrentWorkspaceReadsItsNewNotifications() async throws {
        let f = try Fixture(); defer { f.close() }
        try f.runtime.update { try $0.layout.selectWorkspace(f.target) }
        f.store.state = try f.runtime.state()
        f.store.selectWorkspace(f.target)
        await drain(f.store)
        try assertTargetRead(f)
    }

    // Implements: FR-WSACT-2, FR-ACTIVITY-1
    func testKeyboardWorkspaceCycleReadsTheEnteredWorkspace() async throws {
        let f = try Fixture(); defer { f.close() }
        f.store.execute(.nextSession)
        await drain(f.store)
        try assertTargetRead(f)
    }

    // Implements: FR-WSACT-2, FR-ACTIVITY-1
    func testCapturedNavigationReadsTargetAndLeavesOtherActivityUnread() async throws {
        let f = try Fixture(); defer { f.close() }
        var snapshot = try f.runtime.state()
        try snapshot.layout.selectWorkspace(f.target)
        f.store.applyCapturedNavigation(snapshot, sessions: snapshot.sessions)
        await drain(f.store)
        try assertTargetRead(f)
    }

    // Implements: FR-WSACT-2, FR-ACTIVITY-1
    func testNewEventBeforeQueuedReceiptRemainsUnread() async throws {
        let f = try Fixture(); defer { f.close() }
        f.store.queue.suspend()
        var suspended = true
        defer { if suspended { f.store.queue.resume() } }
        var snapshot = try f.runtime.state()
        try snapshot.layout.selectWorkspace(f.target)
        f.store.applyCapturedNavigation(snapshot, sessions: snapshot.sessions)
        try f.runtime.update { $0.sessions[1].activity.updatedAt = f.date.addingTimeInterval(1) }
        suspended = false; f.store.queue.resume()
        await drain(f.store)
        let state = try f.runtime.state()
        XCTAssertNil(state.activityReadAt[f.rows[1].id])
        XCTAssertEqual(state.activityReadAt[f.rows[2].id], f.date)
        XCTAssertEqual(state.activityReadAt[f.rows[3].id], f.date)
        XCTAssertNil(state.activityReadAt[f.rows[0].id])
    }

    // Implements: FR-WSACT-2, FR-ACTIVITY-1
    func testRefreshingSameWorkspaceDoesNotConsumeANewEvent() async throws {
        let f = try Fixture(); defer { f.close() }
        var snapshot = try f.runtime.state()
        try snapshot.layout.selectWorkspace(f.target)
        f.store.applyCapturedNavigation(snapshot, sessions: snapshot.sessions)
        await drain(f.store)
        try assertTargetRead(f)
        try f.runtime.update { $0.sessions[1].activity.updatedAt = f.date.addingTimeInterval(1) }
        snapshot = try f.runtime.state()
        try snapshot.layout.selectWorkspace(f.target)
        f.store.applyCapturedNavigation(snapshot, sessions: snapshot.sessions)
        await drain(f.store)
        XCTAssertEqual(try f.runtime.state().activityReadAt[f.rows[1].id], f.date)
        XCTAssertTrue(ActivityInbox.isUnread(f.store.sessions[1], readAt: f.store.state.activityReadAt[f.rows[1].id]))
    }

    private func assertTargetRead(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        let persisted = try f.runtime.state().activityReadAt
        XCTAssertEqual(f.store.state.layout.selectedWorkspaceID, f.target, file: file, line: line)
        for row in f.rows.dropFirst() {
            XCTAssertEqual(persisted[row.id], f.date, file: file, line: line)
            XCTAssertEqual(f.store.state.activityReadAt[row.id], f.date, file: file, line: line)
            XCTAssertFalse(ActivityInbox.isUnread(row, readAt: f.store.state.activityReadAt[row.id]), file: file, line: line)
        }
        XCTAssertNil(persisted[f.rows[0].id], file: file, line: line)
        XCTAssertEqual(Set(f.store.activityIndicatorEvents.keys), [.pane(f.rows[0].id, ActivityState.done.rawValue)], file: file, line: line)
        XCTAssertTrue(f.store.terminalViews.isEmpty, file: file, line: line)
        XCTAssertEqual(try TerminalRuntime(root: f.root).state().activityReadAt, persisted, file: file, line: line)
    }

    private func drain(_ store: AppStore) async {
        for _ in 0..<4 {
            await withCheckedContinuation { continuation in
                store.queue.async { DispatchQueue.main.async { continuation.resume() } }
            }
        }
    }

    @MainActor private final class Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let store: AppStore
        let target: String
        let rows: [TerminalSession]
        let date = Date(timeIntervalSince1970: 1_800_000_000)

        init() throws {
            _ = NSApplication.shared
            root = URL(fileURLWithPath: "/tmp/t-read-" + UUID().uuidString.prefix(8))
            runtime = try TerminalRuntime(root: root)
            let cwd = root.path, timestamp = date
            let fixtureRows = [ActivityState.done, .done, .blocked, .error].map { state in
                var row = TerminalSession(id: UUID().uuidString.lowercased(), title: "Fixture", cwd: cwd, pid: 0, alive: false)
                row.activity.state = state; row.activity.updatedAt = timestamp
                return row
            }
            rows = fixtureRows
            var layout = WorkspaceLayout()
            let other = layout.addWorkspace(title: "other-session")
            layout.addTab(paneID: rows[0].id)
            target = layout.addWorkspace(title: "target-session")
            let tab = layout.addTab(paneID: rows[1].id)
            try layout.split(tabID: tab, paneID: rows[2].id, axis: .horizontal)
            layout.addTab(paneID: rows[3].id)
            try layout.selectWorkspace(other)
            try runtime.update { $0.sessions = fixtureRows; $0.layout = layout; $0.settings.automaticRestore = false }
            store = AppStore(runtime: runtime, startServices: false)
            store.state = try runtime.state(); store.sessions = rows
        }

        func close() { try? FileManager.default.removeItem(at: root) }
    }
}
