import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp

@MainActor final class ActivityUnreadIndicatorTests: XCTestCase {
    // Implements: FR-ACTIVITY-1
    func testUnreadCompletionBadgeIsLegibleAndPaintedAtItsNativeMarker() async throws {
        for scheme in [InterfaceColorScheme.dark, .light] {
            let f = try Fixture(scheme: scheme); defer { f.close() }
            try await settle(f)
            let badge = try XCTUnwrap(region("activity-unread-" + f.unreadID, in: f.host))
            let rect = badge.convert(badge.bounds, to: f.host)
            XCTAssertTrue(f.host.bounds.contains(rect))
            XCTAssertGreaterThanOrEqual(rect.width, 8); XCTAssertGreaterThanOrEqual(rect.height, 8)
            let bitmap = try capture(f.host, name: "unread-" + scheme.rawValue)
            let x = Int(rect.midX * CGFloat(bitmap.pixelsWide) / f.host.bounds.width)
            let y = Int((f.host.isFlipped ? rect.midY : f.host.bounds.height - rect.midY) * CGFloat(bitmap.pixelsHigh) / f.host.bounds.height)
            let pixel = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(pixel.alphaComponent, 0.8)
            XCTAssertGreaterThan(pixel.blueComponent, pixel.redComponent + 0.15,
                                 "Unread blue paint must stand out from the orange agent artwork and opaque panel background")
            XCTAssertGreaterThan(pixel.blueComponent, pixel.greenComponent + 0.08)
            XCTAssertNotNil(region("activity-section-done", in: f.host))
            XCTAssertNil(region("activity-unread-" + f.readID, in: f.host))
            XCTAssertNil(region("activity-unread-" + f.runningID, in: f.host))
            XCTAssertEqual(try f.runtime.state().activityReadAt, f.initialReadAt)
            XCTAssertTrue(f.store.terminalViews.isEmpty)
        }
    }

    // Implements: FR-ACTIVITY-1
    func testObservingOneCompletionRemovesOnlyItsDotAndNewerCompletionBecomesUnread() async throws {
        let f = try Fixture(); defer { f.close() }
        try await settle(f)
        XCTAssertNotNil(region("activity-unread-" + f.unreadID, in: f.host))
        f.store.state.activityReadAt[f.unreadID] = f.date
        try await settle(f)
        XCTAssertNil(region("activity-unread-" + f.unreadID, in: f.host))
        XCTAssertEqual(f.store.state.activityReadAt[f.readID], f.date)
        let index = try XCTUnwrap(f.store.sessions.firstIndex { $0.id == f.unreadID })
        f.store.sessions[index].activity.updatedAt = f.date.addingTimeInterval(1)
        try await settle(f)
        XCTAssertNotNil(region("activity-unread-" + f.unreadID, in: f.host))
        XCTAssertNil(region("activity-unread-" + f.readID, in: f.host))
        XCTAssertEqual(try f.runtime.state().activityReadAt, f.initialReadAt)
    }

    // Implements: FR-ACTIVITY-1
    func testViewingInboxClearsHeaderButKeepsUnreadRowsAndNewEventsRelightIt() async throws {
        let f = try Fixture(shown: false); defer { f.close() }
        try await settle(f)
        XCTAssertTrue(f.store.activityNeedsAttention)
        f.store.showActivity = true; try await settle(f)
        XCTAssertFalse(f.store.activityNeedsAttention, "Viewing the inbox must clear its new-activity marker")
        XCTAssertNotNil(region("activity-unread-" + f.unreadID, in: f.host))
        XCTAssertNil(f.store.state.activityReadAt[f.unreadID])
        f.store.showActivity = false; try await settle(f)
        XCTAssertFalse(f.store.activityNeedsAttention, "Closing must not relight the same event")
        let index = try XCTUnwrap(f.store.sessions.firstIndex { $0.id == f.unreadID })
        f.store.sessions[index].activity.updatedAt = f.date.addingTimeInterval(1)
        try await settle(f); XCTAssertTrue(f.store.activityNeedsAttention)
        f.store.showActivity = true; try await settle(f)
        XCTAssertFalse(f.store.activityNeedsAttention)
        XCTAssertNotNil(region("activity-unread-" + f.unreadID, in: f.host))
        XCTAssertEqual(try f.runtime.state().activityReadAt, f.initialReadAt)
    }

    // Implements: FR-ACTIVITY-1
    func testNewlyPresentedEventsInAnOpenInboxDoNotLeaveItsHeaderLit() async throws {
        let f = try Fixture(); defer { f.close() }
        try await settle(f); XCTAssertFalse(f.store.activityNeedsAttention)
        let index = try XCTUnwrap(f.store.sessions.firstIndex { $0.id == f.unreadID })
        f.store.sessions[index].activity.updatedAt = f.date.addingTimeInterval(1)
        try await settle(f)
        XCTAssertFalse(f.store.activityNeedsAttention)
        XCTAssertNotNil(region("activity-unread-" + f.unreadID, in: f.host))
        XCTAssertEqual(try f.runtime.state().activityReadAt, f.initialReadAt)
    }

    // Implements: FR-ACTIVITY-1
    func testObservedBlockedAndErrorItemsClearTheirUnreadDotsWhileAttentionRemains() async throws {
        let f = try Fixture(); defer { f.close() }
        let index = try XCTUnwrap(f.store.sessions.firstIndex { $0.id == f.unreadID })
        for state in [ActivityState.blocked, .error] {
            f.store.sessions[index].activity.state = state
            f.store.state.activityReadAt[f.unreadID] = f.date.addingTimeInterval(-1)
            try await settle(f)
            XCTAssertNotNil(region("activity-unread-" + f.unreadID, in: f.host))
            f.store.state.activityReadAt[f.unreadID] = f.date
            try await settle(f)
            XCTAssertNil(region("activity-unread-" + f.unreadID, in: f.host))
            XCTAssertNotNil(region("activity-section-" + (state == .blocked ? "attention" : "error"), in: f.host))
            XCTAssertTrue(ActivityInbox.needsAttention(f.store.sessions[index], readAt: f.date))
        }
        XCTAssertEqual(try f.runtime.state().activityReadAt, f.initialReadAt)
    }

    // Implements: FR-ACTIVITY-1, FR-WT-5
    func testWorktreeAlertsFollowTheSameInboxSeenBoundaryWithoutChangingTheirStatus() async throws {
        let f = try Fixture(shown: false); defer { f.close() }
        f.store.state.activityReadAt[f.unreadID] = f.date
        let owner = WorktreeOwner(paneID: f.unreadID, generation: "fixture", backendPID: 4711,
            processIdentity: SupervisorProcessIdentity(pid: 4711, ownerUID: 1, startedAtSeconds: 1, startedAtMicroseconds: 1))
        let inode = WorktreeFileIdentity(device: 1, inode: 1)
        let identity = WorktreeIdentity(path: "/tmp/fixture-worktree", commonDirectory: "/tmp/fixture-common", adminDirectory: "/tmp/fixture-admin",
            pathIdentity: inode, gitFileIdentity: inode, adminIdentity: inode, commonIdentity: inode)
        f.store.worktreeCleanupRecords = [WorktreeCleanupRecord(id: "fixture", owner: owner, identity: identity, createdAt: f.date, status: .held)]
        try await settle(f); XCTAssertTrue(f.store.activityNeedsAttention)
        f.store.showActivity = true; try await settle(f)
        XCTAssertFalse(f.store.activityNeedsAttention)
        XCTAssertEqual(f.store.worktreeCleanupRecords[0].status, .held)
        f.store.showActivity = false; try await settle(f)
        XCTAssertFalse(f.store.activityNeedsAttention)
        f.store.worktreeCleanupRecords[0].updatedAt = f.date.addingTimeInterval(1)
        try await settle(f); XCTAssertTrue(f.store.activityNeedsAttention)
        XCTAssertEqual(try f.runtime.state().activityReadAt, f.initialReadAt)
    }

    private struct InboxHost: View {
        @ObservedObject var store: AppStore
        var body: some View {
            Group {
                if store.showActivity { ActivityListView(store: store) }
                else { Color.clear }
            }
        }
    }

    @MainActor private final class Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let store: AppStore
        let host: NSHostingView<InboxHost>
        let window: NSWindow
        let unreadID = UUID().uuidString.lowercased()
        let readID = UUID().uuidString.lowercased()
        let runningID = UUID().uuidString.lowercased()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let initialReadAt: [String: Date]

        init(scheme: InterfaceColorScheme = .dark, shown: Bool = true) throws {
            _ = NSApplication.shared
            root = URL(fileURLWithPath: "/tmp/trano-act-" + UUID().uuidString.prefix(8))
            runtime = try TerminalRuntime(root: root)
            var unread = TerminalSession(id: unreadID, title: "Unread completion", cwd: "/tmp/workflow", pid: 4711, agent: .claude)
            unread.activity.state = .done; unread.activity.updatedAt = date
            var read = TerminalSession(id: readID, title: "Observed completion", cwd: "/tmp/another", pid: 4712, agent: .codex)
            read.activity.state = .done; read.activity.updatedAt = date
            var running = TerminalSession(id: runningID, title: "Working session", cwd: "/tmp/workflow", pid: 4713, agent: .codex)
            running.activity.state = .running
            let sessions = [unread, read, running]
            let readAt = [readID: date]
            initialReadAt = readAt
            try runtime.update { state in
                state.settings.automaticRestore = false; state.sessions = sessions; state.activityReadAt = readAt
                for row in sessions { state.layout.addTab(paneID: row.id) }
            }
            let binding = SupervisorBinding(paneID: unreadID, backendPID: 4711,
                configuration: SupervisorConfiguration(provider: .claude, cwd: root.path))
            store = AppStore(runtime: runtime, externalBinding: binding)
            store.state = try runtime.state(); store.sessions = sessions; store.showActivity = shown
            store.interfacePreferences.colorScheme = scheme; store.interfacePreferences.tintWithTheme = false
            host = NSHostingView(rootView: InboxHost(store: store))
            window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 340, height: 400), styleMask: [], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.animationBehavior = .none; window.contentView = host
            window.orderFrontRegardless()
        }
        func close() {
            window.contentView = nil; window.close(); try? FileManager.default.removeItem(at: root)
        }
    }

    private func region(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { self.region(id, in: $0) }.first
    }
    private func settle(_ f: Fixture) async throws {
        for _ in 0..<4 { f.host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    }
    private func capture(_ view: NSView, name: String) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let destination = ProcessInfo.processInfo.environment["TRANO_ACTIVITY_CAPTURE_DIR"] {
            let root = URL(fileURLWithPath: destination)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent(name + ".png"))
        }
        return bitmap
    }
}
