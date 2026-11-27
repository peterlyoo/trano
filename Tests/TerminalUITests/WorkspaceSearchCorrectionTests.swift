import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp

@MainActor final class WorkspaceSearchCorrectionTests: XCTestCase {
    func testAddRemoteHostFooterParticipatesInArrowsAndEnterWithAndWithoutAQuery() async throws {
        for compact in [true, false] {
            for query in ["", "work"] {
                let f = try Fixture(titles: ["work-one", "work-two"], compact: compact)
                defer { f.close() }
                let (field, editor) = try await search(query, in: f)
                editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
                try await layout(f)
                XCTAssertEqual(selectedTitle(f), "Add Remote Host…")
                guard selectedTitle(f) == "Add Remote Host…" else { continue }
                let selected = try XCTUnwrap(region("picker-selected-command", in: f.host))
                let footer = try XCTUnwrap(region("picker-add-remote-host-footer", in: f.host))
                XCTAssertTrue(footer.convert(footer.bounds, to: f.host).insetBy(dx: -0.5, dy: -0.5)
                    .contains(selected.convert(selected.bounds, to: f.host)))
                editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
                try await layout(f)
                XCTAssertEqual(selectedTitle(f), "New Session")
                editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
                try await layout(f)
                XCTAssertEqual(selectedTitle(f), "Add Remote Host…")
                editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
                try await layout(f)
                XCTAssertEqual(selectedTitle(f), "work-one")
                editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
                try await layout(f)
                assertInput(query, field: field, editor: editor, in: f)
                editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                XCTAssertNil(f.store.picker)
                XCTAssertTrue(f.store.showRemoteHosts)
                try assertDiskUnchanged(f)
            }
        }
    }

    func testSessionPickerArrowsWrapAcrossRowsAndFixedFooterInBothLayouts() async throws {
        for compact in [true, false] {
            let f = try Fixture(titles: ["first-session", "middle-session", "last-session"], compact: compact)
            defer { f.close() }
            let (field, editor) = try await search("", in: f)
            XCTAssertEqual(selectedTitle(f), "first-session")
            for expected in ["Add Remote Host…", "New Session", "last-session", "middle-session", "first-session", "Add Remote Host…"] {
                editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
                try await layout(f)
                XCTAssertEqual(selectedTitle(f), expected)
            }
            for expected in ["first-session", "middle-session", "last-session", "New Session", "Add Remote Host…", "first-session"] {
                editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
                try await layout(f)
                XCTAssertEqual(selectedTitle(f), expected)
            }
            assertInput("", field: field, editor: editor, in: f)
            try assertDiskUnchanged(f)
        }
    }

    func testFilteredSessionPickerWrapsAndSingleWorkspaceKeepsVisibleFooterActions() async throws {
        let f = try Fixture(titles: ["work-one", "work-two", "other"])
        defer { f.close() }
        let (field, editor) = try await search("work", in: f)
        for expected in ["Add Remote Host…", "New Session", "Create “work”", "work-two", "work-one"] {
            editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
            try await layout(f)
            XCTAssertEqual(selectedTitle(f), expected)
        }
        for expected in ["work-two", "Create “work”", "New Session", "Add Remote Host…", "work-one"] {
            editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
            try await layout(f)
            XCTAssertEqual(selectedTitle(f), expected)
        }
        editor.selectAll(nil); editor.insertText("work-one", replacementRange: editor.selectedRange())
        try await layout(f)
        for expected in ["Add Remote Host…", "New Session", "work-one"] {
            editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
            try await layout(f)
            XCTAssertEqual(selectedTitle(f), expected)
        }
        for expected in ["New Session", "Add Remote Host…", "work-one"] {
            editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
            try await layout(f)
            XCTAssertEqual(selectedTitle(f), expected)
        }
        assertInput("work-one", field: field, editor: editor, in: f)
        try assertDiskUnchanged(f)
    }

    // Implements: FR-SEARCH-2
    func testSessionPickerStartsWithFilterOrCreateWithoutATitleRow() async throws {
        for compact in [true, false] {
            let f = try Fixture(titles: ["workflow"], compact: compact)
            defer { f.close() }
            let (field, editor) = try await search("", in: f)
            XCTAssertEqual(field.placeholderAttributedString?.string ?? field.placeholderString, "Filter or create")
            XCTAssertNil(region("tool-panel-header", in: f.host))
            XCTAssertEqual(selectedTitle(f), "workflow")
            if let path = ProcessInfo.processInfo.environment["TRANO_SESSION_PICKER_CAPTURE"] {
                let folder = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(f.host.bitmapImageRepForCachingDisplay(in: f.host.bounds))
                f.host.cacheDisplay(in: f.host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: folder.appendingPathComponent(compact ? "compact.png" : "full.png"))
            }
            editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            XCTAssertNil(f.store.picker)
            try assertDiskUnchanged(f)
        }
    }

    // Implements: FR-SEARCH-2, FR-PANEL-1
    func testOtherPickersKeepTheirTitleAndCloseButton() async throws {
        let f = try Fixture(titles: ["workflow"], compact: false)
        defer { f.close() }
        for (kind, title) in [(AppStore.PickerKind.commands, "Command Palette"), (.anything, "Go to Anything"), (.movePane, "Move Pane")] {
            f.store.picker = kind
            f.host.rootView = PickerView(store: f.store, kind: kind)
            try await layout(f)
            XCTAssertEqual(region("tool-panel-header", in: f.host)?.accessibilityLabel(), title)
            let button = try XCTUnwrap(closeButton(in: f.host))
            XCTAssertEqual(button.accessibilityLabel(), "Close " + title)
            button.performClick(nil)
            XCTAssertNil(f.store.picker)
        }
        try assertDiskUnchanged(f)
    }

    // Implements: FR-SEARCH-2, FR-NAV-6
    func testClosedSessionsStayOutOfPartialExactAndCorrectedSearchResults() async throws {
        for compact in [true, false] {
            let f = try Fixture(titles: ["workflow", "Workspace", "work-archive"], compact: compact,
                                closedTitles: ["Workspace", "work-archive"], retainedTabTitles: ["work-archive"])
            defer { f.close() }
            let (field, editor) = try await search("", in: f)
            for query in ["work", "Workspace", "재가", "work-archive", ""] {
                editor.selectAll(nil)
                editor.insertText(query, replacementRange: editor.selectedRange())
                try await layout(f)
                XCTAssertNil(workspace("Workspace", in: f), "Closed zero-tab sessions must not reappear during search")
                XCTAssertNil(workspace("work-archive", in: f), "Retained tabs do not make a closed session an open search result")
                if query == "Workspace" || query == "work-archive" {
                    XCTAssertEqual(selectedTitle(f), "Create “\(query)”")
                } else {
                    XCTAssertEqual(selectedTitle(f), "workflow")
                }
                assertInput(query, field: field, editor: editor, in: f)
                try assertDiskUnchanged(f)
            }
        }
    }

    // Implements: FR-SEARCH-1, FR-SEARCH-2
    func testMarkedKoreanSuffixFiltersTheFullVisibleQueryWithoutCommittingComposition() async throws {
        for compact in [true, false] {
            let f = try Fixture(titles: ["proxysql", "roy", "project-roy-dev", "r-o-y"], compact: compact)
            defer { f.close() }
            let (field, editor) = try await search("개", in: f)
            XCTAssertNotNil(workspace("proxysql", in: f))
            editor.setMarkedText("ㅛ", selectedRange: NSRange(location: 1, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            let marked = editor.markedRange()
            try await layout(f)
            XCTAssertEqual(editor.string, "개ㅛ")
            XCTAssertTrue(editor.hasMarkedText())
            XCTAssertEqual(editor.markedRange(), marked)
            XCTAssertTrue(field.currentEditor() === editor)
            XCTAssertEqual(selectedTitle(f), "roy")
            XCTAssertNotNil(workspace("roy", in: f))
            XCTAssertNotNil(workspace("project-roy-dev", in: f))
            XCTAssertNil(workspace("proxysql", in: f))
            XCTAssertNil(workspace("r-o-y", in: f))
            XCTAssertFalse(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
            XCTAssertFalse(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
            editor.insertText("ㅛ", replacementRange: editor.markedRange())
            try await layout(f)
            XCTAssertEqual(selectedTitle(f), "roy")
            XCTAssertNil(workspace("proxysql", in: f))
            assertInput("개ㅛ", field: field, editor: editor, in: f)
            try assertDiskUnchanged(f)
        }
    }

    // Implements: FR-SEARCH-1, FR-SEARCH-2
    func testKoreanKeyboardQueryFindsEnglishWorkspacesWithoutRewritingTheEditor() async throws {
        let f = try Fixture(titles: ["home", "workflow", "workflow-extra", "unrelated"])
        defer { f.close() }
        let (field, editor) = try await search("재가리ㅐㅈ", in: f)
        XCTAssertEqual(selectedTitle(f), "workflow")
        XCTAssertNotNil(workspace("workflow", in: f))
        XCTAssertNotNil(workspace("workflow-extra", in: f))
        XCTAssertNil(workspace("home", in: f))
        XCTAssertNil(workspace("unrelated", in: f))
        XCTAssertNotNil(region("picker-workspace-context-" + f.id("workflow"), in: f.host))
        XCTAssertNotNil(region("picker-workspace-close-" + f.id("workflow"), in: f.host))

        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        try await layout(f)
        XCTAssertEqual(selectedTitle(f), "workflow-extra")
        editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
        try await layout(f)
        XCTAssertEqual(selectedTitle(f), "workflow")
        assertInput("재가리ㅐㅈ", field: field, editor: editor, in: f)
        try assertDiskUnchanged(f)
    }

    // Implements: FR-SEARCH-1, FR-SEARCH-2
    func testLiteralKoreanResultsPrecedeAlternateMatchesWithStableOrderAndNoDuplicates() async throws {
        let f = try Fixture(titles: ["gksrmf-extra", "prefix 한글", "gksrmf", "한글", "second 한글"])
        defer { f.close() }
        let (field, editor) = try await search("한글", in: f)
        let expected = ["한글", "prefix 한글", "second 한글", "gksrmf", "gksrmf-extra"]
        for (index, title) in expected.enumerated() {
            if index > 0 {
                editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
                try await layout(f)
            }
            XCTAssertEqual(selectedTitle(f), title)
            XCTAssertNotNil(workspace(title, in: f))
        }
        for title in ["New Session", "Add Remote Host…", expected[0]] {
            editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
            try await layout(f)
            XCTAssertEqual(selectedTitle(f), title, "Literal exact names must wrap through visible footer actions without a duplicate or Create row")
        }
        for title in ["Add Remote Host…", "New Session", expected[expected.count - 1]] {
            editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
            try await layout(f)
            XCTAssertEqual(selectedTitle(f), title)
        }
        assertInput("한글", field: field, editor: editor, in: f)
        try assertDiskUnchanged(f)
    }

    // Implements: FR-SEARCH-2
    func testLiveResultReorderingRetainsSelectedWorkspaceIdentityAndQuery() async throws {
        let f = try Fixture(titles: ["workflow-b", "workflow-a", "unrelated"])
        defer { f.close() }
        let (field, editor) = try await search("재가리ㅐㅈ", in: f)
        XCTAssertEqual(selectedTitle(f), "workflow-b")
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        try await layout(f)
        XCTAssertEqual(selectedTitle(f), "workflow-a")
        f.store.state.layout.workspaces.reverse()
        try await layout(f)
        XCTAssertEqual(selectedTitle(f), "workflow-a")
        XCTAssertNotNil(workspace("workflow-a", in: f))
        XCTAssertNotNil(workspace("workflow-b", in: f))
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        try await layout(f)
        XCTAssertEqual(selectedTitle(f), "workflow-b")
        assertInput("재가리ㅐㅈ", field: field, editor: editor, in: f)
        try assertDiskUnchanged(f)
    }

    // Implements: FR-SEARCH-2
    func testMarkedTextStaysNativeAndCreateKeepsTheOriginalTrimmedName() async throws {
        let f = try Fixture(titles: ["home", "workflow"], compact: false)
        defer { f.close() }
        let (field, editor) = try await search("", in: f)
        editor.setMarkedText("재", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertTrue(editor.hasMarkedText())
        let marked = editor.markedRange()
        let composed = Data(editor.string.utf8)
        XCTAssertFalse(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertFalse(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:))))
        XCTAssertFalse(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        f.store.state.layout.workspaces[1].title = "workflow-updated"
        try await layout(f)
        XCTAssertEqual(editor.markedRange(), marked)
        XCTAssertEqual(Data(editor.string.utf8), composed)
        XCTAssertEqual(selectedTitle(f), "workflow-updated")
        XCTAssertEqual(f.store.picker, .sessions)

        editor.insertText("  재가리ㅐㅈ-x  ", replacementRange: editor.markedRange())
        try await layout(f)
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(selectedTitle(f), "Create “재가리ㅐㅈ-x”")
        assertInput("  재가리ㅐㅈ-x  ", field: field, editor: editor, in: f)
        try assertDiskUnchanged(f)
    }

    @MainActor private final class Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let store: AppStore
        let window: NSWindow
        let host: NSHostingView<PickerView>
        let ids: [String: String]
        let diskBefore: Data

        init(titles: [String], compact: Bool = true, closedTitles: Set<String> = [], retainedTabTitles: Set<String> = []) throws {
            _ = NSApplication.shared
            root = URL(fileURLWithPath: "/tmp/trano-wsc-" + UUID().uuidString.prefix(8))
            runtime = try TerminalRuntime(root: root)
            var layout = WorkspaceLayout()
            var workspaceIDs: [String: String] = [:]
            for title in titles {
                workspaceIDs[title] = layout.addWorkspace(title: title)
                if retainedTabTitles.contains(title) { layout.addTab(paneID: UUID().uuidString) }
            }
            for title in closedTitles { layout.closeWorkspace(workspaceIDs[title]!) }
            ids = workspaceIDs
            if let title = titles.first, let id = workspaceIDs[title] { try layout.selectWorkspace(id) }
            try runtime.update { state in
                state.settings.automaticRestore = false
                state.layout = layout
            }
            let binding = SupervisorBinding(paneID: UUID().uuidString.lowercased(), backendPID: 4711,
                configuration: SupervisorConfiguration(provider: .claude, cwd: root.path))
            store = AppStore(runtime: runtime, externalBinding: binding)
            store.state = try runtime.state(); store.picker = .sessions
            diskBefore = try Self.diskSnapshot(runtime)
            host = NSHostingView(rootView: PickerView(store: store, kind: .sessions, compact: compact))
            window = NSWindow(contentRect: NSRect(x: -14000, y: -14000, width: compact ? 320 : 540, height: 440),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            window.orderFrontRegardless()
        }

        func id(_ title: String) -> String { ids[title]! }

        static func diskSnapshot(_ runtime: TerminalRuntime) throws -> Data {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(runtime.state())
        }

        func close() {
            store.picker = nil; window.contentView = nil; window.close()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func search(_ query: String, in f: Fixture) async throws -> (PickerSearchTextField, NSTextView) {
        try await layout(f)
        let field = try XCTUnwrap(region("picker-search-field", in: f.host) as? PickerSearchTextField)
        XCTAssertTrue(f.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        if !query.isEmpty { editor.insertText(query, replacementRange: editor.selectedRange()) }
        try await layout(f)
        return (field, editor)
    }

    private func assertInput(_ query: String, field: NSTextField, editor: NSTextView, in f: Fixture,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(editor.string, query, file: file, line: line)
        XCTAssertEqual(field.stringValue, query, file: file, line: line)
        XCTAssertTrue(f.window.firstResponder === editor, file: file, line: line)
        XCTAssertTrue(field.currentEditor() === editor, file: file, line: line)
        XCTAssertEqual(f.store.picker, .sessions, file: file, line: line)
    }

    private func assertDiskUnchanged(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Fixture.diskSnapshot(f.runtime), f.diskBefore, file: file, line: line)
        XCTAssertTrue(f.store.terminalViews.isEmpty, file: file, line: line)
        XCTAssertTrue(try f.runtime.state().sessions.isEmpty, file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.runtime.host.socketPath), file: file, line: line)
    }

    private func selectedTitle(_ f: Fixture) -> String? { region("picker-selected-command", in: f.host)?.accessibilityLabel() }
    private func workspace(_ title: String, in f: Fixture) -> NSView? { region("picker-workspace-title-" + f.id(title), in: f.host) }

    private func region(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { self.region(id, in: $0) }.first
    }

    private func closeButton(in view: NSView) -> ToolPanelCloseNativeButton? {
        if let button = view as? ToolPanelCloseNativeButton { return button }
        return view.subviews.lazy.compactMap { self.closeButton(in: $0) }.first
    }

    private func layout(_ f: Fixture) async throws {
        f.host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        f.host.layoutSubtreeIfNeeded()
    }
}
