import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp
@testable import SwiftTerm

@MainActor
final class TerminalURLClickTests: XCTestCase {
    private func click(_ view: TranoView, window: NSWindow, column: Int, modifiers: NSEvent.ModifierFlags) throws {
        let point = NSPoint(x: view.cellDimension.width * (CGFloat(column) + 0.5), y: view.bounds.height - view.cellDimension.height * 0.5)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: modifiers,
                timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
    }

    private func fixture() throws -> (TranoView, NSWindow, AppStore, TerminalBridge, URL, () -> [URL]) {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-url-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        let store = AppStore(runtime: runtime, startServices: false)
        let id = UUID().uuidString.lowercased()
        var pane = TerminalSession(id: id, title: "URL", cwd: root.path, pid: 0, alive: false)
        pane.agent = .claude
        store.sessions = [pane]
        store.state.layout.addTab(paneID: id)
        let view = TranoView(frame: NSRect(x: 0, y: 0, width: 1000, height: 260))
        view.frameDriver.invalidate()
        view.paneID = id; view.store = store
        store.terminalViews[id] = view
        let bridge = TerminalBridge(view: view); view.terminalDelegate = bridge
        let window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 1000, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.animationBehavior = .none
        window.contentView = view; window.orderFrontRegardless()
        final class Box { var urls: [URL] = [] }
        let box = Box()
        view.terminalInteractionOpener = { box.urls.append($0) }
        addTeardownBlock { @MainActor in
            withExtendedLifetime(bridge) {}
            view.invalidateTerminalInteractions(); view.terminalDelegate = nil
            store.terminalViews.removeAll(); window.contentView = nil; window.close()
            try? FileManager.default.removeItem(at: root)
        }
        return (view, window, store, bridge, root, { box.urls })
    }

    func testCommandClickOpensAPlainURL() throws {
        let (view, window, _, _, _, opened) = try fixture()
        view.feed(text: "see https://example.com/a?b=1 now")
        try click(view, window: window, column: 8, modifiers: .command)
        XCTAssertEqual(opened().map(\.absoluteString), ["https://example.com/a?b=1"])
    }

    func testCommandClickLeavesKoreanParticlesAndEmphasisOutOfTheURL() throws {
        let cases = [("PR https://github.com/example/repo/pull/61에서 확인", "https://github.com/example/repo/pull/61"),
                     ("**https://github.com/a/b**", "https://github.com/a/b"),
                     ("(https://github.com/a/b)를 보세요", "https://github.com/a/b"),
                     ("https://ko.wikipedia.org/wiki/대한민국 문서", "https://ko.wikipedia.org/wiki/대한민국")]
        for (text, url) in cases {
            let (view, window, _, _, _, opened) = try fixture()
            view.feed(text: text)
            let column = text.distance(from: text.startIndex, to: text.range(of: "https")!.lowerBound) + 10
            try click(view, window: window, column: column, modifiers: .command)
            XCTAssertEqual(opened(), [URL(string: url)!], text)
        }
    }

    func testCommandClickOpensAURLWhileTheAgentReportsMouse() throws {
        let (view, window, _, _, _, opened) = try fixture()
        view.feed(text: "\u{1b}[?1000h\u{1b}[?1006hsee https://example.com/a now")
        try click(view, window: window, column: 8, modifiers: .command)
        XCTAssertEqual(opened().map(\.absoluteString), ["https://example.com/a"])
    }

    func testCommandClickOpensAURLPrintedByARealShellInTheWorkspaceWindow() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-urlw-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        runtime.isolatePaneHome(root)
        let pane = try runtime.create(title: "URL", cwd: root.path, shell: "/bin/sh",
                                      arguments: ["-c", "printf '  #61 https://github.com/example/repo/pull/61\\n'; sleep 90"]).id
        try runtime.update { state in
            state.settings.automaticRestore = false
            state.layout.addWorkspace(title: "URL"); state.layout.addTab(paneID: pane)
        }
        let store = AppStore(runtime: runtime)
        let window = WorkspaceWindow.make(contentRect: NSRect(x: -10000, y: -10000, width: 1000, height: 600),
                                          contentView: NSHostingView(rootView: WorkspaceView(store: store)))
        window.orderFrontRegardless()
        defer {
            for view in store.terminalViews.values { view.terminate() }
            store.terminalViews.removeAll(); window.contentView = nil; window.close()
            for pane in (try? runtime.list()) ?? [] { try? runtime.terminate(pane.id) }
            runtime.shutdownTestHost(); try? FileManager.default.removeItem(at: root)
        }
        var view: TranoView?
        let deadline = Date().addingTimeInterval(8)
        repeat {
            window.contentView?.layoutSubtreeIfNeeded()
            if let candidate = store.terminalViews[pane], candidate.window === window,
               candidate.link(atViewPoint: NSPoint(x: candidate.cellDimension.width * 12.5, y: candidate.bounds.height - candidate.cellDimension.height * 0.5)) != nil {
                view = candidate; break
            }
            try await Task.sleep(for: .milliseconds(30))
        } while Date() < deadline
        let terminal = try XCTUnwrap(view, "URL never rendered: " + (store.message ?? ""))
        var opened: [URL] = []
        terminal.terminalInteractionOpener = { opened.append($0) }
        window.makeFirstResponder(terminal)
        try click(terminal, window: window, column: 12, modifiers: .command)
        XCTAssertEqual(opened.map(\.absoluteString), ["https://github.com/example/repo/pull/61"])
    }

    func testHoveringAHexColorShowsItsSwatchAndLeavingHidesIt() throws {
        let (view, window, store, _, _, _) = try fixture()
        view.feed(text: "accent: #2da44e; bg: #fff")
        func move(column: Int) throws {
            let point = NSPoint(x: view.cellDimension.width * (CGFloat(column) + 0.5), y: view.bounds.height - view.cellDimension.height * 0.5)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: view.convert(point, to: nil), modifierFlags: [],
                timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
            TerminalColorPreviewRouting.handle(event, store: store, in: window)
        }
        try move(column: 10)
        let badge = try XCTUnwrap(view.colorPreview.badge)
        XCTAssertTrue(badge.superview === view)
        XCTAssertEqual(view.colorPreview.match?.text, "#2da44e")
        XCTAssertEqual(badge.color.redComponent, 0x2d / 255, accuracy: 0.001)
        XCTAssertEqual(badge.color.greenComponent, 0xa4 / 255, accuracy: 0.001)
        XCTAssertTrue(view.bounds.contains(badge.frame))
        XCTAssertNil(badge.hitTest(NSPoint(x: badge.bounds.midX, y: badge.bounds.midY)), "the swatch never takes clicks or selection")
        try move(column: 22)
        XCTAssertEqual(view.colorPreview.match?.text, "#fff")
        try move(column: 3)
        XCTAssertNil(view.colorPreview.badge)
        try move(column: 10)
        XCTAssertNotNil(view.colorPreview.badge)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber,
            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        TerminalColorPreviewRouting.handle(key, store: store, in: window)
        XCTAssertNil(view.colorPreview.badge, "typing dismisses the swatch")
    }
}
