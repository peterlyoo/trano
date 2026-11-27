import AppKit
import XCTest
@testable import TerminalCore
@testable import TranoApp

@MainActor final class SupervisorKeySequenceRoutingTests: XCTestCase {
    // Implements: FR-SET-84, FR-SUP-1, FR-SUP-5
    func testReservedOwnerRoutesSupportedSequencesAndRetainsItsRenderer() throws {
        let f = fixture()
        defer { f.controller.window?.delegate = nil; f.controller.window?.close() }
        f.controller.show()
        let owner = try XCTUnwrap(f.controller.window)
        let renderer = try XCTUnwrap(f.controller.renderer)
        for (suffix, action) in [("c", ActionID.copy), ("v", .paste), ("f", .increaseFont)] {
            XCTAssertTrue(f.controller.handle(try key("x", owner)))
            XCTAssertTrue(f.controller.handle(try key(suffix, owner)))
            XCTAssertEqual(f.spy.actions.last, action)
            XCTAssertTrue(f.controller.renderer === renderer)
        }
        XCTAssertTrue(f.controller.handle(try key("x", owner)))
        XCTAssertTrue(f.controller.handle(try key("w", owner)))
        XCTAssertFalse(f.controller.isPresented)
        XCTAssertTrue(f.controller.renderer === renderer)
        XCTAssertEqual(f.spy.starts, 0)
        XCTAssertEqual(f.spy.stops, 0)
    }

    // Implements: FR-SET-84, FR-SUP-5, FR-INPUT-1
    func testUnsupportedPrefixesAndWrongResponderDoNotConsumeOrDispatch() throws {
        let f = fixture()
        defer { f.controller.window?.delegate = nil; f.controller.window?.close() }
        f.controller.show()
        let owner = try XCTUnwrap(f.controller.window)
        XCTAssertFalse(f.controller.handle(try key("d", owner)))
        XCTAssertTrue(f.spy.actions.isEmpty)
        XCTAssertTrue(f.controller.handle(try key("x", owner)))
        let editor = NSTextView(frame: .zero)
        owner.contentView?.addSubview(editor)
        XCTAssertTrue(owner.makeFirstResponder(editor))
        XCTAssertFalse(f.controller.handle(try key("v", owner)))
        XCTAssertTrue(f.spy.actions.isEmpty)
        XCTAssertTrue(owner.makeFirstResponder(try XCTUnwrap(f.controller.renderer)))
        XCTAssertFalse(f.controller.handle(try key("v", owner)))
        XCTAssertTrue(f.spy.actions.isEmpty)
    }

    // Implements: FR-SET-84, FR-SUP-1, FR-INPUT-1
    func testHideCompositionAndNativeFocusLossCancelPendingSequences() throws {
        let f = fixture()
        defer { f.controller.window?.delegate = nil; f.controller.window?.close() }
        f.controller.show()
        let owner = try XCTUnwrap(f.controller.window)
        let renderer = try XCTUnwrap(f.controller.renderer as? NSTextView)
        XCTAssertTrue(f.controller.handle(try key("x", owner)))
        f.controller.hide(); f.controller.show()
        XCTAssertFalse(f.controller.handle(try key("v", owner)))
        XCTAssertTrue(f.controller.handle(try key("x", owner)))
        renderer.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = renderer.markedRange()
        XCTAssertFalse(f.controller.handle(try key("v", owner)))
        XCTAssertEqual(renderer.markedRange(), marked)
        renderer.unmarkText()
        XCTAssertTrue(f.controller.handle(try key("x", owner)))
        f.spy.active = false
        XCTAssertFalse(f.controller.handle(try key("v", owner)))
        f.spy.active = true
        XCTAssertFalse(f.controller.handle(try key("v", owner)))
        XCTAssertTrue(f.spy.actions.isEmpty)
    }

    // Implements: FR-SET-84, FR-SUP-5
    func testUnsupportedSharedPrefixSuffixAndBindingReloadCannotReachOrdinaryActions() throws {
        let f = fixture()
        defer { f.controller.window?.delegate = nil; f.controller.window?.close() }
        f.controller.show()
        let owner = try XCTUnwrap(f.controller.window)
        XCTAssertTrue(f.controller.handle(try key("x", owner)))
        XCTAssertTrue(f.controller.handle(try key("n", owner)))
        XCTAssertTrue(f.spy.actions.isEmpty)
        XCTAssertTrue(f.controller.isPresented)
        XCTAssertTrue(f.controller.handle(try key("x", owner)))
        f.spy.bindings[ActionID.paste.rawValue] = ["ctrl+b,ctrl+v"]
        XCTAssertFalse(f.controller.handle(try key("v", owner)))
        XCTAssertTrue(f.controller.handle(try key("b", owner)))
        XCTAssertTrue(f.controller.handle(try key("v", owner)))
        XCTAssertEqual(f.spy.actions, [.paste])
    }

    private struct Fixture { let spy: Spy; let controller: SupervisorWindowController }
    private final class Spy: @unchecked Sendable {
        var active = true
        var actions: [ActionID] = []
        var starts = 0, stops = 0
        var bindings = [
            ActionID.copy.rawValue: ["ctrl+x,ctrl+c"], ActionID.paste.rawValue: ["ctrl+x,ctrl+v"],
            ActionID.increaseFont.rawValue: ["ctrl+x,ctrl+f"], ActionID.closePane.rawValue: ["ctrl+x,ctrl+w"],
            ActionID.newSession.rawValue: ["ctrl+x,ctrl+n"], ActionID.splitRight.rawValue: ["ctrl+d,ctrl+s"]
        ]
    }
    private struct ImmediateScheduler: SupervisorPanelScheduling {
        func schedule(_ work: @escaping @Sendable () -> Void) { work() }
        func deliver(_ work: @escaping @MainActor @Sendable () -> Void) { MainActor.assumeIsolated { work() } }
    }
    private func fixture() -> Fixture {
        _ = NSApplication.shared
        let spy = Spy(), renderer = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
        let binding = SupervisorBinding(paneID: "00000000-0000-4000-8000-000000000010", backendPID: 4711,
            configuration: SupervisorConfiguration(provider: .claude, cwd: "/tmp"), createdAt: Date(timeIntervalSince1970: 1),
            processIdentity: SupervisorProcessIdentity(pid: 4711, ownerUID: getuid(), startedAtSeconds: 1, startedAtMicroseconds: 1))
        let session = TerminalSession(id: binding.paneID, title: "Supervisor", cwd: "/tmp", pid: 4711)
        let state = SupervisorProjection.state(binding: binding,
            observation: SupervisorObservation(sessions: [session], backendIdentities: [binding.paneID: binding.processIdentity!]))
        let services = SupervisorPanelServices(readState: { state }, start: { _ in spy.starts += 1; return state },
            stop: { _, _ in spy.stops += 1; return state }, makeRenderer: { _ in renderer }, synchronizeRenderer: { _, _ in },
            performRendererAction: { action, view in
                XCTAssertTrue(view === renderer)
                spy.actions.append(action); return true
            }, cachedAccounts: { [] }, cachedKeyBindings: { spy.bindings })
        let model = SupervisorPanelModel(services: services, configuration: binding.configuration, scheduler: ImmediateScheduler())
        let controller = SupervisorWindowController(model: model, makeWindow: { _ in
            let panel = NSPanel(contentRect: NSRect(x: -14000, y: -14000, width: 480, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.setFrameOrigin(NSPoint(x: -14000, y: -14000))
            return panel
        }, presentWindow: { _ in }, inputWindowIsActive: { _ in spy.active })
        return Fixture(spy: spy, controller: controller)
    }
    private func key(_ character: String, _ owner: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 1,
            windowNumber: owner.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character,
            isARepeat: false, keyCode: 7))
    }
}
