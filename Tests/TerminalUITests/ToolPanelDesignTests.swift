import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp

@MainActor final class ToolPanelDesignTests: XCTestCase {
    // Implements: FR-PANEL-1, FR-PANEL-3
    func testActualActivityUsesTheExistingLightAndDarkInterfaceSurfaces() async throws {
        for scheme in [InterfaceColorScheme.light, .dark] {
            let root = URL(fileURLWithPath: "/tmp/trano-design-" + UUID().uuidString.prefix(8))
            let runtime = try TerminalRuntime(root: root)
            let binding = SupervisorBinding(paneID: UUID().uuidString, backendPID: 4711,
                configuration: SupervisorConfiguration(provider: .claude, cwd: root.path))
            let store = AppStore(runtime: runtime, externalBinding: binding)
            store.interfacePreferences.colorScheme = scheme
            store.interfacePreferences.tintWithTheme = false
            let host = NSHostingView(rootView: ActivityListView(store: store))
            let window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 320, height: 420), styleMask: [], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.animationBehavior = .none; window.contentView = host
            window.orderFrontRegardless()
            defer { window.contentView = nil; window.close(); try? FileManager.default.removeItem(at: root) }
            for _ in 0..<6 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(15)) }
            let bitmap = try capture(host)
            let expected = NSColor(hex: scheme == .light ? "#F5F5F7" : "#141416")
            try assertColor(bitmap.colorAt(x: 4, y: 200), matches: expected)
            try writeCapture(bitmap, name: "activity-" + scheme.rawValue)
        }
    }
    // Implements: FR-PANEL-1, FR-PANEL-2, FR-PANEL-3
    func testActualToolsShareHeaderGeometryAndRenderedLightDarkAndTintSurfaces() async throws {
        let f = try Fixture(); defer { f.close() }
        for mode in ["light", "dark", "tint"] {
            f.store.interfacePreferences.colorScheme = mode == "light" ? .light : .dark
            f.store.interfacePreferences.tintWithTheme = mode == "tint"
            f.store.state.settings.background = "#011423"
            f.store.state.settings.appearance.foreground = "#CBE0F0"
            let theme = f.store.toolPanelTheme
            let draft = AccountOrganizationDraft(profileID: "fixture", state: nil, knownOrganizations: [],
                refresh: { _, _ in nil }, save: { _, _, _ in })
            let request = RemotePathRequest(paneID: "no-renderer", hostID: "no-host", path: "~", directoryOnly: false,
                owner: TerminalInteractionOwner(paneID: "no-renderer", windowID: ObjectIdentifier(f.window), generation: UUID()))
            let resume = ConversationResumeModel(load: { $0(.success(ConversationHistorySnapshot(conversations: [], warnings: [], truncated: false))) }, onActivate: { _ in })
            let panels: [(String, CGFloat, CGFloat, AnyView)] = [
                ("activity", 320, 420, AnyView(ActivityListView(store: f.store))),
                ("queue", 540, 560, AnyView(FollowUpQueueView(store: f.store))),
                ("decisions", 440, 560, AnyView(DecisionInboxView(entries: [], onResolve: { _, _, _, _, _ in }, onDismiss: {}))),
                ("palette", 540, 380, AnyView(PickerView(store: f.store, kind: .commands))),
                ("resume", 584, 564, AnyView(ConversationResumeOverlay(model: resume, onDismiss: {}))),
                ("settings", 880, 630, AnyView(SettingsView(store: f.store))),
                ("profiles", 720, 560, AnyView(ProfileAppearanceView(store: f.store))),
                ("accounts", 740, 440, AnyView(AccountsView(store: f.store))),
                ("organizations", 492, 360, AnyView(AccountOrganizationEditorPresentation(draft: draft, theme: theme, close: {}))),
                ("remote-hosts", 760, 460, AnyView(RemoteHostsView(store: f.store))),
                ("remote-paths", 620, 470, AnyView(RemotePathsView(store: f.store, request: request))),
                ("extensions", 800, 480, AnyView(ExtensionsView(store: f.store))),
                ("voice", 560, 340, AnyView(VoiceInputView(store: f.store)))
            ]
            for (name, width, height, view) in panels {
                let host = NSHostingView(rootView: view.environment(\.toolPanelTheme, theme))
                f.window.setContentSize(NSSize(width: width, height: height)); f.window.contentView = host
                try await settle(f.window)
                if name == "organizations" { XCTAssertLessThan(host.bounds.height, 500, "Organization text must measure against its fixed form width") }
                let surfaces = descendants(host).compactMap { $0 as? ToolPanelSurfaceView }
                XCTAssertEqual(surfaces.count, 1, "\(name)-\(mode)")
                let surface = try XCTUnwrap(surfaces.first)
                XCTAssertEqual(surface.theme, theme, "\(name)-\(mode)")
                let headers = descendants(host).filter { $0.identifier?.rawValue == "tool-panel-header" }
                XCTAssertEqual(headers.count, 1, "\(name)-\(mode)")
                let header = try XCTUnwrap(headers.first)
                XCTAssertEqual(header.bounds.height, 40, accuracy: 0.5, "\(name)-\(mode)")
                XCTAssertGreaterThan(header.bounds.width, 200, "\(name)-\(mode)")
                XCTAssertEqual(header.visibleRect.intersection(header.bounds).height, 40, accuracy: 0.5, "\(name)-\(mode)")
                let bitmap = try capture(surface)
                try assertColor(bitmap.colorAt(x: 4, y: min(80, bitmap.pixelsHigh - 4)), matches: theme.backgroundNS)
                let rendered = try capture(host)
                if name == "settings" {
                    let bg = try XCTUnwrap(theme.backgroundNS.usingColorSpace(.sRGB))
                    let titleInk = (8..<30).reduce(0) { total, y in
                        total + (16..<100).filter { x in
                            guard let color = rendered.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                            return abs(color.redComponent - bg.redComponent) + abs(color.greenComponent - bg.greenComponent) + abs(color.blueComponent - bg.blueComponent) > 0.3
                        }.count
                    }
                    XCTAssertGreaterThan(titleInk, 30, "Actual Settings title must remain visible above native content")
                }
                try writeCapture(rendered, name: name + "-" + mode)
                f.window.contentView = nil
            }
        }
    }
    // Implements: FR-PANEL-4, FR-PANEL-5
    func testOpenSettingsRepaintsInPlaceAndCancelKeepsTheOriginalDraft() async throws {
        let f = try Fixture(); defer { f.close() }
        f.store.interfacePreferences.colorScheme = .dark; f.store.interfacePreferences.tintWithTheme = false
        f.store.state.settings.appearance.opacity = 0.8
        f.window.contentView = NSHostingView(rootView: WorkspaceView(store: f.store))
        f.store.showSettings = true; try await settle(f.window)
        let panel = try XCTUnwrap(f.window.childWindows?.first as? WorkspaceToolPanelWindow)
        let root = try XCTUnwrap(panel.contentView)
        let surface = try XCTUnwrap(descendants(root).compactMap { $0 as? ToolPanelSurfaceView }.first)
        let slider = try XCTUnwrap(descendants(root).compactMap { $0 as? WindowOpacityNativeSlider }.first)
        slider.doubleValue = 0.2
        XCTAssertTrue(slider.sendAction(slider.action, to: slider.target)); try await settle(f.window)
        XCTAssertEqual(f.store.effectiveWindowOpacity, 0.2)
        f.store.interfacePreferences.colorScheme = .light
        try await settle(f.window)
        XCTAssertTrue(panel === f.window.childWindows?.first)
        XCTAssertTrue(descendants(root).contains { $0 === surface })
        XCTAssertTrue(descendants(root).contains { $0 === slider })
        XCTAssertEqual(surface.theme, f.store.toolPanelTheme)
        XCTAssertEqual(panel.appearance?.name, .aqua)
        XCTAssertEqual(slider.doubleValue, 0.2, accuracy: 0.001)
        XCTAssertEqual(f.store.effectiveWindowOpacity, 0.2)
        try assertColor(try capture(surface).colorAt(x: 4, y: 80), matches: f.store.toolPanelTheme.backgroundNS)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        XCTAssertTrue(OutsideClickDismissalRegistry.shared.handle(event))
        try await settle(f.window)
        XCTAssertFalse(f.store.showSettings); XCTAssertNil(f.store.windowOpacityPreview)
        XCTAssertEqual(f.store.effectiveWindowOpacity, 0.8)
    }
    // Implements: FR-PANEL-2, FR-PANEL-4, FR-PANEL-5
    func testNativeResumeRepaintsWithoutReplacingMarkedTextOrModel() async throws {
        let f = try Fixture(); defer { f.close() }
        let model = ConversationResumeModel(load: { $0(.success(ConversationHistorySnapshot(conversations: [], warnings: [], truncated: false))) }, onActivate: { _ in })
        XCTAssertTrue(model.setQuery("검토"))
        let view = ConversationResumeNativeView(model: model, onDismiss: {})
        f.window.contentView = view; try await settle(f.window)
        f.window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(f.window.makeFirstResponder(view.searchField))
        let editor = try XCTUnwrap(view.searchField.currentEditor() as? NSTextView)
        editor.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let text = editor.string, selection = editor.selectedRange(), marked = editor.markedRange(), undo = editor.undoManager?.canUndo
        let light = ToolPanelTheme(background: "#F5F5F7", foreground: "#242426", accent: "#287A70", isDark: false)
        view.configure(model: model, onDismiss: {}, theme: light)
        XCTAssertTrue(view.model === model); XCTAssertTrue(view.searchField.currentEditor() === editor)
        XCTAssertEqual(editor.string, text); XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(editor.markedRange(), marked); XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.undoManager?.canUndo, undo); XCTAssertEqual(model.query, "검토")
        XCTAssertEqual(view.header.bounds.height, 40); XCTAssertEqual(view.searchField.font?.pointSize, 12)
        XCTAssertEqual(view.layer?.borderWidth, 0)
        try assertColor(editor.textColor, matches: light.foregroundNS)
        editor.unmarkText()
    }
    // Implements: FR-PANEL-2, FR-PANEL-4, FR-PANEL-5
    func testUnisessionStylesOnlyChromeAndRetainsRendererAndHideAction() throws {
        let renderer = NSView(); renderer.wantsLayer = true; renderer.layer?.backgroundColor = NSColor.systemPurple.cgColor
        let originalColor = renderer.layer?.backgroundColor
        let view = UnisessionSurfaceView(renderer: renderer)
        view.frame = NSRect(x: 0, y: 0, width: 500, height: 310); view.layoutSubtreeIfNeeded()
        var hidden = 0; view.onHide = { hidden += 1 }
        let theme = ToolPanelTheme(background: "#011423", foreground: "#CBE0F0", accent: "#63C9D5", isDark: true)
        view.apply(theme: theme)
        XCTAssertTrue(view.renderer === renderer); XCTAssertEqual(renderer.layer?.backgroundColor, originalColor)
        XCTAssertEqual(view.header.bounds.height, 40); XCTAssertEqual(view.title.font?.pointSize, 13)
        XCTAssertEqual(view.layer?.cornerRadius, 8)
        let close = try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first { $0.toolTip == "Hide Unisession" })
        XCTAssertEqual(close.bounds.size, NSSize(width: 24, height: 24)); close.performClick(nil)
        XCTAssertEqual(hidden, 1); XCTAssertTrue(view.renderer === renderer)
    }
    // Implements: FR-PANEL-3, FR-PANEL-5
    func testOrganizationHeaderCancelWorksAsSoonAsThePresentationMounts() async throws {
        let f = try Fixture(); defer { f.close() }
        var cancelled = 0
        let draft = AccountOrganizationDraft(profileID: "fixture", state: nil, knownOrganizations: [],
            refresh: { _, _ in nil }, save: { _, _, _ in }, cancel: { cancelled += 1 })
        let host = NSHostingView(rootView: AccountOrganizationEditorPresentation(draft: draft, close: {}))
        f.window.contentView = host; f.window.setContentSize(NSSize(width: 492, height: 360))
        try await settle(f.window)
        let buttons = descendants(host).compactMap { $0 as? NSButton }.filter { $0.accessibilityLabel() == "Cancel" }
        XCTAssertGreaterThanOrEqual(buttons.count, 2)
        let header = try XCTUnwrap(buttons.first { $0 is ToolPanelCloseNativeButton })
        XCTAssertEqual(header.bounds.size, NSSize(width: 24, height: 24))
        XCTAssertTrue(header.isEnabled); header.performClick(nil)
        try await settle(f.window)
        XCTAssertTrue(draft.isClosed); XCTAssertEqual(cancelled, 1)
    }
    // Implements: FR-PANEL-2, FR-PANEL-4
    func testNativeControlTypographyAndRecordingSurviveThemeUpdates() async throws {
        let f = try Fixture(); defer { f.close() }
        let state = ControlTheme()
        let host = NSHostingView(rootView: NativeControls(state: state))
        f.window.contentView = host; try await settle(f.window)
        let font = try XCTUnwrap(descendants(host).compactMap { $0 as? FontChoicePopUpButton }.first)
        let recorder = try XCTUnwrap(descendants(host).compactMap { $0 as? ShortcutButton }.first)
        recorder.beginRecording(); XCTAssertTrue(recorder.recording)
        let title = font.title
        state.theme = ToolPanelTheme(background: "#F5F5F7", foreground: "#242426", accent: "#287A70", isDark: false)
        try await settle(f.window)
        XCTAssertTrue(descendants(host).contains { $0 === font }); XCTAssertTrue(descendants(host).contains { $0 === recorder })
        XCTAssertEqual(font.font?.pointSize, 12); XCTAssertEqual(recorder.font?.pointSize, 12)
        XCTAssertEqual(font.controlSize, .small); XCTAssertEqual(recorder.controlSize, .small)
        XCTAssertEqual(font.appearance?.name, .aqua); XCTAssertEqual(recorder.appearance?.name, .aqua)
        XCTAssertEqual(font.title, title); XCTAssertTrue(recorder.recording)
    }
    // Implements: FR-PANEL-2, FR-PANEL-5
    func testNativeBackgroundPaintersNeverEraseSiblingContentOutsideTheirBounds() throws {
        for view in [SettingsNavigationSidebarView(frame: .zero), ToolPanelSurfaceView(frame: .zero)] as [NSView] {
            view.frame = NSRect(x: 0, y: 0, width: 148, height: 100)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 300,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSColor.magenta.setFill(); NSRect(x: 0, y: 0, width: 300, height: 300).fill()
            view.draw(NSRect(x: -100, y: -100, width: 500, height: 500))
            NSGraphicsContext.restoreGraphicsState()
            try assertColor(bitmap.colorAt(x: 200, y: 200), matches: .magenta)
        }
    }
    @MainActor private final class ControlTheme: ObservableObject { @Published var theme = ToolPanelTheme.defaultDark }
    private struct NativeControls: View {
        @ObservedObject var state: ControlTheme
        var body: some View {
            VStack {
                FontChoicePicker(title: "Font", selection: .constant("Menlo"))
                KeyboardShortcutRecorder(value: "cmd+k", onChange: { _ in }).frame(width: 142, height: 26)
            }.padding(16).toolPanelSurface(state.theme)
        }
    }
    @MainActor private final class Fixture {
        let root: URL
        let store: AppStore
        let window: NSWindow
        init() throws {
            _ = NSApplication.shared
            root = URL(fileURLWithPath: "/tmp/trano-style-" + UUID().uuidString.prefix(8))
            let runtime = try TerminalRuntime(root: root)
            let binding = SupervisorBinding(paneID: UUID().uuidString, backendPID: 4711,
                configuration: SupervisorConfiguration(provider: .claude, cwd: root.path))
            store = AppStore(runtime: runtime, externalBinding: binding)
            window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 1100, height: 850), styleMask: [], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.animationBehavior = .none; window.orderFrontRegardless()
        }
        func close() {
            for child in window.childWindows ?? [] { window.removeChildWindow(child); child.contentView = nil; child.close() }
            window.contentView = nil; window.close(); try? FileManager.default.removeItem(at: root)
        }
    }
    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<8 {
            window.contentView?.layoutSubtreeIfNeeded()
            for child in window.childWindows ?? [] { child.contentView?.layoutSubtreeIfNeeded() }
            try await Task.sleep(for: .milliseconds(15))
        }
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    private func writeCapture(_ bitmap: NSBitmapImageRep, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["TRANO_TOOL_PANEL_CAPTURE_DIR"], !path.isEmpty else { return }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }
    private func capture(_ view: NSView) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
    private func assertColor(_ actual: NSColor?, matches expected: NSColor, file: StaticString = #filePath, line: UInt = #line) throws {
        let a = try XCTUnwrap(actual?.usingColorSpace(.sRGB), file: file, line: line)
        let e = try XCTUnwrap(expected.usingColorSpace(.sRGB), file: file, line: line)
        XCTAssertEqual(a.alphaComponent, 1, accuracy: 1.0 / 255, file: file, line: line)
        XCTAssertEqual(a.redComponent, e.redComponent, accuracy: 2.0 / 255, file: file, line: line)
        XCTAssertEqual(a.greenComponent, e.greenComponent, accuracy: 2.0 / 255, file: file, line: line)
        XCTAssertEqual(a.blueComponent, e.blueComponent, accuracy: 2.0 / 255, file: file, line: line)
    }
}
