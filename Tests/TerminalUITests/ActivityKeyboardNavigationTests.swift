import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import SwiftTerm
@testable import TranoApp

@MainActor final class ActivityKeyboardNavigationTests: XCTestCase {
    func testCommandPeriodActivityOwnsArrowsAndEnterAheadOfUnderlyingURLHints() async throws {
        let f = try Fixture(); defer { f.close() }
        let (terminal, sent) = try await f.installInertTerminal()
        f.store.showActivity = false
        f.delegate.observeSettings(f.store, window: f.window)
        XCTAssertTrue(f.key(47, flags: .command, text: "."))
        XCTAssertTrue(f.store.showActivity)
        XCTAssertTrue(f.window.firstResponder === terminal)
        XCTAssertTrue(terminal.urlHints.start(), "The competing native hint route must actually be active")
        var opened: [URL] = []
        terminal.urlHints.openURL = { opened.append($0) }

        XCTAssertTrue(f.key(125))
        XCTAssertEqual(f.store.selectedActivityID, f.rows[1].id)
        await f.layout()
        XCTAssertNotNil(f.selectedRegion(f.rows[1].id))
        XCTAssertTrue(f.key(126))
        XCTAssertEqual(f.store.selectedActivityID, f.rows[0].id)
        XCTAssertTrue(f.key(125)); XCTAssertTrue(f.key(125))
        XCTAssertEqual(f.store.selectedActivityID, f.rows[2].id)
        XCTAssertTrue(f.key(36))
        XCTAssertFalse(f.store.showActivity)
        await f.drain()
        XCTAssertEqual(f.store.focusedID, f.rows[2].id)
        XCTAssertTrue(opened.isEmpty, "Enter belongs to the selected Activity pane")
        XCTAssertEqual(sent.withLock { $0 }, [])
        XCTAssertFalse(terminal.started); XCTAssertFalse(terminal.process.running)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.runtime.host.socketPath))
    }

    func testActivityOwnsTabAndControlTabInBothDirectionsWithoutSwitchingTerminalTabs() async throws {
        let f = try Fixture(); defer { f.close() }
        let (terminal, sent) = try await f.installInertTerminal()
        f.delegate.observeSettings(f.store, window: f.window)
        let originalTab = f.store.state.layout.selectedTabID
        for control: NSEvent.ModifierFlags in [[], .control] {
            f.store.activitySelectionID = f.rows[0].id
            XCTAssertTrue(f.key(48, flags: control, text: "\t"))
            XCTAssertEqual(f.store.selectedActivityID, f.rows[1].id)
            await f.layout()
            XCTAssertNotNil(f.selectedRegion(f.rows[1].id))
            XCTAssertTrue(f.key(48, flags: control.union(.shift), text: "\u{19}"))
            XCTAssertEqual(f.store.selectedActivityID, f.rows[0].id)
            XCTAssertTrue(f.key(48, flags: control, text: "\t"))
            XCTAssertTrue(f.key(48, flags: control, text: "\t"))
            XCTAssertEqual(f.store.selectedActivityID, f.rows[2].id)
            XCTAssertTrue(f.key(48, flags: control.union(.shift), text: "\t"))
            XCTAssertEqual(f.store.selectedActivityID, f.rows[1].id)
            XCTAssertEqual(f.store.state.layout.selectedTabID, originalTab)
            XCTAssertTrue(f.store.showActivity)
        }
        XCTAssertTrue(f.key(36))
        await f.drain()
        XCTAssertEqual(f.store.focusedID, f.rows[1].id)
        XCTAssertFalse(f.store.showActivity)
        XCTAssertEqual(sent.withLock { $0 }, [])
        XCTAssertFalse(terminal.started); XCTAssertFalse(terminal.process.running)
    }

    func testSelectedRowHasVisibleBoundsAndPaintWithUnreadCaptureCalibration() async throws {
        let f = try Fixture(); defer { f.close() }
        f.window.setContentSize(NSSize(width: 440, height: 680))
        let (terminal, sent) = try await f.installInertTerminal()
        f.store.interfacePreferences.colorScheme = .dark
        f.store.interfacePreferences.tintWithTheme = false
        f.store.showActivity = false
        f.delegate.observeSettings(f.store, window: f.window)
        XCTAssertTrue(terminal.urlHints.start())
        XCTAssertTrue(f.key(47, flags: .command, text: "."))
        XCTAssertTrue(f.store.showActivity)
        XCTAssertFalse(terminal.urlHints.isActive, "Cmd+. dismisses existing hints before opening Activity")
        XCTAssertTrue(f.window.firstResponder === terminal)
        XCTAssertTrue(f.key(125))
        XCTAssertEqual(f.store.selectedActivityID, f.rows[1].id)
        await f.layout()
        let marker = try XCTUnwrap(f.selectedRegion(f.rows[1].id))
        let rect = marker.convert(marker.bounds, to: f.hosting)
        XCTAssertTrue(f.hosting.bounds.contains(rect))
        XCTAssertGreaterThan(rect.width, 200); XCTAssertGreaterThan(rect.height, 40)
        let highlighted = try capture(f.hosting, name: "selected")
        let unread = try XCTUnwrap(f.region("activity-unread-" + f.rows[1].id))
        let unreadRect = unread.convert(unread.bounds, to: f.hosting)
        XCTAssertTrue(f.hosting.bounds.contains(unreadRect))
        let dot = try pixel(highlighted, at: NSPoint(x: unreadRect.midX, y: unreadRect.midY), in: f.hosting)
        XCTAssertGreaterThan(dot.alphaComponent, 0.8)
        XCTAssertGreaterThan(dot.blueComponent, dot.redComponent + 0.15)
        XCTAssertGreaterThan(dot.blueComponent, dot.greenComponent + 0.08)

        let point = NSPoint(x: rect.maxX - 15, y: rect.midY)
        let selected = try pixel(highlighted, at: point, in: f.hosting)
        XCTAssertTrue(f.key(126))
        XCTAssertEqual(f.store.selectedActivityID, f.rows[0].id)
        await f.layout()
        XCTAssertNil(f.selectedRegion(f.rows[1].id))
        let unselected = try pixel(capture(f.hosting, name: "unselected"), at: point, in: f.hosting)
        XCTAssertGreaterThan(selected.alphaComponent, 0.8)
        let difference = abs(selected.redComponent - unselected.redComponent)
            + abs(selected.greenComponent - unselected.greenComponent)
            + abs(selected.blueComponent - unselected.blueComponent)
        XCTAssertGreaterThan(difference, 0.1, "Selection must paint visible color in the row's empty trailing area")
        XCTAssertEqual(sent.withLock { $0 }, [])
        XCTAssertFalse(terminal.started); XCTAssertFalse(terminal.process.running)
    }

    func testArrowsFollowDisplayedSectionsWrapAndHighlightTheSelection() async throws {
        let f = try Fixture(); defer { f.close() }
        XCTAssertEqual(f.store.activityRows.map(\.id), f.rows.map(\.id))
        XCTAssertEqual(f.store.selectedActivityID, f.rows[0].id)
        XCTAssertTrue(f.key(125))
        XCTAssertEqual(f.store.selectedActivityID, f.rows[1].id)
        await f.layout()
        XCTAssertNotNil(f.selectedRegion(f.rows[1].id))
        XCTAssertTrue(f.key(125))
        XCTAssertEqual(f.store.selectedActivityID, f.rows[2].id)
        XCTAssertTrue(f.key(125))
        XCTAssertEqual(f.store.selectedActivityID, f.rows[0].id, "Down wraps from the last row to the first")
        XCTAssertTrue(f.key(126))
        XCTAssertEqual(f.store.selectedActivityID, f.rows[2].id, "Up wraps from the first row to the last")
        XCTAssertTrue(f.store.showActivity)
    }

    func testEnterFocusesExactSplitPaneInAnotherWorkspaceAndReadsItsNotification() async throws {
        let f = try Fixture(); defer { f.close() }
        XCTAssertTrue(f.key(125))
        XCTAssertTrue(f.key(36))
        XCTAssertFalse(f.store.showActivity)
        await f.drain()
        XCTAssertEqual(f.store.state.layout.selectedWorkspaceID, f.targetWorkspace)
        XCTAssertEqual(f.store.focusedID, f.rows[1].id, "Enter opens the selected split pane, not the tab's focused pane")
        XCTAssertEqual(try f.runtime.state().activityReadAt[f.rows[1].id], f.rows[1].activity.updatedAt)
        XCTAssertNil(f.store.message)
        XCTAssertTrue(f.store.terminalViews.isEmpty)
    }

    func testSelectionSurvivesReorderingFallsBackAfterRemovalAndResetsOnReopen() throws {
        let f = try Fixture(); defer { f.close() }
        XCTAssertTrue(f.key(125))
        let selected = f.rows[1].id
        f.store.sessions[1].activity.state = .running
        f.store.sessions[1].activity.updatedAt = Date.distantFuture
        XCTAssertEqual(f.store.selectedActivityID, selected)
        f.store.sessions.removeAll { $0.id == selected }
        XCTAssertEqual(f.store.selectedActivityID, f.store.activityRows.first?.id)
        f.store.showActivity = false; f.store.showActivity = true
        XCTAssertEqual(f.store.activitySelectionID, f.store.activityRows.first?.id)
    }

    func testKeypadEnterAndGroupedRowsUseTheDisplayedRepresentativePane() async throws {
        let f = try Fixture(); defer { f.close() }
        f.store.notificationPreferences.showEachProcessInTabs = false
        let id = try XCTUnwrap(f.store.activityRows.last?.id)
        while f.store.selectedActivityID != id { XCTAssertTrue(f.key(125)) }
        XCTAssertTrue(f.key(76)); await f.drain()
        XCTAssertEqual(f.store.focusedID, id)
        XCTAssertFalse(f.store.showActivity)
    }

    func testEditorsCompositionSettingsAndOtherWindowsKeepTheirKeys() throws {
        let f = try Fixture(); defer { f.close() }
        let initial = f.store.selectedActivityID
        XCTAssertFalse(f.key(125, flags: .option))
        f.store.picker = .sessions
        XCTAssertFalse(f.key(125)); f.store.picker = nil
        f.store.showSettings = true
        XCTAssertFalse(f.key(125)); XCTAssertFalse(f.key(48, flags: [.control, .shift], text: "\t")); f.store.showSettings = false
        let editor = NSTextView(frame: .zero); editor.isFieldEditor = true
        let container = NSView(frame: f.hosting.frame)
        f.hosting.removeFromSuperview(); container.addSubview(f.hosting)
        f.window.contentView = container; container.addSubview(editor)
        XCTAssertTrue(f.window.makeFirstResponder(editor))
        XCTAssertFalse(f.key(125)); XCTAssertFalse(f.key(36))
        XCTAssertFalse(f.key(48, text: "\t")); XCTAssertFalse(f.key(48, flags: [.control, .shift], text: "\u{19}"))
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(f.key(126)); XCTAssertTrue(editor.hasMarkedText())
        editor.unmarkText()
        let other = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false; defer { other.close() }
        XCTAssertFalse(f.key(125, window: other))
        XCTAssertEqual(f.store.selectedActivityID, initial)
        XCTAssertTrue(f.store.showActivity)
    }

    func testFirstUpAfterCommandPeriodWrapsToBottomEvenWhileCommandIsHeld() async throws {
        let f = try Fixture(); defer { f.close() }
        let (terminal, sent) = try await f.installInertTerminal()
        f.store.showActivity = false
        f.delegate.observeSettings(f.store, window: f.window)
        XCTAssertTrue(f.key(47, flags: .command, text: "."))
        let rows = f.store.activityRows.map(\.id)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(f.store.selectedActivityID, rows.first)
        XCTAssertTrue(f.key(126, flags: .command), "Cmd is often still held right after Cmd+.")
        XCTAssertEqual(f.store.selectedActivityID, rows.last)
        XCTAssertTrue(f.key(125, flags: .command))
        XCTAssertEqual(f.store.selectedActivityID, rows.first)
        f.store.showActivity = false
        XCTAssertTrue(f.key(47, flags: .command, text: "."))
        XCTAssertTrue(f.key(126))
        XCTAssertEqual(f.store.selectedActivityID, rows.last, "Plain Up from the top wraps to the bottom notification")
        XCTAssertTrue(f.store.showActivity)
        XCTAssertEqual(sent.withLock { $0 }, [])
        XCTAssertFalse(terminal.started)
    }

    func testFilterNarrowsRowsByTitleStatusAndKoreanLayoutAndResetsOnReopen() async throws {
        let f = try Fixture(); defer { f.close() }
        f.store.activityFilter = "done"
        XCTAssertEqual(f.store.activityRows.map(\.id), [f.rows[1].id])
        XCTAssertEqual(f.store.selectedActivityID, f.rows[1].id)
        f.store.activityFilter = "Working"
        XCTAssertEqual(f.store.activityRows.map(\.id), [f.rows[2].id], "Section status names match")
        f.store.activityFilter = "target"
        XCTAssertEqual(Set(f.store.activityRows.map(\.id)), [f.rows[1].id, f.rows[2].id], "Workspace titles match")
        f.store.activityFilter = "ㅠㅣㅐ차"
        XCTAssertEqual(f.store.activityRows.map(\.id), [f.rows[0].id], "Hangul typed on a Latin layout matches 'block'")
        f.store.activityFilter = "zzz-no-match"
        XCTAssertTrue(f.store.activityRows.isEmpty)
        XCTAssertNil(f.store.selectedActivityID)
        f.store.showActivity = false
        XCTAssertEqual(f.store.activityFilter, "")
        f.store.showActivity = true
        XCTAssertEqual(f.store.activityRows.count, 3)
    }

    func testFilterFieldEditorKeepsArrowEnterAndEscapeOwnership() async throws {
        let f = try Fixture(); defer { f.close() }
        f.delegate.observeSettings(f.store, window: f.window)
        f.window.orderFrontRegardless()
        await f.layout()
        let deadline = Date().addingTimeInterval(2)
        while !f.listOwnsFocus, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(f.listOwnsFocus, "The Activity list owns focus when Activity opens")
        XCTAssertFalse(ActivityKeyboardInput.ownsFieldEditor(f.window.firstResponder), "The filter field must not take focus when Activity opens")
        let rows = f.store.activityRows.map(\.id)
        XCTAssertTrue(f.key(126))
        XCTAssertEqual(f.store.selectedActivityID, rows.last)
        XCTAssertTrue(f.key(125))
        XCTAssertEqual(f.store.selectedActivityID, rows.first)
        XCTAssertTrue(f.key(53))
        XCTAssertFalse(f.store.showActivity)
    }

    func testFilterFieldSitsBelowTheActivityRows() async throws {
        let f = try Fixture(); defer { f.close() }
        f.window.orderFrontRegardless()
        await f.layout()
        func find(_ view: NSView, _ id: String) -> NSView? {
            if view.identifier?.rawValue == id { return view }
            return view.subviews.lazy.compactMap { find($0, id) }.first
        }
        let field = try XCTUnwrap(find(f.hosting, ActivityKeyboardInput.filterIdentifier))
        let row = try XCTUnwrap(find(f.hosting, "activity-selected-" + f.rows[0].id))
        // Window coordinates grow upward, so the bottom control has the smaller Y.
        let fieldFrame = field.convert(field.bounds, to: nil), rowFrame = row.convert(row.bounds, to: nil)
        XCTAssertLessThanOrEqual(fieldFrame.maxY, rowFrame.minY, "The filter field must sit below the Activity rows")
        let host = f.hosting.convert(f.hosting.bounds, to: nil)
        XCTAssertLessThan(fieldFrame.midY - host.minY, 40, "The filter field must be at the bottom edge of the panel")
    }

    func testTypedTextMovesFocusToFilterWhileArrowsStayOnList() async throws {
        let f = try Fixture(); defer { f.close() }
        f.delegate.observeSettings(f.store, window: f.window)
        f.window.orderFrontRegardless()
        await f.layout()
        let deadline = Date().addingTimeInterval(2)
        while !f.listOwnsFocus, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let list = try XCTUnwrap(f.window.firstResponder as? NSView)
        XCTAssertTrue(f.listOwnsFocus)
        let rows = f.store.activityRows.map(\.id)
        list.keyDown(with: f.nativeEvent(125, text: "\u{f701}"))
        XCTAssertEqual(f.store.selectedActivityID, rows[1], "Down stays on the list")
        XCTAssertTrue(f.listOwnsFocus, "Arrow keys must not move focus to the filter")
        XCTAssertEqual(f.store.activityFilter, "")
        list.keyDown(with: f.nativeEvent(2, text: "d"))
        XCTAssertTrue(ActivityKeyboardInput.ownsFieldEditor(f.window.firstResponder), "Typed text moves focus to the filter field")
        let editor = try XCTUnwrap(f.window.firstResponder as? NSTextView)
        XCTAssertEqual(editor.string, "d", "The first typed character lands in the filter")
        editor.keyDown(with: f.nativeEvent(31, text: "o"))
        XCTAssertEqual(editor.string, "do")
        let settle = Date().addingTimeInterval(2)
        while f.store.activityFilter != "do", Date() < settle { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(f.store.activityFilter, "do")
        XCTAssertEqual(f.store.activityRows.map(\.id), [f.rows[1].id])
        XCTAssertTrue(f.key(126))
        XCTAssertTrue(ActivityKeyboardInput.ownsFieldEditor(f.window.firstResponder), "Navigation from the filter keeps the filter focused")
        XCTAssertTrue(f.key(53))
        XCTAssertFalse(f.store.showActivity)
    }

    @MainActor private final class Fixture {
        let root = URL(fileURLWithPath: "/tmp/trano-activity-navigation-" + UUID().uuidString.prefix(8))
        let runtime: TerminalRuntime
        let store: AppStore
        let rows: [TerminalSession]
        let targetWorkspace: String
        let hosting: NSHostingView<ActivityListView>
        let window: NSWindow
        let delegate = ApplicationDelegate()

        init() throws {
            _ = NSApplication.shared
            runtime = try TerminalRuntime(root: root)
            let cwd = root.path
            rows = [ActivityState.blocked, .done, .running].map { state in
                var row = TerminalSession(id: UUID().uuidString.lowercased(), title: state.rawValue, cwd: cwd, pid: 0, alive: false)
                row.activity.state = state
                row.activity.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
                return row
            }
            var layout = WorkspaceLayout()
            let first = layout.addWorkspace(title: "first-session")
            layout.addTab(paneID: rows[0].id)
            targetWorkspace = layout.addWorkspace(title: "target-session")
            let tab = layout.addTab(paneID: rows[1].id)
            try layout.split(tabID: tab, paneID: rows[2].id, axis: .horizontal)
            try layout.selectWorkspace(first)
            let values = rows
            try runtime.update { $0.sessions = values; $0.layout = layout; $0.settings.automaticRestore = false }
            store = AppStore(runtime: runtime, startServices: false)
            store.state = try runtime.state(); store.sessions = rows
            store.notificationPreferences.showEachProcessInTabs = true
            hosting = NSHostingView(rootView: ActivityListView(store: store))
            window = WorkspaceWindow.make(contentRect: NSRect(x: -12000, y: -12000, width: 440, height: 300), contentView: hosting)
            window.animationBehavior = .none
            delegate.window = window; delegate.store = store; delegate.windows[window] = store
            store.showActivity = true
        }
        var listOwnsFocus: Bool {
            guard let owner = window.firstResponder as? NSView, owner.isDescendant(of: hosting) else { return false }
            return !(owner is NSTextView) && !(owner is NSTextField) && owner.acceptsFirstResponder
        }
        func nativeEvent(_ code: UInt16, flags: NSEvent.ModifierFlags = [], text: String) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        }
        func key(_ code: UInt16, flags: NSEvent.ModifierFlags = [], window target: NSWindow? = nil, text: String = "") -> Bool {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: (target ?? window).windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
            return delegate.handle(event)
        }
        func installInertTerminal() async throws -> (TranoView, SwiftTerm.Locked<[UInt8]>) {
            let terminal = TranoView(frame: hosting.bounds)
            terminal.frameDriver.invalidate()
            terminal.paneID = rows[0].id; terminal.store = store
            terminal.configure(TerminalSettings())
            store.terminalViews[terminal.paneID] = terminal
            let container = NSView(frame: hosting.frame)
            hosting.removeFromSuperview()
            container.addSubview(terminal); container.addSubview(hosting)
            window.contentView = container; window.orderFrontRegardless()
            XCTAssertTrue(window.makeFirstResponder(terminal))
            let sent = SwiftTerm.Locked<[UInt8]>([])
            terminal.setProcessInputHandler { bytes, origin, _ in
                if case .user = origin { sent.withLock { $0.append(contentsOf: bytes) } }
            }
            terminal.feed(text: "\u{1b}[2J\u{1b}[Hhttps://example.test/activity-owner")
            let deadline = Date().addingTimeInterval(2)
            while terminal.terminalContentSnapshot(region: .viewport)?.rows.first?.text.contains("https://") != true,
                  Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(terminal.terminalContentSnapshot(region: .viewport)?.rows.first?.text.contains("https://") == true)
            XCTAssertFalse(terminal.started); XCTAssertFalse(terminal.process.running)
            return (terminal, sent)
        }
        func selectedRegion(_ id: String) -> NSView? {
            region("activity-selected-" + id)
        }
        func region(_ id: String) -> NSView? {
            func find(_ view: NSView) -> NSView? {
                if view.identifier?.rawValue == id { return view }
                return view.subviews.lazy.compactMap { find($0) }.first
            }
            return find(hosting)
        }
        func layout() async {
            for _ in 0..<4 { hosting.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(15)) }
        }
        func drain() async {
            for _ in 0..<4 {
                await withCheckedContinuation { continuation in
                    store.queue.async { DispatchQueue.main.async { continuation.resume() } }
                }
            }
        }
        func close() {
            for terminal in store.terminalViews.values {
                terminal.urlHints.dismiss(); terminal.setProcessInputHandler(nil)
                terminal.invalidateTerminalInteractions()
            }
            store.terminalViews.removeAll()
            window.contentView = nil; window.close()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func capture(_ view: NSView, name: String) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let path = ProcessInfo.processInfo.environment["TRANO_ACTIVITY_CAPTURE_DIR"] {
            let root = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent(name + ".png"))
        }
        return bitmap
    }

    private func pixel(_ bitmap: NSBitmapImageRep, at point: NSPoint, in view: NSView) throws -> NSColor {
        let x = Int(point.x * CGFloat(bitmap.pixelsWide) / view.bounds.width)
        let y = Int((view.isFlipped ? point.y : view.bounds.height - point.y) * CGFloat(bitmap.pixelsHigh) / view.bounds.height)
        return try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }
}
