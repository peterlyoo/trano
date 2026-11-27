import XCTest
import AppKit
import SwiftUI
@testable import TerminalCore
@testable import TranoApp

final class DecisionInboxViewTests: XCTestCase {
    // Implements: FR-DECISION-4
    @MainActor func testNativeChoiceAndSendAnswerNeedNoExtraReviewScreen() async throws {
        _ = NSApplication.shared
        let label = DecisionText(en: "Disk", ko: "디스크")
        let question = DecisionQuestion(requestID: UUID().uuidString.lowercased(), threadID: UUID().uuidString.lowercased(),
            source: DecisionSource(agent: "codex", sessionID: "fixture-session", workspace: "/fixture/workspace"),
            question: label, options: [DecisionOption(id: "disk", label: label, description: label), DecisionOption(id: "memory", label: label, description: label)])
        let entry = DecisionInboxEntry(question: question, paneID: "pane", generation: "generation", createdAt: Date(), status: "pending", delivered: false)
        var answers: [(String, String?, String?)] = []
        let hosting = NSHostingView(rootView: DecisionInboxView(entries: [entry], onResolve: { _, action, option, text, _ in answers.append((action, option, text)) }, onDismiss: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()
        defer { window.close() }
        func button(_ id: String, in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.identifier?.rawValue == id { return button }
            for child in view.subviews { if let found = button(id, in: child) { return found } }
            return nil
        }
        try await Task.sleep(for: .milliseconds(120)); hosting.layoutSubtreeIfNeeded()
        XCTAssertFalse(try XCTUnwrap(button("decision-send", in: hosting)).isEnabled)
        let choice = try XCTUnwrap(button("decision-option-disk", in: hosting))
        XCTAssertTrue(choice.target === choice)
        choice.performClick(nil)
        try await Task.sleep(for: .milliseconds(80)); hosting.layoutSubtreeIfNeeded()
        let send = try XCTUnwrap(button("decision-send", in: hosting))
        XCTAssertTrue(send.isEnabled)
        XCTAssertTrue(send.target === send)
        send.performClick(nil)
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers.first?.0, "choose")
        XCTAssertEqual(answers.first?.1, "disk")
        try XCTUnwrap(button("decision-cancel", in: hosting)).performClick(nil)
        XCTAssertEqual(answers.last?.0, "cancel")
    }

    // Implements: FR-DECISION-4, FR-INPUT-1
    @MainActor func testSendAnswerCommitsTheComposingSyllableInsteadOfIgnoringTheClick() async throws {
        _ = NSApplication.shared
        let label = DecisionText(en: "Disk", ko: "디스크")
        let question = DecisionQuestion(requestID: UUID().uuidString.lowercased(), threadID: UUID().uuidString.lowercased(),
            source: DecisionSource(agent: "claude", sessionID: "fixture-session", workspace: "/fixture/workspace"),
            question: label, options: [DecisionOption(id: "disk", label: label, description: label)])
        let entry = DecisionInboxEntry(question: question, paneID: "pane", generation: "generation", createdAt: Date(), status: "pending", delivered: false)
        var answers: [(String, String?, String?)] = []
        let hosting = NSHostingView(rootView: DecisionInboxView(entries: [entry], onResolve: { _, action, option, text, _ in answers.append((action, option, text)) }, onDismiss: {}))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 440, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.close() }
        func region(_ id: String, in view: NSView) -> NSView? {
            if view.identifier?.rawValue == id { return view }
            return view.subviews.lazy.compactMap { region(id, in: $0) }.first
        }
        try await Task.sleep(for: .milliseconds(120)); hosting.layoutSubtreeIfNeeded()
        try XCTUnwrap(region("decision-other", in: hosting) as? NSButton).performClick(nil)
        try await Task.sleep(for: .milliseconds(80)); hosting.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(region("decision-instruction", in: hosting) as? NSTextView)
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.insertText("세 번째로 진행", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.setMarkedText("해", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        try await Task.sleep(for: .milliseconds(80)); hosting.layoutSubtreeIfNeeded()
        let send = try XCTUnwrap(region("decision-send", in: hosting) as? NSButton)
        XCTAssertTrue(send.isEnabled)
        send.performClick(nil)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers.first?.0, "revise")
        XCTAssertEqual(answers.first?.2, "세 번째로 진행해")
    }

    // Implements: FR-DECISION-4
    func testChoiceOrOtherTextIsRequiredAndSelectionPreservesTheDraft() {
        var draft = DecisionDraft()
        XCTAssertFalse(draft.canSend)
        draft.selectOther()
        XCTAssertFalse(draft.canSend)
        draft.instruction = "다른 방법\nKeep UTF-8"
        XCTAssertTrue(draft.canSend)
        draft.select("disk")
        XCTAssertFalse(draft.other)
        XCTAssertTrue(draft.canSend)
        XCTAssertEqual(draft.selectionID, "disk")
        XCTAssertEqual(draft.instruction, "다른 방법\nKeep UTF-8")
    }

    // Implements: FR-DECISION-5, FR-INPUT-1
    @MainActor func testRetiredQuestionCannotCommitItsMarkedDraftIntoTheNextQuestion() async throws {
        _ = NSApplication.shared
        func entry(_ name: String) -> DecisionInboxEntry {
            let text = DecisionText(en: name, ko: name)
            let question = DecisionQuestion(requestID: UUID().uuidString.lowercased(), threadID: UUID().uuidString.lowercased(),
                source: DecisionSource(agent: "codex", sessionID: "fixture-session", workspace: "/fixture/workspace"),
                question: text, options: ["disk", "memory"].map { DecisionOption(id: name + "-" + $0, label: text, description: text) })
            return DecisionInboxEntry(question: question, paneID: "pane", generation: "generation", createdAt: Date(), status: "pending", delivered: false)
        }
        let first = entry("first"), second = entry("second")
        let expected = "두 번째 초안 " + "한글".decomposedStringWithCanonicalMapping + " 👩🏽‍💻"
        let model = QuestionDraftFixture(entries: [first, second], drafts: [
            first.id: DecisionDraft(instruction: "첫 번째 초안 ", other: true),
            second.id: DecisionDraft(instruction: expected, other: true)
        ])
        let hosting = NSHostingView(rootView: QuestionDraftFixtureView(model: model))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 440, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.close() }
        func region(_ id: String, in view: NSView) -> NSView? {
            if view.identifier?.rawValue == id { return view }
            return view.subviews.lazy.compactMap { region(id, in: $0) }.first
        }
        try await Task.sleep(for: .milliseconds(120))
        hosting.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(region("decision-instruction", in: hosting) as? NSTextView)
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        model.entries = [second]
        let deadline = Date().addingTimeInterval(2)
        while region("decision-option-second-disk", in: hosting) == nil && Date() < deadline {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(region("decision-option-second-disk", in: hosting))
        editor.unmarkText()
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        let current = try XCTUnwrap(region("decision-instruction", in: hosting) as? NSTextView)
        XCTAssertEqual(Data(try XCTUnwrap(model.drafts[second.id]).instruction.utf8), Data(expected.utf8))
        XCTAssertEqual(Data(current.string.utf8), Data(expected.utf8))
    }

    // Implements: FR-DECISION-4
    @MainActor func testNativeOverlayStaysInItsOwningWindowWithoutResizingTerminal() async throws {
        let text = DecisionText(en: "Choose storage", ko: "저장소 선택")
        let options = ["disk", "memory"].map { DecisionOption(id: $0, label: text, description: DecisionText(en: String(repeating: "A long description. ", count: 12), ko: "설명")) }
        let question = DecisionQuestion(requestID: UUID().uuidString.lowercased(), threadID: UUID().uuidString.lowercased(), source: DecisionSource(agent: "codex", sessionID: "fixture-session", workspace: "/fixture/workspace"), question: text, options: options)
        let entry = DecisionInboxEntry(question: question, paneID: "fixture-pane", generation: "fixture-generation", createdAt: Date(), status: "pending", delivered: false)
        let content = NSHostingView(rootView: ZStack {
            Color.black.background(WorkspaceRegion("fixture-terminal"))
            DecisionInboxOverlay(entries: [entry], onResolve: { _, _, _, _, _ in }, onDismiss: {})
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 360), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        try await Task.sleep(for: .milliseconds(100))
        content.layoutSubtreeIfNeeded()
        defer { window.close() }
        XCTAssertEqual(content.bounds.size, NSSize(width: 500, height: 360))
        XCTAssertTrue(content.window === window)
        XCTAssertEqual(window.contentView?.bounds.size, NSSize(width: 500, height: 360))
        func region(_ id: String, in view: NSView) -> NSView? {
            if view.identifier?.rawValue == id { return view }
            return view.subviews.lazy.compactMap { region(id, in: $0) }.first
        }
        let panel = try XCTUnwrap(region("decision-inbox-panel", in: content))
        let terminal = try XCTUnwrap(region("fixture-terminal", in: content))
        XCTAssertTrue(panel.window === window)
        XCTAssertTrue(terminal.window === window)
        XCTAssertTrue(content.bounds.contains(panel.convert(panel.bounds, to: content)))
        XCTAssertTrue(terminal.convert(terminal.bounds, to: content).contains(panel.convert(panel.bounds, to: content)))
        XCTAssertEqual(terminal.bounds.size, NSSize(width: 500, height: 360))
    }

    @MainActor private final class QuestionDraftFixture: ObservableObject {
        @Published var entries: [DecisionInboxEntry]
        @Published var drafts: [String: DecisionDraft]
        init(entries: [DecisionInboxEntry], drafts: [String: DecisionDraft]) {
            self.entries = entries
            self.drafts = drafts
        }
    }

    private struct QuestionDraftFixtureView: View {
        @ObservedObject var model: QuestionDraftFixture
        var body: some View {
            DecisionInboxView(entries: model.entries, onResolve: { _, _, _, _, _ in }, onDismiss: {}, draftStore: $model.drafts)
        }
    }
}
