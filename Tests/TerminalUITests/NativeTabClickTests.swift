import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import SwiftTerm
@testable import TerminalCore
@testable import TranoApp

@MainActor final class NativeTabClickTests: XCTestCase {
    // Implements: FR-NAV-12, FR-INPUT-1
    func testNativeWindowClicksSelectTitleAndIconWithTerminalOrEditorResponder() async throws {
        let f = try Fixture(); defer { f.close() }
        for editor in [false, true] {
            for surface in [Surface.title, .icon] {
                try await f.reset()
                let responder: NSResponder = editor ? f.editor : f.views[1]
                XCTAssertTrue(f.window.makeFirstResponder(responder))
                let point = try f.point(surface)
                let hit = try XCTUnwrap(f.hit(point))
                XCTAssertTrue(hit is TabDragView, "Actual \(surface) hit: \(type(of: hit))")
                try f.click(point)
                await f.drain()
                XCTAssertEqual(try f.runtime.state().layout.selectedTabID, f.tabs[0], "Durable selection: \(surface), editor=\(editor)")
                XCTAssertEqual(f.store.selectedTab?.id, f.tabs[0], "Presented selection: \(surface), editor=\(editor)")
                try f.assertNoJobs()
            }
        }
    }

    func testBackgroundSwiftUIGestureDeliveryCalibration() async throws {
        let f = try Fixture(); defer { f.close() }
        try await f.reset()
        try await requireSwiftUIGestureDelivery(in: f)
        try f.assertNoJobs()
    }

    // Implements: FR-NAV-12, FR-INPUT-1
    func testQualifiedPaddingClicksSelectWithTerminalOrEditorResponder() async throws {
        let f = try Fixture(); defer { f.close() }
        try await f.reset()
        try await requireSwiftUIGestureDelivery(in: f)
        for editor in [false, true] {
            try await f.reset()
            let responder: NSResponder = editor ? f.editor : f.views[1]
            XCTAssertTrue(f.window.makeFirstResponder(responder))
            try f.click(f.point(.padding))
            await f.drain()
            XCTAssertEqual(try f.runtime.state().layout.selectedTabID, f.tabs[0], "Durable padding selection, editor=\(editor)")
            XCTAssertEqual(f.store.selectedTab?.id, f.tabs[0], "Presented padding selection, editor=\(editor)")
            try f.assertNoJobs()
        }
    }

    private func requireSwiftUIGestureDelivery(in f: Fixture) async throws {
        var taps = 0
        let calibration = NSHostingView(rootView: Text("Harmless gesture calibration")
            .frame(width: 240, height: 40).contentShape(Rectangle()).onTapGesture { taps += 1 })
        calibration.frame = NSRect(x: 20, y: 150, width: 240, height: 40)
        f.hosting.addSubview(calibration)
        defer { calibration.removeFromSuperview() }
        calibration.layoutSubtreeIfNeeded()
        let point = calibration.convert(NSPoint(x: calibration.bounds.midX, y: calibration.bounds.midY), to: nil)
        let hit = try XCTUnwrap(f.hit(point))
        XCTAssertTrue(hit === calibration || hit.isDescendant(of: calibration), "Calibration must own the actual hit: \(type(of: hit))")
        try f.click(point)
        await f.drain()
        guard taps == 1 else {
            throw XCTSkip("Background SwiftUI onTapGesture delivery unavailable: taps=\(taps), hit=\(type(of: hit)), key=\(f.window.isKeyWindow). Raw calibration: .local/remote-footer-and-input-latency/tab-calibration.log")
        }
    }

    // Implements: FR-NAV-12, FR-INPUT-1
    func testNativeTitleClickWhileComposingCommitsSelectionWithoutDiscardingPreedit() async throws {
        let f = try Fixture(); defer { f.close() }
        try await f.reset()
        XCTAssertTrue(f.window.makeFirstResponder(f.editor))
        f.editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = f.editor.markedRange(), text = f.editor.string
        try f.click(f.point(.title))
        await f.drain()
        XCTAssertEqual(try f.runtime.state().layout.selectedTabID, f.tabs[0])
        XCTAssertEqual(f.store.selectedTab?.id, f.tabs[1])
        XCTAssertTrue(f.window.firstResponder === f.editor)
        XCTAssertTrue(f.editor.hasMarkedText())
        XCTAssertEqual(f.editor.markedRange(), marked)
        XCTAssertEqual(f.editor.string, text)
        try f.assertNoJobs()
    }

    // Implements: FR-NAV-12
    func testNativeTitleClickSurvivesQueuedRuntimeWork() async throws {
        let f = try Fixture(); defer { f.close() }
        try await f.reset()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        f.store.queue.async { _ = release.wait(timeout: .now() + 5) }
        try f.click(f.point(.title))
        XCTAssertEqual(f.store.selectedTab?.id, f.tabs[1], "The current implementation defers selection until queued work finishes")
        release.signal()
        await f.drain()
        XCTAssertEqual(try f.runtime.state().layout.selectedTabID, f.tabs[0])
        XCTAssertEqual(f.store.selectedTab?.id, f.tabs[0], "A deferred native click must not be discarded")
        try f.assertNoJobs()
    }

    // Implements: FR-NAV-12
    func testConfirmedNativeTitleClickPresentsBeforeUnrelatedMetadataCompletes() async throws {
        try await assertConfirmedClickPresentsBeforeMetadata(.title)
    }

    // Implements: FR-NAV-12
    func testConfirmedPaddingClickPresentsBeforeUnrelatedMetadataCompletes() async throws {
        try await assertConfirmedClickPresentsBeforeMetadata(.padding)
    }

    private func assertConfirmedClickPresentsBeforeMetadata(_ surface: Surface) async throws {
        let f = try Fixture(delayingMetadata: true); defer { f.releaseMetadata(); f.close() }
        try await f.reset()
        if surface == .padding { try await requireSwiftUIGestureDelivery(in: f) }
        XCTAssertTrue(f.window.makeFirstResponder(f.views[1]))
        try f.click(f.point(surface))
        let deadline = Date().addingTimeInterval(3)
        while !f.metadataReady, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard f.metadataReady else { XCTFail("Click did not reach the deterministic metadata probe: \(surface)"); return }
        XCTAssertEqual(try f.runtime.state().layout.selectedTabID, f.tabs[0], "Mutation is confirmed before the unrelated metadata probe finishes")
        let presentationDeadline = Date().addingTimeInterval(1)
        while f.store.selectedTab?.id != f.tabs[0], Date() < presentationDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(f.store.selectedTab?.id, f.tabs[0], "A confirmed \(surface) click must present without waiting for terminal metadata")
        f.releaseMetadata()
        await f.drain()
        XCTAssertEqual(f.store.selectedTab?.id, f.tabs[0])
        try f.assertNoJobs()
    }

    // Implements: FR-NAV-12
    func testNativePressKeepsImmutableTabWhenRepresentableChangesBeforeRelease() async throws {
        let f = try Fixture(); defer { f.close() }
        try await f.reset()
        let point = try f.point(.title)
        let drag = try XCTUnwrap(f.hit(point) as? TabDragView)
        drag.mouseDown(with: try f.event(.leftMouseDown, point))
        drag.tabID = f.tabs[1]
        drag.title = "Updated representable"
        drag.mouseUp(with: try f.event(.leftMouseUp, point))
        await f.drain()
        XCTAssertEqual(try f.runtime.state().layout.selectedTabID, f.tabs[0])
        XCTAssertEqual(f.store.selectedTab?.id, f.tabs[0])
        try f.assertNoJobs()
    }

    // Implements: FR-NAV-12
    func testNativeStalePressCannotRestoreAnotherWorkspace() async throws {
        let f = try Fixture(); defer { f.close() }
        try await f.reset()
        let point = try f.point(.title)
        let drag = try XCTUnwrap(f.hit(point) as? TabDragView)
        drag.mouseDown(with: try f.event(.leftMouseDown, point))
        var snapshot = try f.runtime.state()
        let other = snapshot.layout.addWorkspace(title: "Other inert workspace")
        try f.runtime.update { $0 = snapshot }
        f.store.applyCapturedNavigation(snapshot, sessions: f.sessions)
        drag.mouseUp(with: try f.event(.leftMouseUp, point))
        await f.drain()
        XCTAssertEqual(try f.runtime.state().layout.selectedWorkspaceID, other)
        XCTAssertEqual(f.store.preferredWorkspaceID, other)
        try f.assertNoJobs()
    }

    // Implements: FR-NAV-12, FR-INPUT-1
    func testNativeDragThresholdIsSeparateFromClickAndComposition() async throws {
        let f = try Fixture(); defer { f.close() }
        try await f.reset()
        let point = try f.point(.title)
        let drag = try XCTUnwrap(f.hit(point) as? TabDragView)
        var starts = 0
        drag.beginSession = { _, _, _ in starts += 1; return true }
        defer { drag.completeDrag(at: .zero, operation: [], released: false, cancelled: true) }
        drag.mouseDown(with: try f.event(.leftMouseDown, point))
        drag.mouseDragged(with: try f.event(.leftMouseDragged, NSPoint(x: point.x + 3, y: point.y)))
        XCTAssertEqual(starts, 0)
        drag.mouseUp(with: try f.event(.leftMouseUp, point))
        await f.drain()
        XCTAssertEqual(f.store.selectedTab?.id, f.tabs[0])

        try await f.reset()
        XCTAssertTrue(f.window.makeFirstResponder(f.editor))
        f.editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        let current = try XCTUnwrap(f.hit(f.point(.title)) as? TabDragView)
        current.beginSession = { _, _, _ in starts += 1; return true }
        defer { current.completeDrag(at: .zero, operation: [], released: false, cancelled: true) }
        let currentPoint = try f.point(.title)
        current.mouseDown(with: try f.event(.leftMouseDown, currentPoint))
        current.mouseDragged(with: try f.event(.leftMouseDragged, NSPoint(x: currentPoint.x + 20, y: currentPoint.y)))
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(f.editor.hasMarkedText())
        f.editor.unmarkText()
        current.mouseDown(with: try f.event(.leftMouseDown, currentPoint))
        current.mouseDragged(with: try f.event(.leftMouseDragged, NSPoint(x: currentPoint.x + 4, y: currentPoint.y)))
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(f.store.selectedTab?.id, f.tabs[1], "A started drag must not act as a click")
        current.completeDrag(at: .zero, operation: [], released: false, cancelled: true)
        try f.assertNoJobs()
    }

    private enum Surface { case title, icon, padding }

    @MainActor private final class Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let store: AppStore
        let sessions: [TerminalSession]
        let tabs: [String]
        let views: [TranoView]
        let hosting: NSHostingView<WorkspaceView>
        let window: NSWindow
        let editor = NSTextView(frame: NSRect(x: 20, y: 80, width: 200, height: 45))
        let delegate = ApplicationDelegate()
        private let initial: RuntimeState
        private let fakeBackend: FakePaneBackend?
        var metadataReady: Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("metadata-ready").path) }

        init(delayingMetadata: Bool = false) throws {
            _ = NSApplication.shared
            let directory = URL(fileURLWithPath: "/tmp/t-native-tab-click-" + UUID().uuidString.prefix(8))
            root = directory
            if delayingMetadata {
                let backend = FakePaneBackend()
                fakeBackend = backend
                let ready = directory.appendingPathComponent("metadata-ready"), release = directory.appendingPathComponent("metadata-release")
                backend.listHook = {
                    _ = FileManager.default.createFile(atPath: ready.path, contents: Data())
                    let deadline = Date().addingTimeInterval(6)
                    while !FileManager.default.fileExists(atPath: release.path) {
                        guard Date() < deadline else { throw TerminalError.runtime("Fake pane listing was never released") }
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                }
                let engine = try TerminalRuntime(root: directory)
                engine.host = backend
                runtime = engine
            } else {
                fakeBackend = nil
                runtime = try TerminalRuntime(root: directory)
            }
            let panes = (0..<2).map { TerminalSession(id: UUID().uuidString.lowercased(), title: "Inert tab \($0)", cwd: directory.path, pid: 0, alive: false) }
            sessions = panes
            var snapshot = RuntimeState()
            snapshot.settings.automaticRestore = false
            snapshot.layout.addWorkspace(title: "Inert native tab clicks")
            let tabIDs = panes.map { snapshot.layout.addTab(paneID: $0.id) }
            tabs = tabIDs
            try snapshot.layout.selectTab(tabIDs[1])
            snapshot.sessions = panes
            initial = snapshot
            try runtime.update { $0 = snapshot }
            let model = AppStore(runtime: runtime, startServices: false)
            store = model
            model.interfacePreferences.animationStyle = .off
            views = sessions.map { session in
                let view = TranoView.makeClipboardTerminal(frame: .zero)
                view.store = model; view.paneID = session.id
                model.terminalViews[session.id] = view
                return view
            }
            model.applyCapturedNavigation(snapshot, sessions: sessions)
            hosting = NSHostingView(rootView: WorkspaceView(store: model))
            window = WorkspaceWindow.make(contentRect: NSRect(x: -12000, y: -12000, width: 1100, height: 700), contentView: hosting)
            window.animationBehavior = .none
            window.orderFrontRegardless()
            hosting.addSubview(editor)
            delegate.window = window; delegate.store = model; delegate.windows[window] = model
            delegate.observeSettings(model, window: window)
        }

        func reset() async throws {
            editor.unmarkText()
            try runtime.update { $0 = initial }
            store.applyCapturedNavigation(initial, sessions: sessions)
            for _ in 0..<4 {
                hosting.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(15))
            }
            XCTAssertTrue(window.isVisible)
            XCTAssertTrue(store.terminalViews[sessions[1].id]?.window === window)
            XCTAssertNotNil(region("tab-drag-" + tabs[0], in: hosting))
        }

        func point(_ surface: Surface) throws -> NSPoint {
            let identifier: String
            switch surface {
            case .title: identifier = "tab-title-" + tabs[0]
            case .icon: identifier = "tab-agents-" + tabs[0]
            case .padding: identifier = "workspace-tab-" + tabs[0]
            }
            let view = try XCTUnwrap(region(identifier, in: hosting))
            let local = NSPoint(x: surface == .padding ? 2 : view.bounds.midX, y: view.bounds.midY)
            return view.convert(local, to: nil)
        }

        func hit(_ point: NSPoint) -> NSView? {
            guard let frame = window.contentView?.superview else { return nil }
            return frame.hitTest(frame.convert(point, from: nil))
        }

        func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }

        func click(_ point: NSPoint) throws {
            let down = try event(.leftMouseDown, point)
            if !delegate.handle(down) { window.sendEvent(down) }
            window.sendEvent(try event(.leftMouseUp, point))
        }

        func drain() async {
            for _ in 0..<3 {
                await withCheckedContinuation { continuation in
                    store.queue.async { DispatchQueue.main.async { continuation.resume() } }
                }
                hosting.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(15))
            }
        }

        func assertNoJobs(file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(try runtime.state().sessions, sessions, file: file, line: line)
            XCTAssertTrue(views.allSatisfy { !$0.started && !$0.process.running }, file: file, line: line)
            XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.host.socketPath), file: file, line: line)
            XCTAssertNil(store.message, file: file, line: line)
        }

        func releaseMetadata() {
            guard fakeBackend != nil else { return }
            try? Data().write(to: root.appendingPathComponent("metadata-release"))
        }

        func close() {
            releaseMetadata()
            editor.unmarkText()
            views.forEach { $0.frameDriver.invalidate(); $0.invalidateTerminalInteractions(); $0.terminalDelegate = nil }
            store.terminalViews.removeAll()
            window.contentView = nil; window.close()
            try? FileManager.default.removeItem(at: root)
            XCTAssertFalse(fakeBackend?.calls.contains { $0.hasPrefix("create") || $0.hasPrefix("respawn") } ?? false)
        }

        private func region(_ id: String, in view: NSView) -> NSView? {
            if view.identifier?.rawValue == id { return view }
            return view.subviews.lazy.compactMap { self.region(id, in: $0) }.first
        }
    }
}
