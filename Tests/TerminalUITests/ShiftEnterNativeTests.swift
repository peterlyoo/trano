import AppKit
import XCTest
@testable import TerminalCore
@testable import SwiftTerm
@testable import TranoApp

@MainActor final class ShiftEnterNativeTests: XCTestCase {
    func testLegacyCodingAgentsReceiveDistinctShiftEnterInsteadOfSubmit() throws {
        for agent in [AgentKind.claude, .codex] {
            let f = try Fixture(agent: agent); defer { f.close() }
            for code: UInt16 in [36, 76] {
                f.recorder.reset()
                f.view.keyDown(with: try f.key(flags: .shift, code: code))
                XCTAssertEqual(f.recorder.text, "\u{1b}\r")
            }
        }
    }

    func testOrdinaryEnterStillSendsCarriageReturnForAgentsAndShell() throws {
        for agent in [AgentKind.claude, .codex, .shell] {
            let f = try Fixture(agent: agent); defer { f.close() }
            f.view.keyDown(with: try f.key())
            XCTAssertEqual(f.recorder.text, "\r")
        }
    }

    func testLegacyShellShiftEnterKeepsItsExistingBehavior() throws {
        let f = try Fixture(agent: .shell); defer { f.close() }
        f.view.keyDown(with: try f.key(flags: .shift))
        XCTAssertEqual(f.recorder.text, "\r")
    }

    func testNegotiatedKittyShiftEnterKeepsProtocolEncoding() throws {
        let f = try Fixture(agent: .codex); defer { f.close() }
        f.view.feed(text: "\u{1b}[>1u")
        f.recorder.reset()
        f.view.keyDown(with: try f.key(flags: .shift))
        XCTAssertEqual(f.recorder.text, "\u{1b}[13;2u")
    }

    private final class Recorder: @unchecked Sendable {
        private let storage = SwiftTerm.Locked<[UInt8]>([])
        var text: String { storage.withLock { String(decoding: $0, as: UTF8.self) } }
        func record(_ bytes: [UInt8]) { storage.withLock { $0.append(contentsOf: bytes) } }
        func reset() { storage.withLock { $0.removeAll() } }
    }

    @MainActor private final class Fixture {
        let root: URL
        let store: AppStore
        let view: TranoView
        let window: NSWindow
        let recorder = Recorder()
        init(agent: AgentKind) throws {
            _ = NSApplication.shared
            let directory = URL(fileURLWithPath: "/tmp/trano-shift-enter-" + UUID().uuidString.prefix(8))
            root = directory
            let runtime = try TerminalRuntime(root: directory)
            store = AppStore(runtime: runtime, startServices: false)
            let id = UUID().uuidString.lowercased()
            var row = TerminalSession(id: id, title: "Fixture", cwd: directory.path, pid: 0, alive: false)
            row.agent = agent
            store.sessions = [row]
            store.state.layout.addTab(paneID: id)
            view = TranoView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
            view.frameDriver.invalidate()
            view.paneID = id; view.store = store
            store.terminalViews[id] = view
            view.configure(TerminalSettings())
            window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 640, height: 300),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.animationBehavior = .none
            window.contentView = view; window.orderFrontRegardless()
            XCTAssertNotNil(view.interactionOwner())
            let captured = recorder
            view.setProcessInputHandler { bytes, origin, _ in
                if case .user = origin { captured.record(bytes) }
            }
            XCTAssertFalse(view.started)
            XCTAssertFalse(view.process.running)
            XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.host.socketPath))
        }
        func key(flags: NSEvent.ModifierFlags = [], code: UInt16 = 36) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code))
        }
        func close() {
            view.invalidateTerminalInteractions(); view.setProcessInputHandler(nil)
            view.terminalDelegate = nil; store.terminalViews.removeAll()
            window.contentView = nil; window.close()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
