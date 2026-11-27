import AppKit
import Darwin
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class SupervisorWindowControllerTests: XCTestCase {
    // Implements: FR-SUP-1
    @MainActor func testPlacementFitsTheOwningDisplayIncludingOversizedPanels() {
        let visible = NSRect(x: -1280, y: 100, width: 1280, height: 800)
        let owner = NSRect(x: -700, y: 200, width: 600, height: 600)
        for size in [NSSize(width: 480, height: 640), NSSize(width: 2200, height: 1600)] {
            let frame = SupervisorWindowController.placementFrame(NSRect(origin: .zero, size: size),
                ownerFrame: owner, visibleFrame: visible)
            XCTAssertTrue(visible.contains(frame))
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
        }
    }

    // Implements: FR-SUP-1, FR-SUP-2
    @MainActor func testNativeSelectorsAndStartButtonStayInsideACompactPanel() throws {
        let f = fixture()
        defer { f.controller.window?.delegate = nil; f.controller.window?.close() }
        f.controller.show()
        f.scheduler.runNext()
        let panel = try XCTUnwrap(f.controller.window)
        for size in [NSSize(width: 360, height: 420), NSSize(width: 600, height: 800)] {
            panel.setContentSize(size)
            let content = try XCTUnwrap(panel.contentView)
            content.layoutSubtreeIfNeeded()
            for id in ["supervisor-provider", "supervisor-account", "supervisor-start", "supervisor-stop", "supervisor-status"] {
                let control = try XCTUnwrap(region(id, in: content))
                let rect = control.convert(control.bounds, to: content)
                XCTAssertGreaterThan(rect.width, 0)
                XCTAssertGreaterThan(rect.height, 0)
                XCTAssertTrue(content.bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect), id)
            }
        }
        let content = try XCTUnwrap(panel.contentView)
        let provider = try XCTUnwrap(region("supervisor-provider", in: content) as? NSPopUpButton)
        provider.selectItem(withTitle: "Codex")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(provider.action), to: provider.target, from: provider))
        let start = try XCTUnwrap(region("supervisor-start", in: content) as? NSButton)
        start.performClick(nil)
        XCTAssertTrue(f.model.isBusy)
        XCTAssertFalse(start.isEnabled)
        XCTAssertEqual(f.spy.startCount, 0)
        f.scheduler.runNext()
        XCTAssertEqual(f.spy.startedConfigurations.last?.provider, .codex)
        XCTAssertEqual(f.spy.startCount, 1)
    }

    // Implements: FR-SUP-1, FR-SUP-2
    @MainActor func testShowingAnEmptyPanelOnlySchedulesAReadAndDoesNotStartAnAgent() throws {
        let f = fixture()
        let owner = makePanel()
        defer { owner.close(); f.controller.window?.delegate = nil; f.controller.window?.close() }
        let ownerFrame = owner.frame
        f.controller.show(relativeTo: owner)
        XCTAssertTrue(f.controller.isPresented)
        XCTAssertEqual(f.scheduler.pendingCount, 1)
        XCTAssertTrue(f.model.isBusy)
        XCTAssertEqual(f.spy.startCount, 0)
        XCTAssertEqual(f.spy.rendererCount, 0)
        XCTAssertEqual(owner.frame, ownerFrame)
        f.scheduler.runNext()
        XCTAssertFalse(f.model.isBusy)
        XCTAssertEqual(f.spy.readCount, 1)
        XCTAssertEqual(f.spy.startCount, 0)
        XCTAssertNil(f.controller.renderer)
    }

    // Implements: FR-SUP-2, FR-SUP-5
    @MainActor func testStartAndStopPublishBusyStateBeforeBackgroundWorkAndCaptureExactBinding() throws {
        let f = fixture()
        f.model.start()
        XCTAssertTrue(f.model.isBusy)
        XCTAssertEqual(f.scheduler.pendingCount, 1)
        XCTAssertEqual(f.spy.startCount, 0)
        f.model.start()
        XCTAssertEqual(f.scheduler.pendingCount, 1)
        f.scheduler.runNext()
        XCTAssertFalse(f.model.isBusy)
        XCTAssertEqual(f.spy.startCount, 1)
        let binding = try XCTUnwrap(f.model.snapshot?.binding)
        f.model.stop()
        XCTAssertTrue(f.model.isBusy)
        XCTAssertEqual(f.spy.stopCount, 0)
        f.scheduler.runNext()
        XCTAssertEqual(f.spy.stoppedIDs, [binding.paneID])
        XCTAssertEqual(f.spy.stoppedPIDs, [binding.backendPID])
        XCTAssertEqual(f.model.snapshot?.phase, .stopped)
        XCTAssertFalse(f.model.isBusy)
    }

    // Implements: FR-SUP-1
    @MainActor func testWorkspaceRefreshAndShowHideRetainTheSameWindowAndRenderer() throws {
        let f = fixture(initial: liveState())
        let firstOwner = makePanel()
        let secondOwner = makePanel()
        defer {
            firstOwner.close(); secondOwner.close()
            f.controller.window?.delegate = nil; f.controller.window?.close()
        }
        let firstFrame = firstOwner.frame, secondFrame = secondOwner.frame
        f.controller.show(relativeTo: firstOwner)
        f.scheduler.runNext()
        let panel = try XCTUnwrap(f.controller.window)
        let renderer = try XCTUnwrap(f.controller.renderer)
        XCTAssertTrue(renderer.window === panel)
        XCTAssertFalse(panel.isReleasedWhenClosed)
        XCTAssertEqual(f.spy.rendererCount, 1)
        f.model.refresh()
        f.scheduler.runNext()
        f.controller.hide()
        XCTAssertFalse(f.controller.isPresented)
        f.controller.show(relativeTo: secondOwner)
        f.scheduler.runNext()
        XCTAssertTrue(f.controller.window === panel)
        XCTAssertTrue(f.controller.renderer === renderer)
        XCTAssertEqual(f.spy.rendererCount, 1)
        XCTAssertEqual(firstOwner.frame, firstFrame)
        XCTAssertEqual(secondOwner.frame, secondFrame)
        XCTAssertEqual(f.spy.stopCount, 0)
    }

    // Implements: FR-SUP-1, FR-SUP-5
    @MainActor func testCloseAndCommandWOnlyHideTheSupervisor() throws {
        let f = fixture(initial: liveState())
        defer { f.controller.window?.delegate = nil; f.controller.window?.close() }
        f.controller.show()
        f.scheduler.runNext()
        let panel = try XCTUnwrap(f.controller.window)
        let renderer = try XCTUnwrap(f.controller.renderer)
        XCTAssertFalse(f.controller.windowShouldClose(panel))
        XCTAssertFalse(f.controller.isPresented)
        XCTAssertTrue(f.controller.renderer === renderer)
        f.controller.show()
        f.scheduler.runNext()
        XCTAssertTrue(f.controller.perform(.closePane))
        XCTAssertFalse(f.controller.isPresented)
        XCTAssertTrue(f.controller.renderer === renderer)
        XCTAssertEqual(f.spy.stopCount, 0)
        XCTAssertTrue(f.spy.forwardedActions.isEmpty)
    }

    // Implements: FR-SUP-1, FR-SUP-2, FR-SUP-5
    @MainActor func testOpeningAnExplicitlyStoppedBindingDoesNotAttachARenderer() throws {
        let f = fixture(initial: liveState(stoppedAt: Date(timeIntervalSince1970: 2)))
        defer { f.controller.window?.delegate = nil; f.controller.window?.close() }
        f.controller.show()
        f.scheduler.runNext()
        XCTAssertEqual(f.model.snapshot?.phase, .stopped)
        XCTAssertEqual(f.spy.rendererCount, 0)
        XCTAssertEqual(f.spy.synchronizeCount, 0)
        XCTAssertNil(f.controller.renderer)
        XCTAssertTrue(f.model.canStart)
        let content = try XCTUnwrap(f.controller.window?.contentView)
        let start = try XCTUnwrap(region("supervisor-start", in: content) as? NSButton)
        XCTAssertTrue(start.isEnabled)
    }

    // Implements: FR-SUP-1, FR-SUP-5
    @MainActor func testAnExistingRendererIsRetainedWithoutSynchronizingAStoppedBackend() throws {
        let f = fixture(initial: liveState())
        defer { f.controller.window?.delegate = nil; f.controller.window?.close() }
        f.controller.show()
        f.scheduler.runNext()
        let renderer = try XCTUnwrap(f.controller.renderer)
        f.model.stop()
        let beforeCompletion = f.spy.synchronizeCount
        f.scheduler.runNext()
        XCTAssertTrue(f.controller.renderer === renderer)
        XCTAssertEqual(f.spy.synchronizeCount, beforeCompletion)
        f.controller.hide()
        f.controller.show()
        f.scheduler.runNext()
        XCTAssertTrue(f.controller.renderer === renderer)
        XCTAssertEqual(f.spy.synchronizeCount, beforeCompletion)
    }

    // Implements: FR-SUP-1, FR-SUP-5
    @MainActor func testChangedBackendIdentityDetachesTheOldRendererBeforeAnAttachFailure() throws {
        let f = fixture(initial: liveState())
        defer { f.controller.window?.delegate = nil; f.controller.window?.close() }
        f.controller.show()
        f.scheduler.runNext()
        let oldRenderer = try XCTUnwrap(f.controller.renderer)
        f.spy.replaceState(liveState(backendPID: 8822))
        f.spy.rendererFailure = true
        f.model.refresh()
        f.scheduler.runNext()
        XCTAssertNil(f.controller.renderer)
        XCTAssertNil(oldRenderer.superview)
        XCTAssertFalse(f.controller.perform(.paste))
        XCTAssertTrue(f.spy.forwardedActions.isEmpty)
    }

    // Implements: FR-SUP-1, FR-SUP-5
    @MainActor func testRendererValidationFailureDetachesTheRendererThatCouldReceiveInput() throws {
        let f = fixture(initial: liveState())
        defer { f.controller.window?.delegate = nil; f.controller.window?.close() }
        f.controller.show()
        f.scheduler.runNext()
        let oldRenderer = try XCTUnwrap(f.controller.renderer)
        f.spy.synchronizeFailure = true
        f.model.refresh()
        f.scheduler.runNext()
        XCTAssertNil(f.controller.renderer)
        XCTAssertNil(oldRenderer.superview)
        XCTAssertFalse(f.controller.perform(.paste))
        XCTAssertTrue(f.spy.forwardedActions.isEmpty)
    }

    // Implements: FR-SUP-1, FR-SUP-5
    @MainActor func testOwnedWindowRoutingKeepsRendererActionsOutOfNormalPanes() throws {
        let f = fixture(initial: liveState())
        let other = makePanel()
        defer { other.close(); f.controller.window?.delegate = nil; f.controller.window?.close() }
        f.controller.show()
        f.scheduler.runNext()
        let panel = try XCTUnwrap(f.controller.window)
        XCTAssertTrue(f.controller.owns(panel))
        XCTAssertFalse(f.controller.owns(other))
        XCTAssertFalse(f.controller.owns(nil))
        XCTAssertTrue(f.controller.perform(.copy))
        XCTAssertEqual(f.spy.forwardedActions, [.copy])
        XCTAssertFalse(f.controller.perform(.closeOtherPanes))
        XCTAssertEqual(f.spy.forwardedActions, [.copy])
        let close = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        XCTAssertTrue(f.controller.handle(close))
        XCTAssertFalse(f.controller.isPresented)
        XCTAssertEqual(f.spy.stopCount, 0)
    }

    // Implements: FR-SUP-1, FR-INPUT-1
    @MainActor func testMarkedTextDoesNotHideThePanelOrDispatchAnAction() throws {
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        let f = fixture(initial: liveState(), renderer: editor)
        defer { editor.unmarkText(); f.controller.window?.delegate = nil; f.controller.window?.close() }
        f.controller.show()
        f.scheduler.runNext()
        let panel = try XCTUnwrap(f.controller.window)
        XCTAssertTrue(panel.firstResponder === editor)
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = editor.markedRange()
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        XCTAssertFalse(f.controller.handle(event))
        XCTAssertTrue(f.controller.isPresented)
        XCTAssertEqual(editor.markedRange(), marked)
        XCTAssertTrue(f.spy.forwardedActions.isEmpty)
    }

    // Implements: FR-SUP-1, FR-SUP-2
    @MainActor func testAHiddenPanelDoesNotCreateARendererWhenAReadCompletes() {
        let f = fixture(initial: liveState())
        defer { f.controller.window?.delegate = nil; f.controller.window?.close() }
        f.controller.show()
        f.controller.hide()
        f.scheduler.runNext()
        XCTAssertFalse(f.controller.isPresented)
        XCTAssertNil(f.controller.renderer)
        XCTAssertEqual(f.spy.rendererCount, 0)
        f.controller.show()
        f.scheduler.runNext()
        XCTAssertEqual(f.spy.rendererCount, 1)
    }

    // Implements: FR-SUP-2, FR-SUP-5
    @MainActor func testFailureClearsBusyStateAndLeavesRetryAvailable() {
        let f = fixture()
        f.spy.startFailure = true
        f.model.start()
        f.scheduler.runNext()
        XCTAssertFalse(f.model.isBusy)
        XCTAssertNotNil(f.model.errorMessage)
        XCTAssertEqual(f.spy.startCount, 1)
        f.spy.startFailure = false
        f.model.start()
        f.scheduler.runNext()
        XCTAssertNil(f.model.errorMessage)
        XCTAssertNotNil(f.model.snapshot?.binding)
        XCTAssertEqual(f.spy.startCount, 2)
    }

    // Implements: FR-SUP-2
    @MainActor func testAStoppedBindingDoesNotReplaceTheNextExplicitProviderChoice() {
        let f = fixture(initial: liveState())
        f.model.refresh()
        f.scheduler.runNext()
        f.model.stop()
        f.scheduler.runNext()
        f.model.configuration = SupervisorConfiguration(provider: .codex, cwd: "/tmp/next")
        f.model.refresh()
        f.scheduler.runNext()
        XCTAssertEqual(f.model.configuration.provider, .codex)
        XCTAssertEqual(f.model.configuration.cwd, "/tmp/next")
    }

    // Implements: FR-SUP-1, FR-SUP-2
    @MainActor func testRefreshEventsDuringAnOperationCoalesceIntoOneFollowupRead() {
        let f = fixture()
        f.model.start()
        f.model.refresh()
        f.model.refresh()
        XCTAssertEqual(f.scheduler.pendingCount, 1)
        f.scheduler.runNext()
        XCTAssertEqual(f.spy.startCount, 1)
        XCTAssertEqual(f.scheduler.pendingCount, 1)
        XCTAssertTrue(f.model.isBusy)
        f.scheduler.runNext()
        XCTAssertEqual(f.spy.readCount, 1)
        XCTAssertFalse(f.model.isBusy)
        XCTAssertEqual(f.scheduler.pendingCount, 0)
    }

    // Implements: FR-SUP-1, FR-SET-93, FR-SET-94
    @MainActor func testHidingInvalidatesPendingLinkApprovalWithoutDiscardingRenderer() throws {
        let renderer = InteractionRenderer(frame: .zero)
        let f = fixture(initial: liveState(), renderer: renderer)
        defer { f.controller.window?.delegate = nil; f.controller.window?.close() }
        f.controller.show(); f.scheduler.runNext()
        let panel = try XCTUnwrap(f.controller.window)
        let owner = TerminalInteractionOwner(paneID: "pane", windowID: ObjectIdentifier(panel), generation: UUID())
        let lease = TerminalInteractionLease(owner: owner, sessionPID: 4711)
        renderer.invalidate = { lease.invalidate() }
        var saveReply: TerminalTrustedRuleSaveCompletion?
        var opened = 0
        let prompt = LinkPrompt()
        let handler = TerminalApplicationLinkHandler(preferences: { TerminalPreferences() },
            owner: { lease.isValid ? owner : nil }, opener: { _ in opened += 1 }, presentPrompt: prompt,
            saveTrustedRule: { _, _, _, completion in saveReply = completion })
        handler.requestOpen(URL(string: "exampleapp://host/path")!, in: panel)
        try XCTUnwrap(prompt.reply)(.alertSecondButtonReturn)
        f.controller.hide()
        XCTAssertFalse(lease.isValid)
        try XCTUnwrap(saveReply)(.success(()))
        XCTAssertEqual(opened, 0)
        XCTAssertTrue(f.controller.renderer === renderer)
        XCTAssertEqual(f.spy.stopCount, 0)
    }

    @MainActor private final class InteractionRenderer: NSView, TerminalInteractionInvalidating {
        var invalidate: () -> Void = {}
        func invalidateTerminalInteractions() { invalidate() }
    }

    @MainActor private final class LinkPrompt: TerminalApplicationLinkPromptPresenting {
        var reply: ((NSApplication.ModalResponse) -> Void)?
        func present(_ alert: NSAlert, in window: NSWindow,
                     completion: @escaping (NSApplication.ModalResponse) -> Void) -> () -> Void {
            reply = completion
            return {}
        }
    }

    private struct Fixture {
        let spy: SupervisorPanelSpy
        let scheduler: SupervisorPanelFakeScheduler
        let model: SupervisorPanelModel
        let controller: SupervisorWindowController
    }

    @MainActor private func fixture(initial: SupervisorState? = nil, renderer: NSView? = nil) -> Fixture {
        let spy = SupervisorPanelSpy(state: initial ?? emptyState())
        let scheduler = SupervisorPanelFakeScheduler()
        let nativeView = renderer ?? NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
        let services = SupervisorPanelServices(readState: { spy.read() }, start: { config in try spy.start(config) },
            stop: { pane, pid in spy.stop(pane, pid) }, makeRenderer: { _ in
                spy.rendererCount += 1
                if spy.rendererFailure { throw TerminalError.runtime("Fixture backend identity changed") }
                return nativeView
            }, synchronizeRenderer: { _, _ in
                spy.synchronizeCount += 1
                if spy.synchronizeFailure { throw TerminalError.runtime("Fixture backend identity changed") }
            },
            performRendererAction: { action, _ in
                guard [.copy, .paste, .selectAll, .clear, .find, .findNext, .findPrevious, .increaseFont, .decreaseFont, .resetFont].contains(action) else { return false }
                spy.forwardedActions.append(action); return true
            }, cachedAccounts: { [] }, cachedKeyBindings: { [:] })
        let model = SupervisorPanelModel(services: services,
            configuration: SupervisorConfiguration(provider: .claude, cwd: "/tmp"), scheduler: scheduler)
        let controller = SupervisorWindowController(model: model, makeWindow: { _ in self.makePanel() }, presentWindow: { _ in spy.presentationCount += 1 }, inputWindowIsActive: { _ in true })
        return Fixture(spy: spy, scheduler: scheduler, model: model, controller: controller)
    }

    @MainActor private func makePanel() -> NSPanel {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.setFrameOrigin(NSPoint(x: -14000, y: -14000))
        return panel
    }

    @MainActor private func region(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { self.region(id, in: $0) }.first
    }
}

private func emptyState() -> SupervisorState {
    SupervisorProjection.state(binding: nil, observation: SupervisorObservation())
}

private func liveState(configuration: SupervisorConfiguration = SupervisorConfiguration(provider: .claude, cwd: "/tmp"),
                       backendPID: Int32 = 4711, stoppedAt: Date? = nil) -> SupervisorState {
    let config = configuration
    let binding = SupervisorBinding(paneID: "00000000-0000-4000-8000-000000000010", backendPID: backendPID,
        configuration: config, createdAt: Date(timeIntervalSince1970: 1), stoppedAt: stoppedAt,
        processIdentity: SupervisorProcessIdentity(pid: backendPID, ownerUID: getuid(),
            startedAtSeconds: 1, startedAtMicroseconds: 1))
    var session = TerminalSession(id: binding.paneID, title: "Supervisor", cwd: "/tmp", pid: binding.backendPID)
    if stoppedAt != nil { session.alive = false }
    let identities = binding.processIdentity.map { [binding.paneID: $0] } ?? [:]
    return SupervisorProjection.state(binding: binding,
        observation: SupervisorObservation(sessions: [session], backendIdentities: identities))
}

private final class SupervisorPanelSpy: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var state: SupervisorState
    private(set) var readCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var stoppedIDs: [String] = []
    private(set) var stoppedPIDs: [Int32] = []
    private(set) var startedConfigurations: [SupervisorConfiguration] = []
    var startFailure = false
    var rendererFailure = false
    var synchronizeFailure = false
    var rendererCount = 0
    var synchronizeCount = 0
    var presentationCount = 0
    var forwardedActions: [ActionID] = []

    init(state: SupervisorState) { self.state = state }
    func replaceState(_ value: SupervisorState) { lock.lock(); defer { lock.unlock() }; state = value }
    func read() -> SupervisorState {
        lock.lock(); defer { lock.unlock() }
        readCount += 1; return state
    }
    func start(_ configuration: SupervisorConfiguration) throws -> SupervisorState {
        lock.lock(); defer { lock.unlock() }
        startCount += 1
        startedConfigurations.append(configuration)
        if startFailure { throw TerminalError.runtime("Fixture start failure") }
        state = liveState(configuration: configuration); return state
    }
    func stop(_ pane: String, _ pid: Int32) -> SupervisorState {
        lock.lock(); defer { lock.unlock() }
        stopCount += 1; stoppedIDs.append(pane); stoppedPIDs.append(pid)
        if var binding = state.binding {
            binding.stoppedAt = Date(timeIntervalSince1970: 2)
            state = SupervisorProjection.state(binding: binding, observation: SupervisorObservation())
        }
        return state
    }
}

private final class SupervisorPanelFakeScheduler: SupervisorPanelScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var work: [@Sendable () -> Void] = []
    private var delivery: [@MainActor @Sendable () -> Void] = []
    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return work.count }
    func schedule(_ item: @escaping @Sendable () -> Void) { lock.lock(); work.append(item); lock.unlock() }
    func deliver(_ item: @escaping @MainActor @Sendable () -> Void) { lock.lock(); delivery.append(item); lock.unlock() }
    @MainActor func runNext() {
        lock.lock(); let next = work.isEmpty ? nil : work.removeFirst(); lock.unlock()
        next?()
        while true {
            lock.lock(); let callback = delivery.isEmpty ? nil : delivery.removeFirst(); lock.unlock()
            guard let callback else { break }
            callback()
        }
    }
}
