import AppKit
@testable import SwiftTerm
import XCTest
@testable import TerminalCore
@testable import TranoApp

@MainActor private final class InterruptInputWindow: NSWindow {
    var reportsKey = true
    override var isVisible: Bool { true }
    override var isKeyWindow: Bool { reportsKey }
}

@MainActor final class InterruptHandoffNativeTests: XCTestCase {
    // Implements: FR-INPUT-1
    func testDoubleInterruptHoldsImmediatelyTypedSuffixWhileAgentStillOwnsTheTerminal() async throws {
        for provider in [AgentKind.claude, .codex] {
            let f = try Fixture(provider: provider); defer { f.close() }
            f.installProbe()
            try f.deliver("\u{3}", key: 8, modifiers: .control, ignoring: "c", time: 10)
            try f.deliver("\u{3}", key: 8, modifiers: .control, ignoring: "c", time: 10.1)
            let before = f.bytes
            let held = try f.deliver("a", key: 0, time: 10.2)
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertTrue(held, "Typing after the exit gesture must wait for this agent to release the shell")
            XCTAssertEqual(f.bytes, before, "The suffix must never reach the exiting provider")
            XCTAssertTrue(f.view.interruptHandoff.isWaiting)
            XCTAssertEqual(before.filter { $0 == 3 }.count, 2, "Both interrupts must reach the provider immediately")
        }
    }
    func testReadyShellReceivesEveryQueuedKeyInOrderAfterKeyboardModesAreRestored() async throws {
        let f = try Fixture(provider: .codex); defer { f.close() }
        f.view.feed(text: "\u{1b}[>3u")
        f.installProbe()
        try f.interruptTwice()
        let prefix = f.bytes
        for (index, value) in ["a", "b", "c", "\r"].enumerated() {
            XCTAssertTrue(try f.deliver(value, key: value == "\r" ? 36 : 0, time: 10.2 + Double(index) * 0.01))
        }
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(f.bytes, prefix, "No typing may reach the provider before the shell owns input")
        f.view.feed(text: "\u{1b}[<u")
        f.makeReady()
        try await f.waitUntilFlushed()
        XCTAssertEqual(Array(f.bytes.dropFirst(prefix.count)), Array("abc\r".utf8))
        XCTAssertEqual(f.replayed, [0, 0, 0, 36])
    }
    func testAShellWithItsOwnKittyKeyboardModeReceivesTypingWithoutWaitingForever() async throws {
        let f = try Fixture(provider: .codex); defer { f.close() }
        f.installProbe(); try f.interruptTwice()
        XCTAssertTrue(try f.deliver("a", key: 0, time: 10.2))
        f.view.feed(text: "\u{1b}[>8u"); f.makeReady()
        try await f.waitUntilFlushed()
        XCTAssertEqual(f.replayed, [0])
        XCTAssertTrue(String(decoding: f.bytes, as: UTF8.self).contains("[97"))
    }
    func testIMECompositionStartedByReplayDoesNotDropTheRemainingQueuedKeys() async throws {
        let f = try Fixture(provider: .claude); defer { f.close() }
        f.installProbe()
        var replayed: [UInt16] = []
        f.view.interruptHandoffReplay = { event in
            replayed.append(event.keyCode)
            if replayed.count == 1 {
                f.view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            } else {
                f.installSpy(); f.view.insertText("한", replacementRange: NSRange(location: NSNotFound, length: 0)); f.view.unmarkText()
            }
        }
        try f.interruptTwice()
        XCTAssertTrue(try f.deliver("g", key: 5, time: 10.2))
        XCTAssertTrue(try f.deliver("k", key: 40, time: 10.3))
        f.makeReady(); try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(replayed, [5, 40])
        XCTAssertTrue(String(decoding: f.bytes, as: UTF8.self).hasSuffix("한"))
    }
    func testSingleInterruptAndAutorepeatDoNotStartAnExitHandoff() throws {
        let f = try Fixture(provider: .claude); defer { f.close() }
        try f.deliver("\u{3}", key: 8, modifiers: .control, ignoring: "c", time: 10)
        XCTAssertFalse(try f.deliver("\u{3}", key: 8, modifiers: .control, ignoring: "c", time: 10.05, repeated: true))
        XCTAssertFalse(f.view.interruptHandoff.isWaiting)
        XCTAssertFalse(try f.deliver("x", key: 7, time: 10.1))
        XCTAssertTrue(String(decoding: f.bytes, as: UTF8.self).hasSuffix("x"))
        XCTAssertFalse(f.view.interruptHandoff.isWaiting)
    }
    func testAdditionalInterruptPassesThroughWhileOrdinaryInputWaits() throws {
        let f = try Fixture(provider: .codex); defer { f.close() }
        try f.interruptTwice(); let before = f.bytes.count
        XCTAssertTrue(try f.deliver("x", key: 7, time: 10.2))
        XCTAssertFalse(try f.deliver("\u{3}", key: 8, modifiers: .control, ignoring: "c", time: 10.3))
        XCTAssertEqual(Array(f.bytes.dropFirst(before)), [3])
    }
    func testAChangedBackendOrNativeResponderNeverReceivesBufferedTyping() async throws {
        for changeBackend in [true, false] {
            let f = try Fixture(provider: .claude); defer { f.close() }
            f.installProbe(); try f.interruptTwice(); let prefix = f.bytes
            XCTAssertTrue(try f.deliver("x", key: 7, time: 10.2))
            if changeBackend { f.store.sessions[0].pid += 1 }
            else { XCTAssertTrue(f.window.makeFirstResponder(nil)) }
            f.makeReady(); try await Task.sleep(for: .milliseconds(160))
            XCTAssertEqual(f.bytes, prefix); XCTAssertTrue(f.replayed.isEmpty)
        }
    }
    func testExitWitnessIsCapturedBeforeTheFirstInterruptCanKillItsProcess() throws {
        let f = try Fixture(provider: .claude); defer { f.close() }
        var capturedBeforeBytes: [Int] = []
        f.view.interruptHandoff.capture = { capturedBeforeBytes.append(f.bytes.count); return f.view.captureInterruptHandoff() }
        try f.interruptTwice()
        XCTAssertEqual(capturedBeforeBytes, [0])
        XCTAssertTrue(f.view.interruptHandoff.isWaiting)
    }
    func testKeyReleasesAreHeldAndReplayedWithoutTriggeringCommandActions() async throws {
        let f = try Fixture(provider: .codex); defer { f.close() }
        f.installProbe(); try f.interruptTwice()
        XCTAssertTrue(try f.deliver("\u{3}", key: 8, modifiers: .control, ignoring: "c", time: 10.11, type: .keyUp))
        XCTAssertTrue(try f.deliver("a", key: 0, time: 10.2))
        XCTAssertTrue(try f.deliver("a", key: 0, time: 10.21, type: .keyUp))
        f.makeReady(); try await f.waitUntilFlushed()
        XCTAssertEqual(f.replayed, [8, 0, 0])
        XCTAssertEqual(f.bytes, [3, 3, 97])
        let tabCount = f.store.state.layout.tabs.count
        XCTAssertFalse(try f.deliver("t", key: 17, modifiers: .command, time: 11, type: .keyUp))
        XCTAssertEqual(f.store.state.layout.tabs.count, tabCount)
    }
    func testBufferedWriteChecksForANewerExitedGenerationAtFinalAdmission() throws {
        let f = try Fixture(provider: .claude); defer { f.close() }
        let admission = TerminalInterruptInputAdmission(); admission.begin([])
        let sent = WriteRecorder()
        let writer = admission.guardWriter(runtime: f.runtime, paneID: f.view.paneID, backendPID: 4711, write: sent.write)
        admission.end()
        var launch = AgentLaunch(paneID: f.view.paneID, provider: .codex, cwd: f.root.path, accountID: nil, configurationRoot: f.root.path, bootID: "unit")
        launch.lifecycle = .exited
        try f.runtime.update { $0.agentLaunches.append(launch) }
        writer.writer([97]) { sent.complete($0) }
        XCTAssertEqual(sent.count, 0); XCTAssertTrue(sent.failed)
        let normal = admission.guardWriter(runtime: f.runtime, paneID: f.view.paneID, backendPID: 4711, write: sent.write)
        normal.writer([98]) { sent.complete($0) }
        XCTAssertEqual(sent.count, 1, "The handoff guard must not remain attached to later normal typing")
    }
    func testEarlierUnguardedTypingCannotAbsorbProtectedReplayInTheSameRelayBatch() async throws {
        let f = try Fixture(provider: .claude); defer { f.close() }
        let admission = TerminalInterruptInputAdmission(); admission.begin([])
        let sent = WriteRecorder()
        let rejected = expectation(description: "protected replay rejects changed generation")
        let runtime = f.runtime, paneID = f.view.paneID, rootPath = f.root.path
        let relay = TerminalInputRelay(delayMilliseconds: 20, deliver: { bytes, _, write, completion in
            write(bytes, completion)
        }, invalidated: { _ in rejected.fulfill() })
        relay.send([97], user: true) { bytes, completion in
            var launch = AgentLaunch(paneID: paneID, provider: .codex, cwd: rootPath, accountID: nil, configurationRoot: rootPath, bootID: "unit")
            launch.lifecycle = .exited
            do { try runtime.update { $0.agentLaunches.append(launch) } }
            catch { completion(.failure(error)); return }
            sent.write(bytes, completion: completion)
        }
        let guarded = admission.guardWriter(runtime: runtime, paneID: paneID, backendPID: 4711, write: sent.write)
        relay.send([98], user: true, coalescingKey: guarded.coalescingKey, write: guarded.writer)
        admission.end()
        await fulfillment(of: [rejected], timeout: 1)
        XCTAssertEqual(sent.bytes, [97])
    }
    private final class WriteRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var writes = 0
        private var payload: [UInt8] = []
        private var failure = false
        var count: Int { lock.lock(); defer { lock.unlock() }; return writes }
        var bytes: [UInt8] { lock.lock(); defer { lock.unlock() }; return payload }
        var failed: Bool { lock.lock(); defer { lock.unlock() }; return failure }
        func write(_ bytes: [UInt8], completion: @escaping TerminalInputRelay.Completion) {
            lock.lock(); writes += 1; payload.append(contentsOf: bytes); lock.unlock(); completion(.success(bytes.count))
        }
        func complete(_ result: Result<Int, Error>) { lock.lock(); if case .failure = result { failure = true }; lock.unlock() }
    }
    @MainActor private final class Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let store: AppStore
        let view: TranoView
        let window: InterruptInputWindow
        let delegate = ApplicationDelegate()
        var bytes: [UInt8] = []
        var status = TerminalShellHandoffStatus.waiting
        var replayed: [UInt16] = []
        init(provider: AgentKind) throws {
            _ = NSApplication.shared
            root = URL(fileURLWithPath: "/tmp/trano-int-" + UUID().uuidString.prefix(8))
            runtime = try TerminalRuntime(root: root)
            let id = UUID().uuidString.lowercased()
            var pane = TerminalSession(id: id, title: "Fixture", cwd: root.path, pid: 4711)
            pane.agent = provider; pane.foregroundProgram = TerminalProgram(agent: provider)
            try runtime.update { $0.sessions = [pane] }
            let binding = SupervisorBinding(paneID: id, backendPID: pane.pid, configuration: SupervisorConfiguration(provider: provider, cwd: root.path))
            store = AppStore(runtime: runtime, externalBinding: binding)
            store.sessions = [pane]; store.state.sessions = [pane]; store.loading = false
            view = TranoView(frame: NSRect(x: 0, y: 0, width: 640, height: 300)); view.frameDriver.invalidate()
            view.interruptHandoffApplicationActive = { true }
            store.terminalViews[id] = view; view.store = store; view.paneID = id
            window = InterruptInputWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view
            XCTAssertTrue(window.makeFirstResponder(view))
            delegate.window = window; delegate.store = store; delegate.windows[window] = store
            installSpy()
        }
        func installSpy() {
            view.setProcessInputHandler { [weak self] bytes, origin, _ in
                guard case .user = origin else { return }
                MainActor.assumeIsolated { self?.bytes.append(contentsOf: bytes) }
            }
        }
        func installProbe() {
            view.interruptHandoffProbe = { [weak self] _, completion in completion(self?.status ?? .changed) }
            view.interruptHandoffReplay = { [weak self] event in
                guard let self else { return }
                replayed.append(event.keyCode); installSpy()
                if event.type == .keyUp { view.keyUp(with: event) } else { view.keyDown(with: event) }
            }
        }
        func makeReady() {
            let binding = TerminalInputBinding(paneID: view.paneID, backendPID: 4711, generation: "terminal:4711")
            status = .ready(TerminalShellHandoffSnapshot(identity: "shell:4711:birth:1", binding: binding, launches: []))
        }
        func interruptTwice() throws {
            try deliver("\u{3}", key: 8, modifiers: .control, ignoring: "c", time: 10)
            try deliver("\u{3}", key: 8, modifiers: .control, ignoring: "c", time: 10.1)
        }
        func waitUntilFlushed() async throws {
            for _ in 0..<100 where view.interruptHandoff.isWaiting { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(view.interruptHandoff.isWaiting)
        }
        @discardableResult func deliver(_ text: String, key: UInt16, modifiers: NSEvent.ModifierFlags = [], ignoring: String? = nil,
                                        time: TimeInterval, type: NSEvent.EventType = .keyDown, repeated: Bool = false) throws -> Bool {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: time, windowNumber: window.windowNumber, context: nil, characters: text,
                charactersIgnoringModifiers: ignoring ?? text, isARepeat: repeated, keyCode: key))
            let handled = delegate.handle(event)
            if !handled { if type == .keyUp { view.keyUp(with: event) } else { view.keyDown(with: event) } }
            return handled
        }
        func close() {
            view.invalidateTerminalInteractions(); view.setProcessInputHandler(nil)
            view.interruptHandoffReplay = nil; view.interruptHandoffProbe = nil; view.interruptHandoff.capture = { nil }
            window.contentView = nil; window.close(); try? FileManager.default.removeItem(at: root)
        }
    }
}
