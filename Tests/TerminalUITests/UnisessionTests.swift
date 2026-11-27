import AppKit
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class UnisessionPresentationTests: XCTestCase {
    // Implements: FR-UNI-2, FR-UNI-3, FR-UNI-4, FR-UNI-5, FR-UNI-6
    @MainActor func testSameTerminalMovesAcrossWindowsAndHidesWithoutClosing() {
        _ = NSApplication.shared
        let renderer = NSView()
        let presentation = UnisessionPresentation(renderer: renderer)
        let first = fixtureWindow(), second = fixtureWindow()
        defer { presentation.detach(); first.close(); second.close() }
        XCTAssertTrue(presentation.show(in: first, topInset: 40))
        XCTAssertTrue(renderer.window === first)
        XCTAssertTrue(presentation.show(in: second, topInset: 40))
        XCTAssertTrue(renderer.window === second)
        XCTAssertTrue(presentation.surface.renderer === renderer)
        XCTAssertTrue(presentation.hide())
        XCTAssertFalse(presentation.isPresented)
        XCTAssertTrue(presentation.show(in: first, topInset: 40))
        XCTAssertTrue(presentation.surface.renderer === renderer)
        XCTAssertTrue(renderer.window === first)
    }

    @MainActor func testGeometryStaysInsideWindowAndDoesNotResizeWorkspace() {
        _ = NSApplication.shared
        let renderer = NSView(), window = fixtureWindow()
        let presentation = UnisessionPresentation(renderer: renderer)
        defer { presentation.detach(); window.close() }
        let original = window.contentView!.bounds
        XCTAssertTrue(presentation.show(in: window, topInset: 48))
        let compact = presentation.surface.frame
        XCTAssertEqual(compact.maxX, original.maxX - 8, accuracy: 0.5)
        XCTAssertEqual(compact.maxY, original.maxY - 56, accuracy: 0.5)
        presentation.toggleExpanded()
        XCTAssertGreaterThan(presentation.surface.frame.width, compact.width)
        XCTAssertEqual(window.contentView!.bounds, original)
        presentation.toggleExpanded()
        XCTAssertEqual(presentation.surface.frame, compact)
        presentation.resize(to: NSSize(width: 10000, height: 10000))
        XCTAssertTrue(presentation.host.bounds.contains(presentation.surface.frame))
        window.contentView?.setFrameSize(NSSize(width: 260, height: 180))
        presentation.host.layoutSubtreeIfNeeded()
        XCTAssertTrue(presentation.host.bounds.contains(presentation.surface.frame))
    }

    @MainActor func testOverlayUsesTerminalColorsAndPassesOutsideClicksThrough() {
        _ = NSApplication.shared
        let presentation = UnisessionPresentation(renderer: NSView())
        let window = fixtureWindow()
        defer { presentation.detach(); window.close() }
        presentation.show(in: window, topInset: 40)
        let background = NSColor(calibratedRed: 0.16, green: 0.2, blue: 0.24, alpha: 0.6)
        presentation.surface.apply(background: background, foreground: .white)
        XCTAssertEqual(presentation.surface.layer?.backgroundColor, NSColor.clear.cgColor)
        XCTAssertEqual(presentation.surface.header.layer?.backgroundColor, background.cgColor)
        XCTAssertNil(presentation.host.hitTest(NSPoint(x: 2, y: 2)))
        XCTAssertEqual(presentation.surface.title.stringValue, "Unisession")
        XCTAssertNil(presentation.surface.subviews.first { $0.identifier?.rawValue == "supervisor-provider" })
    }

    @MainActor func testMarkedInputBlocksReparentAndHide() {
        _ = NSApplication.shared
        var protected = true
        let presentation = UnisessionPresentation(renderer: NSView(), canMove: { !protected })
        let first = fixtureWindow(), second = fixtureWindow()
        defer { protected = false; presentation.detach(); first.close(); second.close() }
        XCTAssertTrue(presentation.show(in: first, topInset: 40))
        XCTAssertFalse(presentation.show(in: second, topInset: 40))
        XCTAssertTrue(presentation.surface.renderer.window === first)
        XCTAssertFalse(presentation.hide())
        protected = false
        XCTAssertTrue(presentation.show(in: second, topInset: 40))
        XCTAssertTrue(presentation.hide())
    }

    @MainActor private func fixtureWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 960, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 700))
        return window
    }
}

final class UnisessionInputOwnershipTests: XCTestCase {
    // Implements: FR-UNI-3, FR-UNI-5
    @MainActor func testHideReleasesDescendantResponderWithoutTouchingOtherEditor() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(), terminal = UnisessionTestResponder()
        host.addSubview(terminal)
        let presentation = UnisessionPresentation(renderer: host)
        defer { presentation.detach(); window.close() }
        presentation.show(in: window, topInset: 40)
        XCTAssertTrue(window.makeFirstResponder(terminal))
        XCTAssertTrue(presentation.hide())
        XCTAssertFalse(window.firstResponder === terminal)
        let ordinary = UnisessionTestResponder()
        window.contentView?.addSubview(ordinary)
        window.makeFirstResponder(ordinary)
        presentation.show(in: window, topInset: 40)
        presentation.hide()
        XCTAssertTrue(window.firstResponder === ordinary)
    }

    @MainActor func testFocusIntentRejectsOtherWindowNewResponderOrSupersededRequest() {
        _ = NSApplication.shared
        let first = NSWindow(), second = NSWindow()
        first.isReleasedWhenClosed = false; second.isReleasedWhenClosed = false
        defer { first.close(); second.close() }
        let original = UnisessionTestResponder(), replacement = UnisessionTestResponder()
        first.contentView?.addSubview(original); first.contentView?.addSubview(replacement)
        first.makeFirstResponder(original)
        let intent = UnisessionFocusIntent(owner: first, generation: 7)
        XCTAssertTrue(intent.permitsFocus(in: first, generation: 7))
        XCTAssertFalse(intent.permitsFocus(in: second, generation: 7))
        XCTAssertFalse(intent.permitsFocus(in: first, generation: 8))
        first.makeFirstResponder(replacement)
        XCTAssertFalse(intent.permitsFocus(in: first, generation: 7))
    }

    @MainActor func testFocusIntentRejectsDestinationMarkedTextAndToolbarKeepsLegacyPreferenceID() {
        _ = NSApplication.shared
        let window = NSWindow(); window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = UnisessionTestMarkedEditor()
        window.contentView?.addSubview(editor); window.makeFirstResponder(editor)
        let intent = UnisessionFocusIntent(owner: window, generation: 1)
        XCTAssertFalse(intent.permitsFocus(in: window, generation: 1))
        XCTAssertEqual(InterfaceToolbarItem.supervisor.title, "Unisession")
        XCTAssertEqual(InterfaceToolbarItem.supervisor.rawValue, "supervisor")
    }
}

@MainActor private final class UnisessionTestResponder: NSView {
    override var acceptsFirstResponder: Bool { true }
}
@MainActor private final class UnisessionTestMarkedEditor: NSTextView {
    override func hasMarkedText() -> Bool { true }
}

final class UnisessionAppearanceTests: XCTestCase {
    // Implements: FR-UNI-4, FR-UNI-5
    func testLocalZoomOverridesAssignedProfileOnlyInExternalSnapshot() {
        let id = UUID().uuidString.lowercased()
        let binding = UnisessionBinding(paneID: id, backendPID: 42, processIdentity: SupervisorProcessIdentity(pid: 42, ownerUID: 1, startedAtSeconds: 1, startedAtMicroseconds: 0))
        var original = TerminalSettings()
        original.fontSize = 12
        let profile = AppearanceProfile(name: "Original", settings: original)
        original.appearanceProfiles = [profile]; original.paneAppearanceProfiles[id] = profile.id
        var copied = original, preferences = TerminalPreferences()
        ExternalTerminalPanePolicy.unisession(binding).applyLocalFontSize(18, settings: &copied, preferences: &preferences)
        XCTAssertEqual(preferences.resolved(legacy: copied.resolvedAppearance(for: id), profileAssigned: true).fontSize, 18)
        XCTAssertEqual(original.appearanceProfiles[0].fontSize, 12)
        XCTAssertEqual(original.fontSize, 12)
    }

    @MainActor func testHideButtonReportsWhetherItReleasedSharedInput() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let terminal = UnisessionTestResponder(), ordinary = UnisessionTestResponder()
        let presentation = UnisessionPresentation(renderer: terminal)
        defer { presentation.detach(); window.close() }
        var released: [Bool] = []
        presentation.onHide = { released.append($0) }
        window.contentView?.addSubview(ordinary)
        presentation.show(in: window, topInset: 40)
        window.makeFirstResponder(ordinary)
        let button = try XCTUnwrap(presentation.surface.header.subviews.compactMap { $0 as? NSButton }.first { $0.toolTip == "Hide Unisession" })
        button.performClick(nil)
        XCTAssertEqual(released, [false])
        XCTAssertTrue(window.firstResponder === ordinary)
        presentation.show(in: window, topInset: 40)
        window.makeFirstResponder(terminal)
        button.performClick(nil)
        XCTAssertEqual(released, [false, true])
        XCTAssertFalse(window.firstResponder === terminal)
    }
}

final class UnisessionEditorOwnershipTests: XCTestCase {
    // Implements: FR-UNI-5
    @MainActor func testNativeFindEditorBelongsToSharedTerminalButUnrelatedEditorDoesNot() {
        let terminalHost = NSView(), findBar = NSView(), editor = NSTextView(), ordinary = NSTextView()
        terminalHost.addSubview(findBar); findBar.addSubview(editor)
        XCTAssertTrue(UnisessionResponderOwnership.owns(editor, in: terminalHost))
        XCTAssertTrue(UnisessionResponderOwnership.owns(terminalHost, in: terminalHost))
        XCTAssertFalse(UnisessionResponderOwnership.owns(ordinary, in: terminalHost))
        XCTAssertFalse(UnisessionResponderOwnership.owns(nil, in: terminalHost))
    }
}

final class UnisessionNativeFindBarTests: XCTestCase {
    // Implements: FR-UNI-5
    @MainActor func testActualTerminalFindBarEditorKeepsSharedOwnershipAndHideClearsIt() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let terminal = TranoView.makeClipboardTerminal(frame: NSRect(x: 0, y: 0, width: 500, height: 280))
        let presentation = UnisessionPresentation(renderer: terminal)
        defer { presentation.detach(); window.close() }
        presentation.show(in: window, topInset: 40)
        presentation.surface.layoutSubtreeIfNeeded()
        let item = NSMenuItem(); item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        terminal.performFindPanelAction(item)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertFalse(editor === terminal)
        XCTAssertTrue(presentation.ownsInputFocus)
        XCTAssertTrue(UnisessionResponderOwnership.owns(editor, in: terminal))
        XCTAssertTrue(presentation.hide())
        XCTAssertFalse(window.firstResponder === editor)
    }
}

final class UnisessionLaunchDirectoryTests: XCTestCase {
    // Implements: FR-UNI-1, FR-UNI-3
    func testRemoteWorkspaceUsesLocalHomeAndLocalWorkspaceKeepsItsDirectory() {
        var pane = TerminalSession(id: UUID().uuidString.lowercased(), title: "Remote", cwd: "/remote/project", pid: 42)
        pane.remote = RemoteReference(hostID: UUID().uuidString.lowercased(), sessionID: "remote-pane")
        XCTAssertEqual(UnisessionLaunchDirectory.resolve(pane, home: "/local/home"), "/local/home")
        pane.remote = nil; pane.cwd = "/local/project"
        XCTAssertEqual(UnisessionLaunchDirectory.resolve(pane, home: "/local/home"), "/local/project")
        XCTAssertEqual(UnisessionLaunchDirectory.resolve(nil, home: "/local/home"), "/local/home")
    }
}
