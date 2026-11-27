import AppKit
import SwiftUI
import XCTest
import TerminalCore
@testable import TranoApp

@MainActor final class ConversationResumeUITests: XCTestCase {
    @MainActor final class Loader {
        var pending: [ConversationResumeModel.LoadCompletion] = []
        func load(_ completion: @escaping ConversationResumeModel.LoadCompletion) { pending.append(completion) }
        func finish(_ entries: [AgentConversation], warnings: [String] = [], truncated: Bool = false) {
            guard !pending.isEmpty else { XCTFail("No load requested"); return }
            pending.removeFirst()(.success(ConversationHistorySnapshot(conversations: entries, warnings: warnings, truncated: truncated)))
        }
    }
    enum Failure: LocalizedError { case fixture; var errorDescription: String? { "Synthetic failure" } }

    func testLoadingSortsNewestFirstSearchesMetadataAndPreservesIDOnRenameRefresh() {
        let loader = Loader(); let model = ConversationResumeModel(load: loader.load, onActivate: { _ in })
        let older = entry("old", title: "한글 작업", provider: .claude, time: 1)
        let newer = entry("new", title: "Build", provider: .codex, time: 2)
        XCTAssertTrue(model.refresh()); XCTAssertTrue(model.loading)
        loader.finish([older, newer], warnings: ["Synthetic warning"], truncated: true)
        XCTAssertFalse(model.loading); XCTAssertEqual(model.filteredConversations.map(\.id), [newer.id, older.id])
        XCTAssertEqual(model.selectedID, newer.id); XCTAssertTrue(model.truncated)
        XCTAssertTrue(model.choose(id: older.id))
        XCTAssertTrue(model.refresh()); loader.finish([entry("old", title: "Renamed", provider: .claude, time: 4, label: "Renamed account"), newer])
        XCTAssertEqual(model.selectedID, older.id)
        for text in ["renamed", "project", "Renamed account", "old"] {
            XCTAssertTrue(model.setQuery(text)); XCTAssertTrue(model.filteredConversations.contains { $0.id == older.id })
        }
        XCTAssertTrue(model.setQuery("")); XCTAssertTrue(model.setProvider(.codex))
        XCTAssertEqual(model.filteredConversations.map(\.id), [newer.id])
    }

    func testSelectionSurvivesFilterWhenStillVisibleAndMovesWithoutWrapping() {
        let loader = Loader(); let model = ConversationResumeModel(load: loader.load, onActivate: { _ in })
        let a = entry("a", title: "Project A", provider: .claude, time: 3)
        let b = entry("b", title: "Project B", provider: .claude, time: 2)
        model.refresh(); loader.finish([a, b]); model.choose(id: b.id)
        model.setQuery("project"); XCTAssertEqual(model.selectedID, b.id)
        model.move(-1); XCTAssertEqual(model.selectedID, a.id)
        model.move(-1); XCTAssertEqual(model.selectedID, a.id)
        model.move(20); XCTAssertEqual(model.selectedID, b.id)
        model.setQuery("no match"); XCTAssertNil(model.selectedID); XCTAssertFalse(model.canSubmit)
    }

    func testSubmitFreezesExactEntryBusyBlocksChangesAndFailureRetainsRow() {
        let loader = Loader(); var activated: [AgentConversation] = []
        let model = ConversationResumeModel(load: loader.load, onActivate: { activated.append($0) })
        let a = entry("a", title: "Selected", provider: .codex, time: 1)
        model.refresh(); loader.finish([a]); XCTAssertTrue(model.submit())
        XCTAssertEqual(activated, [a]); XCTAssertTrue(model.resuming)
        XCTAssertFalse(model.submit()); XCTAssertFalse(model.refresh()); XCTAssertFalse(model.setQuery("different")); XCTAssertFalse(model.dismiss())
        XCTAssertFalse(model.finishActivation(error: Failure.fixture)); XCTAssertFalse(model.resuming)
        XCTAssertEqual(model.selectedID, a.id); XCTAssertEqual(model.error, "Synthetic failure")
        XCTAssertTrue(model.submit()); XCTAssertEqual(activated, [a, a])
    }

    func testDisabledSourceOnlyOpensExactLiveConversationAndOwnerIMEGatesActions() {
        let loader = Loader(); var live: [String: String] = [:]; var owner = true; var marked = false; var activations = 0
        let model = ConversationResumeModel(load: loader.load, onActivate: { _ in activations += 1 }, livePaneIDs: { live }, canInteract: { owner }, hasMarkedText: { marked })
        let a = entry("a", title: "Disabled", provider: .claude, time: 1, enabled: false)
        model.refresh(); loader.finish([a]); XCTAssertFalse(model.canSubmit); XCTAssertFalse(model.submit())
        live[a.id] = "exact-pane"; XCTAssertTrue(model.canSubmit)
        marked = true; XCTAssertFalse(model.submit()); XCTAssertFalse(model.move(1)); XCTAssertFalse(model.dismiss())
        marked = false; owner = false; XCTAssertFalse(model.submit()); XCTAssertFalse(model.dismiss())
        owner = true; XCTAssertTrue(model.submit()); XCTAssertEqual(activations, 1)
    }

    func testDismissInvalidatesPendingCompletionAndLoadFailureKeepsRows() {
        let loader = Loader(); let model = ConversationResumeModel(load: loader.load, onActivate: { _ in })
        let a = entry("a", title: "Cached", provider: .claude, time: 1)
        model.refresh(); loader.finish([a]); model.refresh()
        XCTAssertTrue(model.dismiss()); loader.finish([])
        XCTAssertEqual(model.conversations, [a]); XCTAssertFalse(model.loading)
        XCTAssertTrue(model.refresh())
        loader.pending.removeFirst()(.failure(Failure.fixture))
        XCTAssertEqual(model.conversations, [a]); XCTAssertEqual(model.selectedID, a.id); XCTAssertEqual(model.error, "Synthetic failure")
    }

    func testNativeSearchArrowsEnterEscapeAndMarkedTextKeepEditorIdentity() {
        let loader = Loader(); var activated = 0; var dismissed = 0
        let model = ConversationResumeModel(load: loader.load, onActivate: { _ in activated += 1 })
        let a = entry("a", title: "한글 Project", provider: .claude, time: 2)
        let b = entry("b", title: "Second", provider: .codex, time: 1)
        model.refresh(); loader.finish([a, b])
        let view = ConversationResumeNativeView(model: model, onDismiss: { dismissed += 1 })
        view.frame = NSRect(x: 0, y: 0, width: 560, height: 540); view.layoutSubtreeIfNeeded(); view.refresh()
        let identity = ObjectIdentifier(view.searchField)
        let editor = NSTextView(); view.editorProvider = { editor }
        editor.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.control(view.searchField, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertFalse(view.control(view.searchField, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        view.searchField.stringValue = "ㅎ"; view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.searchField))
        XCTAssertEqual(model.query, ""); XCTAssertFalse(model.dismiss())
        editor.unmarkText(); editor.string = ""
        XCTAssertTrue(view.control(view.searchField, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertEqual(model.selectedID, b.id)
        XCTAssertTrue(view.control(view.searchField, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(activated, 1)
        model.finishActivation(error: Failure.fixture); view.refresh()
        XCTAssertEqual(ObjectIdentifier(view.searchField), identity)
        XCTAssertEqual(view.table.numberOfRows, 2)
        XCTAssertTrue(view.control(view.searchField, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(dismissed, 1)
    }

    func testOverlayPanelRemainsInsideParentWithTwelvePointMargins() {
        for size in [CGSize(width: 900, height: 700), CGSize(width: 320, height: 240), CGSize(width: 10, height: 10)] {
            let panel = ConversationResumeOverlay.panelSize(in: size)
            XCTAssertGreaterThanOrEqual(panel.width, 0); XCTAssertGreaterThanOrEqual(panel.height, 0)
            XCTAssertLessThanOrEqual(panel.width, max(0, size.width - 24)); XCTAssertLessThanOrEqual(panel.height, max(0, size.height - 24))
        }
        XCTAssertEqual(ConversationResumeOverlay.panelSize(in: CGSize(width: 900, height: 700)), CGSize(width: 560, height: 540))
    }

    private func entry(_ id: String, title: String, provider: AgentKind, time: Double, label: String = "Work", enabled: Bool = true) -> AgentConversation {
        let source = ConversationHistorySource(id: provider.rawValue + "-source", provider: provider, configurationRoot: "/synthetic/config", accountID: "account", label: label, enabled: enabled)
        return AgentConversation(source: source, providerSessionID: id, title: title, cwd: "/synthetic/project", updatedAt: Date(timeIntervalSince1970: time), relativePath: "sessions/" + id + ".jsonl")
    }
}
