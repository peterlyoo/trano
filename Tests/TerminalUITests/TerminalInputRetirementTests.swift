import AppKit
import XCTest
@testable import TerminalCore
@testable import TranoApp

@MainActor final class TerminalInputRetirementTests: XCTestCase {
    // Implements: FR-QUEUE-5
    func testClosingTabDropsQueuedProtocolReplyWithoutAlertingTheRemainingTab() async throws {
        let f = try Fixture(); defer { f.close() }
        f.view.send(source: f.view, data: Array("\u{1b}[0n".utf8)[...])
        f.retireTab()
        try await waitForUncertainty(f)
        XCTAssertNil(f.store.message, "A retired tab must not publish its transport failure over the remaining tab")
        XCTAssertEqual(f.store.state.layout.selectedTabID, f.remainingTab)
        XCTAssertNil(f.store.terminalViews[f.binding.paneID])
        try f.assertRemainingInputUnchanged()
    }

    // Implements: FR-QUEUE-5
    func testClosingTabRetainsUnsentDraftUncertaintyWithoutShowingAnErrorOnAnotherTab() async throws {
        let f = try Fixture(); defer { f.close() }
        f.view.send(txt: "draft")
        f.retireTab()
        try await waitForUncertainty(f)
        XCTAssertNil(f.store.message)
        XCTAssertEqual(try f.readiness(), .inputReviewRequired, "Closing a view must not certify unsent text as clean")
        try f.assertRemainingInputUnchanged()
    }

    // Implements: FR-QUEUE-5
    func testReinstallingTheSameViewAndBindingRejectsTheOldRelayCallback() async throws {
        let f = try Fixture(); defer { f.close() }
        f.view.send(txt: "draft")
        f.view.paneID = "retired-binding"
        f.view.paneID = f.binding.paneID
        f.view.installTerminalInputRelay(store: f.store, id: f.binding.paneID, expectedPID: f.binding.backendPID)
        try await waitForUncertainty(f)
        XCTAssertTrue(f.store.terminalViews[f.binding.paneID] === f.view)
        XCTAssertNil(f.store.message, "The same binding can belong to a later relay lifetime")
        try f.assertRemainingInputUnchanged()
    }

    // Implements: FR-QUEUE-5
    func testActiveTerminalStillReportsUnconfirmedUserInput() async throws {
        let f = try Fixture(); defer { f.close() }
        f.view.send(txt: "draft")
        try await waitForUncertainty(f)
        XCTAssertEqual(f.store.message, "Terminal input could not be confirmed. Review the terminal before resuming queued input.")
        XCTAssertEqual(try f.readiness(), .inputReviewRequired)
        try f.assertRemainingInputUnchanged()
    }

    // Implements: FR-QUEUE-5
    func testRetiredViewRejectsLateUserEventsWithoutShowingReconnectErrors() async throws {
        let f = try Fixture(); defer { f.close() }
        f.retireTab()
        f.view.send(txt: "late event")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(f.store.message)
        try f.assertRemainingInputUnchanged()
    }

    // Implements: FR-QUEUE-5
    func testReinstalledRelayRejectsAnAlreadyQueuedReconnectWarning() async throws {
        let f = try Fixture(); defer { f.close() }
        f.view.paneID = "reconnecting"
        f.view.paneID = f.binding.paneID
        f.view.send(txt: "during reconnect")
        f.view.installTerminalInputRelay(store: f.store, id: f.binding.paneID, expectedPID: f.binding.backendPID)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(f.store.message)
        try f.assertRemainingInputUnchanged()
    }

    // Implements: FR-QUEUE-5
    func testCurrentReconnectingViewStillReportsRejectedInput() async throws {
        let f = try Fixture(); defer { f.close() }
        f.view.paneID = "reconnecting"
        f.view.paneID = f.binding.paneID
        f.view.send(txt: "during reconnect")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(f.store.message, "Terminal is reconnecting. Try input again when it is ready.")
        try f.assertRemainingInputUnchanged()
    }

    // Implements: FR-QUEUE-5
    func testRejectedInputRefreshesSessionsToDriveReconnect() async throws {
        let f = try Fixture(); defer { f.close() }
        XCTAssertTrue(f.store.sessions.allSatisfy(\.alive))
        f.view.paneID = "reconnecting"
        f.view.paneID = f.binding.paneID
        f.view.send(txt: "during reconnect")
        let deadline = Date().addingTimeInterval(2)
        while f.store.sessions.contains(where: \.alive), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(f.store.sessions.allSatisfy { !$0.alive }, "Rejected input must reload sessions from the runtime")
        XCTAssertEqual(f.store.message, TranoView.reconnectingMessage)
        try f.assertRemainingInputUnchanged()
    }

    private func waitForUncertainty(_ f: Fixture) async throws {
        let deadline = Date().addingTimeInterval(2)
        while try f.readiness() != .inputReviewRequired, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(try f.readiness(), .inputReviewRequired)
        try await Task.sleep(for: .milliseconds(50))
    }

    @MainActor private final class Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let store: AppStore
        let view: TranoView
        let binding: TerminalInputBinding
        let remainingBinding: TerminalInputBinding
        let remainingLease: TerminalInputLease
        let sourceTab: String
        let remainingTab: String

        init() throws {
            _ = NSApplication.shared
            root = URL(fileURLWithPath: "/tmp/trano-retire-" + UUID().uuidString.prefix(8))
            runtime = try TerminalRuntime(root: root)
            let source = TerminalSession(id: UUID().uuidString.lowercased(), title: "Closing", cwd: root.path, pid: 100)
            let remaining = TerminalSession(id: UUID().uuidString.lowercased(), title: "Remaining", cwd: root.path, pid: 101)
            var launch = AgentLaunch(paneID: source.id, provider: .claude, cwd: root.path, accountID: nil,
                configurationRoot: root.path, bootID: "unit")
            launch.providerPID = 200; launch.processID = 150
            var otherLaunch = AgentLaunch(paneID: remaining.id, provider: .codex, cwd: root.path, accountID: nil,
                configurationRoot: root.path, bootID: "unit")
            otherLaunch.providerPID = 201; otherLaunch.processID = 151
            binding = TerminalInputBinding(paneID: source.id, backendPID: 100, generation: launch.id, providerPID: 200)
            remainingBinding = TerminalInputBinding(paneID: remaining.id, backendPID: 101, generation: otherLaunch.id, providerPID: 201)
            var layout = WorkspaceLayout()
            layout.addWorkspace(title: "unit-workspace")
            sourceTab = layout.addTab(paneID: source.id)
            remainingTab = layout.addTab(paneID: remaining.id)
            try layout.selectTab(sourceTab)
            try runtime.update { state in
                state.settings.automaticRestore = false
                state.sessions = [source, remaining]; state.agentLaunches = [launch, otherLaunch]; state.layout = layout
            }
            var ledger = TerminalInputLedger()
            for item in [binding, remainingBinding] {
                let receipt = try ledger.beginManualWrite(binding: item, submissionCandidate: true)
                XCTAssertTrue(ledger.finishWrite(receipt, succeeded: true))
                XCTAssertTrue(ledger.observeTrustedSubmit(binding: item))
            }
            remainingLease = try XCTUnwrap(ledger.readiness(binding: remainingBinding).lease)
            try TerminalInputLedgerStore(root: root).save(ledger)
            store = AppStore(runtime: runtime, externalBinding: SupervisorBinding(paneID: source.id, backendPID: 100,
                configuration: SupervisorConfiguration(provider: .claude, cwd: root.path)))
            store.state = try runtime.state(); store.sessions = [source, remaining]
            view = TranoView.makeClipboardTerminal(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
            view.store = store; view.paneID = source.id; store.terminalViews[source.id] = view
            view.installTerminalInputRelay(store: store, id: source.id, expectedPID: 100)
            XCTAssertFalse(view.process.running, "This native component fixture must not start terminal jobs")
        }

        func retireTab() {
            store.state.layout.closeTab(sourceTab)
            store.terminalViews.removeValue(forKey: binding.paneID)
            view.terminate()
        }
        func readiness() throws -> TerminalInputReadiness {
            try runtime.terminalInputReadiness(paneID: binding.paneID, generation: binding.generation)
        }
        func assertRemainingInputUnchanged() throws {
            XCTAssertEqual(try runtime.terminalInputReadiness(paneID: remainingBinding.paneID, generation: remainingBinding.generation).lease, remainingLease)
            XCTAssertFalse(view.process.running)
        }
        func close() {
            store.terminalViews.removeAll()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
