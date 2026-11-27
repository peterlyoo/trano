import AppKit
import SwiftUI
import XCTest
import TerminalCore
@testable import TranoApp

@MainActor final class SettingsOutsideClickNativeTests: XCTestCase {
    func testActualToolPresentationsKeepInsideInputAndCloseFromTheOwner() async throws {
        let f = try Fixture(); defer { f.close() }
        let tools: [(ReferenceWritableKeyPath<AppStore, Bool>, String)] = [
            (\.showSettings, "settings-sheet"), (\.showRemoteHosts, "remote-hosts-sheet"),
            (\.showAccounts, "accounts-sheet"), (\.showExtensions, "extensions-sheet"), (\.showVoice, "voice-input-sheet-")]
        for (flag, prefix) in tools {
            f.store[keyPath: flag] = true
            try await f.settle()
            let surface = try XCTUnwrap(f.surface(prefix))
            let panel = try XCTUnwrap(surface.window as? WorkspaceToolPanelWindow)
            XCTAssertTrue(panel.parent === f.window)
            XCTAssertNil(f.window.attachedSheet)
            XCTAssertTrue(panel.canBecomeKey); XCTAssertFalse(panel.canBecomeMain)
            let inside = try f.event(in: panel, at: surface.convert(NSPoint(x: surface.bounds.midX, y: surface.bounds.midY), to: nil))
            XCTAssertFalse(OutsideClickDismissalRegistry.shared.handle(inside))
            XCTAssertTrue(f.store[keyPath: flag])
            try f.deliverOutside()
            try await f.settle()
            XCTAssertFalse(f.store[keyPath: flag], prefix)
        }
    }
    func testSettingsEscapeRetainsTheNativeCancelShortcut() async throws {
        let f = try Fixture(); defer { f.close() }
        f.store.showSettings = true
        try await f.settle()
        let panel = try XCTUnwrap(f.surface("settings-sheet")?.window)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        NSApp.sendEvent(escape)
        try await f.settle()
        XCTAssertFalse(f.store.showSettings)
    }
    func testEscapeCancelsShortcutRecordingBeforeTheSettingsPanel() async throws {
        let f = try Fixture(); defer { f.close() }
        f.store.showSettings = true
        try await f.settle()
        let panel = try XCTUnwrap(f.surface("settings-sheet")?.window)
        let recorder = ShortcutButton(frame: NSRect(x: 0, y: 0, width: 160, height: 30))
        panel.contentView?.addSubview(recorder); recorder.beginRecording()
        XCTAssertTrue(panel.firstResponder === recorder); XCTAssertTrue(recorder.recording)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        NSApp.sendEvent(escape)
        try await f.settle()
        XCTAssertTrue(f.store.showSettings)
        XCTAssertFalse(recorder.recording)
    }
    func testSettingsEscapePreservesMarkedTextBeforeCancelling() async throws {
        let f = try Fixture(); defer { f.close() }
        f.store.showSettings = true
        try await f.settle()
        let panel = try XCTUnwrap(f.surface("settings-sheet")?.window)
        let editor = MarkedEditor(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        panel.contentView?.addSubview(editor)
        XCTAssertTrue(panel.makeFirstResponder(editor))
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        XCTAssertFalse(OutsideClickDismissalRegistry.shared.handle(escape))
        XCTAssertTrue(f.store.showSettings)
        editor.marked = false
        XCTAssertTrue(OutsideClickDismissalRegistry.shared.handle(escape))
        XCTAssertFalse(f.store.showSettings)
    }
    private final class MarkedEditor: NSTextView {
        var marked = true
        override func hasMarkedText() -> Bool { marked }
    }
    func testSettingsResizeRetainsDraftAndClampsToOwnerBeforeOutsideCancel() async throws {
        let f = try Fixture(); defer { f.close() }
        f.store.state.settings.appearance.opacity = 0.8
        f.store.showSettings = true
        try await f.settle()
        let panel = try XCTUnwrap(f.surface("settings-sheet")?.window)
        func slider(_ view: NSView) -> WindowOpacityNativeSlider? {
            if let value = view as? WindowOpacityNativeSlider { return value }
            return view.subviews.lazy.compactMap { slider($0) }.first
        }
        let control = try XCTUnwrap(panel.contentView.flatMap { slider($0) })
        control.doubleValue = 0.2
        XCTAssertTrue(control.sendAction(control.action, to: control.target))
        try await f.settle()
        XCTAssertEqual(f.store.effectiveWindowOpacity, 0.2)
        f.window.setContentSize(NSSize(width: 900, height: 580))
        try await f.settle()
        let ownerBounds = f.window.convertToScreen(f.window.contentView!.bounds)
        XCTAssertTrue(ownerBounds.insetBy(dx: 15, dy: 15).contains(panel.frame))
        XCTAssertLessThan(panel.frame.height, 630)
        XCTAssertEqual(f.store.effectiveWindowOpacity, 0.2, "Resizing must not recreate the draft")
        let stored = try f.runtime.state().settings
        try f.deliverOutside()
        try await f.settle()
        XCTAssertFalse(f.store.showSettings); XCTAssertNil(f.store.windowOpacityPreview)
        XCTAssertEqual(f.store.effectiveWindowOpacity, 0.8)
        XCTAssertEqual(try f.runtime.state().settings, stored)
    }
    func testSettingsOutsideCloseWinsAboveNativeUnisessionWithoutEndingIt() async throws {
        let f = try Fixture(); let shared = UnisessionPresentation(renderer: NSView())
        defer { shared.detach(); f.close() }
        XCTAssertTrue(shared.show(in: f.window, topInset: 40))
        f.store.showSettings = true
        try await f.settle()
        XCTAssertTrue(f.surface("settings-sheet")?.window?.parent === f.window)
        try f.deliverOutside()
        try await f.settle()
        XCTAssertFalse(f.store.showSettings); XCTAssertTrue(shared.isPresented)
    }
    func testStandaloneProfilesOutsideClickUsesItsCloseCallback() async throws {
        let f = try Fixture(); defer { f.close() }
        let model = PanelState()
        f.window.contentView = NSHostingView(rootView: ProfilesHost(store: f.store, model: model))
        try await f.settle()
        XCTAssertNotNil(f.surface("appearance-profiles-sheet"))
        XCTAssertNil(f.window.attachedSheet)
        try f.deliverOutside()
        try await f.settle()
        XCTAssertFalse(model.visible)
    }
    @MainActor private final class PanelState: ObservableObject { @Published var visible = true }
    private struct ProfilesHost: View {
        let store: AppStore
        @ObservedObject var model: PanelState
        var body: some View {
            Color.clear.workspacePanel(isPresented: model.visible) {
                ProfileAppearanceView(store: store, onClose: { model.visible = false })
            }
        }
    }
    @MainActor private final class Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let store: AppStore
        let window: NSWindow
        private let delegate = ApplicationDelegate()
        private var monitor: Any?
        init() throws {
            _ = NSApplication.shared
            root = URL(fileURLWithPath: "/tmp/trano-sp-" + UUID().uuidString.prefix(8))
            runtime = try TerminalRuntime(root: root)
            let binding = SupervisorBinding(paneID: UUID().uuidString, backendPID: 4711,
                configuration: SupervisorConfiguration(provider: .claude, cwd: root.path))
            store = AppStore(runtime: runtime, externalBinding: binding)
            window = WorkspaceWindow.make(contentRect: NSRect(x: -12000, y: -12000, width: 1100, height: 850),
                contentView: NSHostingView(rootView: WorkspaceView(store: store)))
            window.animationBehavior = .none; window.orderFrontRegardless()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [weak self] event in
                self?.delegate.handle(event) == true ? nil : event
            }
        }
        func settle() async throws {
            for _ in 0..<8 { window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(15)) }
        }
        func surface(_ prefix: String) -> NSView? {
            func find(_ view: NSView) -> NSView? {
                if view.identifier?.rawValue.hasPrefix("outside-dismissal-" + prefix) == true { return view }
                return view.subviews.lazy.compactMap { find($0) }.first
            }
            return (window.childWindows ?? []).lazy.compactMap { $0.contentView.flatMap { find($0) } }.first
        }
        func event(in target: NSWindow, at point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        func deliverOutside() throws { NSApp.sendEvent(try event(in: window, at: NSPoint(x: 2, y: 2))) }
        func close() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            window.contentView = nil; window.close()
            try? FileManager.default.removeItem(at: root)
        }
    }
    private func findSettings(in window: NSWindow) -> NSView? {
        func find(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == "outside-dismissal-settings-sheet" { return view }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        for child in window.childWindows ?? [] where child.parent === window {
            if let view = child.contentView.flatMap({ find($0) }) { return view }
        }
        return nil
    }
    func testActualWorkspaceSettingsPresentationCancelsFromOwnerEventDelivery() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-so-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        let binding = SupervisorBinding(paneID: UUID().uuidString, backendPID: 4711,
            configuration: SupervisorConfiguration(provider: .claude, cwd: root.path))
        let store = AppStore(runtime: runtime, externalBinding: binding)
        let host = NSHostingView(rootView: WorkspaceView(store: store))
        let window = WorkspaceWindow.make(contentRect: NSRect(x: -12000, y: -12000, width: 1100, height: 850), contentView: host)
        window.animationBehavior = .none
        window.orderFrontRegardless()
        let delegate = ApplicationDelegate()
        var observed = 0
        let monitor = try XCTUnwrap(NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            observed += 1
            return delegate.handle(event) ? nil : event
        })
        defer {
            NSEvent.removeMonitor(monitor)
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.contentView = nil; window.close()
            try? FileManager.default.removeItem(at: root)
        }
        func click(_ point: NSPoint) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            NSApp.sendEvent(event)
        }
        try click(NSPoint(x: 200, y: 100))
        XCTAssertEqual(observed, 1, "Control event must traverse the actual local event monitor")
        store.showSettings = true
        for _ in 0..<30 {
            host.layoutSubtreeIfNeeded()
            if findSettings(in: window) != nil || window.attachedSheet != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); window.attachedSheet?.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(window.attachedSheet, "Settings must not block owner mouse input with a document-modal sheet")
        XCTAssertNotNil(findSettings(in: window), "Actual Settings surface must belong to a native nonmodal child of its Trano owner")
        XCTAssertNotNil(store.windowOpacityPreview)
        let before = try runtime.state().settings
        observed = 0
        try click(NSPoint(x: 200, y: 100))
        for _ in 0..<8 { await Task.yield() }
        XCTAssertFalse(store.showSettings, "Owner-window outside click must invoke actual Settings Cancel")
        XCTAssertNil(store.windowOpacityPreview, "Cancel must end its window-opacity preview")
        XCTAssertEqual(try runtime.state().settings, before)
    }
}
