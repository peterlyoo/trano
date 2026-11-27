import AppKit
import XCTest
@testable import TerminalCore
@testable import SwiftTerm
@testable import TranoApp

@MainActor private final class PasteInputWindow: NSWindow {
    override var isVisible: Bool { true }
    override var isKeyWindow: Bool { true }
    var closingSheet: NSWindow?
    override var attachedSheet: NSWindow? { closingSheet }
}
@MainActor private struct FakePastePrompt: TerminalDraftPastePromptPresenting {
    let action: () -> Bool
    func confirm(_ text: String) -> String? { action() ? text : nil }
}
private final class PasteBytes: @unchecked Sendable {
    let lock = NSLock(); private var value: [UInt8] = []
    func record(_ bytes: [UInt8]) { lock.lock(); value += bytes; lock.unlock() }
    var text: String {lock.lock(); defer {lock.unlock()}; return String(decoding: value, as: UTF8.self)}
}
@MainActor final class DeferredPasteNativeTests: XCTestCase {
    // Implements: FR-INPUT-3, FR-PASTE-EDIT-2
    func testConfirmationKeyboardResponderActivatesNativePasteWithoutButtonClick() async throws {
        for (characters, code) in [("", UInt16(0)), ("\r", UInt16(36)), ("\u{3}", UInt16(76))] {
            let f = try fixture(); defer { f.cleanup() }
            let target = try XCTUnwrap(DeferredTerminalInputTarget.capture(store: f.store, paneID: f.pane.id, applicationActive: { true }))
            f.view.terminalPastePromptPresenter = NativeTerminalDraftPastePromptPresenter(runModal: { alert in
                let window = alert.window
                window.isReleasedWhenClosed = false; window.animationBehavior = .none
                window.setFrameOrigin(NSPoint(x: -12000, y: -12000))
                let key = Timer(timeInterval: 0.02, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        window.setFrameOrigin(NSPoint(x: -12000, y: -12000))
                        let preview = (alert.accessoryView as? NSScrollView)?.documentView
                        print("PASTE_MODAL key=\(code) editorFocused=\(window.firstResponder === preview) defaultPaste=\(window.defaultButtonCell === alert.buttons[1].cell) keyWindow=\(window.isKeyWindow) appKey=\(NSApp.keyWindow === window) modal=\(NSApp.modalWindow === window) active=\(NSApp.isActive) equivalent=\(alert.buttons[1].keyEquivalent.debugDescription) enabled=\(alert.buttons[1].isEnabled)")
                        let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                            modifierFlags: code == 76 ? .numericPad : [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, characters: characters,
                            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
                        if code == 0 { alert.buttons[1].performClick(nil) }
                        else {
                            let owner = window.initialFirstResponder
                            XCTAssertNotNil(owner)
                            XCTAssertTrue(window.makeFirstResponder(owner))
                            XCTAssertTrue(window.firstResponder === owner)
                            owner?.keyDown(with: event)
                        }
                    }
                }
                let watchdog = Timer(timeInterval: 1, repeats: false) { _ in
                    MainActor.assumeIsolated { if NSApp.modalWindow === window { NSApp.abortModal() } }
                }
                RunLoop.main.add(key, forMode: .modalPanel)
                RunLoop.main.add(watchdog, forMode: .modalPanel)
                defer { key.invalidate(); watchdog.invalidate(); window.close() }
                let response = alert.runModal()
                XCTAssertEqual(response, .alertSecondButtonReturn, "Opening the confirmation must leave Enter bound to Paste, key=\(code)")
                return response
            })
            XCTAssertTrue(target.insert("한글\nsecond"))
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(f.bytes.text, "\u{1b}[200~한글\nsecond\u{1b}[201~")
            XCTAssertFalse(f.view.process.running)
        }
    }
    // Implements: FR-PASTE-EDIT-1, FR-PASTE-EDIT-3
    func testNativeConfirmationPastesTheEditedPreviewInsteadOfTheOriginalClipboardText() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let target = try XCTUnwrap(DeferredTerminalInputTarget.capture(store: f.store, paneID: f.pane.id, applicationActive: {true}))
        f.view.terminalPastePromptPresenter = NativeTerminalDraftPastePromptPresenter(runModal: { alert in
            let preview = (alert.accessoryView as? NSScrollView)?.documentView as? NSTextView
            XCTAssertTrue(preview?.isEditable == true)
            XCTAssertFalse(preview?.isRichText ?? true)
            preview?.string = "수정한 입력\nsecond 👩🏽‍💻"
            self.capturePreviewIfRequested(alert)
            return .alertSecondButtonReturn
        })
        XCTAssertTrue(target.insert("한글\nsecond"))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(f.bytes.text, "\u{1b}[200~수정한 입력\nsecond 👩🏽‍💻\u{1b}[201~")
    }

    // Implements: FR-PASTE-EDIT-1, FR-PASTE-EDIT-2
    func testMarkedReturnStaysWithTheEditorAndEscapeDiscardsTheEditedPreview() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let target = try XCTUnwrap(DeferredTerminalInputTarget.capture(store: f.store, paneID: f.pane.id, applicationActive: {true}))
        f.view.terminalPastePromptPresenter = NativeTerminalDraftPastePromptPresenter(runModal: { alert in
            alert.layout()
            let window = alert.window
            window.isReleasedWhenClosed = false; window.animationBehavior = .none
            defer { window.close() }
            guard let preview = (alert.accessoryView as? NSScrollView)?.documentView as? NSTextView else {
                XCTFail("Missing preview editor"); return .abort
            }
            let probe = ConfirmationKeyProbe()
            for button in alert.buttons { button.target = probe; button.action = #selector(ConfirmationKeyProbe.activate(_:)) }
            XCTAssertTrue(window.makeFirstResponder(preview))
            preview.string = "edited "
            preview.setSelectedRange(NSRange(location: 7, length: 0))
            preview.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
                                  replacementRange: NSRange(location: NSNotFound, length: 0))
            let marked = preview.markedRange()
            let composed = preview.string
            XCTAssertTrue(preview.hasMarkedText())
            for (characters, code) in [("\r", UInt16(36)), ("\u{3}", UInt16(76))] {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: code == 76 ? .numericPad : [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
                XCTAssertFalse(window.performKeyEquivalent(with: event))
                XCTAssertNil(probe.selected)
                XCTAssertEqual(preview.markedRange(), marked)
                XCTAssertEqual(preview.string, composed)
                XCTAssertTrue(window.firstResponder === preview)
            }
            preview.unmarkText()
            let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            XCTAssertTrue(window.performKeyEquivalent(with: escape))
            XCTAssertTrue(probe.selected === alert.buttons[0])
            return .alertFirstButtonReturn
        })
        XCTAssertTrue(target.insert("한글\nsecond"))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(f.bytes.text, "")
    }

    // Implements: FR-PASTE-EDIT-3
    func testEditedPreviewOverUTF8LimitCannotBypassOriginalClipboardSizeCheck() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let target = try XCTUnwrap(DeferredTerminalInputTarget.capture(store: f.store, paneID: f.pane.id, applicationActive: {true}))
        f.view.terminalPastePromptPresenter = NativeTerminalDraftPastePromptPresenter(runModal: { alert in
            ((alert.accessoryView as? NSScrollView)?.documentView as? NSTextView)?.string = String(repeating: "한", count: 349_526)
            return .alertSecondButtonReturn
        })
        XCTAssertTrue(target.insert("한글\nsecond"))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(f.bytes.text, "")
        XCTAssertEqual(f.store.message, "Paste is limited to 1 MiB.")
    }

    // Implements: FR-PASTE-EDIT-1, FR-PASTE-EDIT-2
    func testPreviewReturnInsertsNewlineThenButtonReturnPastesTheEditedContent() async throws {
        for (characters, code, flags) in [("\r", UInt16(36), NSEvent.ModifierFlags()),
                                          ("\u{3}", UInt16(76), NSEvent.ModifierFlags.numericPad)] {
            let f = try fixture(); defer { f.cleanup() }
            let target = try XCTUnwrap(DeferredTerminalInputTarget.capture(store: f.store, paneID: f.pane.id, applicationActive: {true}))
            f.view.terminalPastePromptPresenter = NativeTerminalDraftPastePromptPresenter(runModal: { alert in
                alert.layout()
                let window = alert.window
                window.isReleasedWhenClosed = false; window.animationBehavior = .none
                defer { window.close() }
                guard let preview = (alert.accessoryView as? NSScrollView)?.documentView as? NSTextView else {
                    XCTFail("Missing preview editor"); return .abort
                }
                preview.string = "수정"
                preview.setSelectedRange(NSRange(location: 2, length: 0))
                let probe = ConfirmationKeyProbe()
                for button in alert.buttons { button.target = probe; button.action = #selector(ConfirmationKeyProbe.activate(_:)) }
                XCTAssertTrue(window.makeFirstResponder(preview))
                @MainActor func keyEvent() -> NSEvent {
                    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                        characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
                }
                let event = keyEvent()
                if !window.performKeyEquivalent(with: event) { preview.keyDown(with: event) }
                XCTAssertNil(probe.selected, "Editor Return must not activate Paste")
                XCTAssertEqual(preview.string, "수정\n")
                preview.insertText("한글", replacementRange: NSRange(location: NSNotFound, length: 0))
                probe.selected = nil
                XCTAssertTrue(window.makeFirstResponder(alert.buttons[1]))
                XCTAssertTrue(window.performKeyEquivalent(with: keyEvent()), "key=\(code)")
                XCTAssertTrue(probe.selected === alert.buttons[1], "key=\(code)")
                return .alertSecondButtonReturn
            })
            XCTAssertTrue(target.insert("한글\nsecond"))
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(f.bytes.text, "\u{1b}[200~수정\n한글\u{1b}[201~")
        }
    }

    // Implements: FR-INPUT-3
    func testNativeConfirmationReturnAndKeypadEnterPasteWithoutSubmitting() async throws {
        for (characters, code, flags) in [("\r", UInt16(36), NSEvent.ModifierFlags()),
                                          ("\u{3}", UInt16(76), NSEvent.ModifierFlags.numericPad)] {
            let f = try fixture(); defer { f.cleanup() }
            let target = try XCTUnwrap(DeferredTerminalInputTarget.capture(store: f.store, paneID: f.pane.id, applicationActive: {true}))
            f.view.terminalPastePromptPresenter = NativeTerminalDraftPastePromptPresenter(runModal: { alert in
                self.pressConfirmationKey(alert, characters: characters, keyCode: code, flags: flags)
            })
            XCTAssertTrue(target.insert("한글\nsecond"))
            XCTAssertFalse(target.insert("duplicate"))
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(f.bytes.text, "\u{1b}[200~한글\nsecond\u{1b}[201~",
                           "Confirmation Enter must paste exactly once without sending a terminal Return")
        }
    }

    // Implements: FR-INPUT-3
    func testNativeConfirmationEscapeCancelsWithoutInput() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let target = try XCTUnwrap(DeferredTerminalInputTarget.capture(store: f.store, paneID: f.pane.id, applicationActive: {true}))
        f.view.terminalPastePromptPresenter = NativeTerminalDraftPastePromptPresenter(runModal: { alert in
            self.pressConfirmationKey(alert, characters: "\u{1b}", keyCode: 53, flags: [])
        })
        XCTAssertTrue(target.insert("한글\nsecond"))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(f.bytes.text, "")
    }

    private final class ConfirmationKeyProbe: NSObject {
        var selected: NSButton?
        @objc func activate(_ sender: NSButton) { selected = sender }
    }

    private func pressConfirmationKey(_ alert: NSAlert, characters: String, keyCode: UInt16,
                                      flags: NSEvent.ModifierFlags) -> NSApplication.ModalResponse {
        alert.layout()
        let window = alert.window
        window.isReleasedWhenClosed = false; window.animationBehavior = .none
        defer { window.close() }
        let probe = ConfirmationKeyProbe()
        for button in alert.buttons { button.target = probe; button.action = #selector(ConfirmationKeyProbe.activate(_:)) }
        XCTAssertEqual(alert.buttons.map(\.title), ["Cancel", "Paste"])
        let preview = (alert.accessoryView as? NSScrollView)?.documentView as? NSTextView
        XCTAssertEqual(preview?.string, "한글\nsecond")
        XCTAssertTrue(window.initialFirstResponder === alert.accessoryView)
        XCTAssertTrue(window.initialFirstResponder?.acceptsFirstResponder == true)
        XCTAssertTrue(window.firstResponder === alert.accessoryView,
                      "Before ordering the alert, Return must remain outside the preview editor")
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else {
            XCTFail("Native confirmation key event could not be constructed"); return .abort
        }
        XCTAssertTrue(window.performKeyEquivalent(with: event), "The native alert must handle the confirmation key")
        guard let selected = probe.selected, let index = alert.buttons.firstIndex(of: selected) else {
            XCTFail("No native alert button received the key"); return .abort
        }
        return NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index)
    }

    private func capturePreviewIfRequested(_ alert: NSAlert) {
        guard let path = ProcessInfo.processInfo.environment["TRANO_PASTE_PREVIEW_CAPTURE"] else { return }
        alert.window.appearance = NSAppearance(named: .darkAqua)
        alert.layout()
        alert.window.isReleasedWhenClosed = false; alert.window.animationBehavior = .none
        defer { alert.window.close() }
        guard let content = (alert.accessoryView as? NSScrollView)?.documentView,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            XCTFail("Native paste preview cannot be captured"); return
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("Native paste preview capture is empty"); return
        }
        do { try data.write(to: URL(fileURLWithPath: path)) }
        catch { XCTFail("Native paste preview capture failed: \(error)") }
    }

    func testOriginalDeferredTargetIsRecheckedAfterFakeModalChangesItsProvider() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let launch = AgentLaunch(paneID: f.pane.id, provider: .codex, cwd: f.root.path, accountID: nil,
            configurationRoot: f.root.path, bootID: "fixture", processID: nil, providerPID: 70)
        f.store.state.agentLaunches = [launch]
        let target = try XCTUnwrap(DeferredTerminalInputTarget.capture(store: f.store, paneID: f.pane.id, applicationActive: {true}))
        var confirmations = 0
        f.view.terminalPastePromptPresenter = FakePastePrompt {
            confirmations += 1
            var changed = launch; changed.id = UUID().uuidString; changed.providerPID = 71
            f.store.state.agentLaunches = [changed]
            return true
        }
        XCTAssertTrue(target.insert("old\nvoice"))
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(confirmations, 1); XCTAssertEqual(f.bytes.text, "")
    }
    func testFakeModalCannotPasteAfterLeaseInvalidationOrFocusMovesToAnEditor() async throws {
        for changeLease in [true, false] {
            let f = try fixture(); defer { f.cleanup() }
            let target = try XCTUnwrap(DeferredTerminalInputTarget.capture(store: f.store, paneID: f.pane.id, applicationActive: {true}))
            let editor = NSTextView()
            f.view.terminalPastePromptPresenter = FakePastePrompt {
                if changeLease { target.attempt.lease.invalidate() }
                else { XCTAssertTrue(f.window.makeFirstResponder(editor)) }
                return true
            }
            XCTAssertTrue(target.insert("old\nvoice"))
            try? await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(f.bytes.text, "")
        }
    }
    func testOrdinaryPasteCannotBypassFailedNativeOwnerCapture() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let editor = NSTextView(); XCTAssertTrue(f.window.makeFirstResponder(editor))
        f.view.terminalPastePromptPresenter = FakePastePrompt {XCTFail("Protected paste prompted"); return true}
        f.view.pasteDraft("old\nclipboard")
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(f.bytes.text, "")
    }
    func testUnchangedDeferredOwnerPastesMultilineOnceThroughUserInputTransport() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let target = try XCTUnwrap(DeferredTerminalInputTarget.capture(store: f.store, paneID: f.pane.id, applicationActive: {true}))
        f.view.terminalPastePromptPresenter = FakePastePrompt {true}
        XCTAssertTrue(target.insert("한글\nvoice")); XCTAssertFalse(target.insert("duplicate"))
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(f.bytes.text, "\u{1b}[200~한글\nvoice\u{1b}[201~")
    }
    func testDetachedSheetResponderGapRetainsVoiceUntilNextExplicitOpen() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let target = try XCTUnwrap(DeferredTerminalInputTarget.capture(store: f.store, paneID: f.pane.id, applicationActive: {true}))
        let id = UUID(); f.store.voiceInputPresentationID = id
        XCTAssertTrue(f.window.makeFirstResponder(nil))
        target.completeVoice("복원할 음성", presentationID: id, closingSheet: nil)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(target.attempt.consumed); XCTAssertEqual(f.bytes.text, "")
        XCTAssertFalse(f.store.showVoice)
        f.store.showVoice = true
        XCTAssertEqual(f.store.voiceInputInitialDraft, "복원할 음성")
        XCTAssertNotEqual(f.store.voiceInputPresentationID, id)
    }
    func testOwnClosingSheetTimeoutRetainsRecoveryWithoutForcingFocusOrSending() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let target = try XCTUnwrap(DeferredTerminalInputTarget.capture(store: f.store, paneID: f.pane.id, applicationActive: {true}))
        let sheet = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false; defer {sheet.close()}
        let id = UUID(); f.store.voiceInputPresentationID = id; f.window.closingSheet = sheet
        target.completeVoice("timeout draft", presentationID: id, closingSheet: sheet)
        try? await Task.sleep(for: .milliseconds(2100))
        XCTAssertFalse(target.attempt.consumed); XCTAssertEqual(f.bytes.text, "")
        XCTAssertTrue(f.window.firstResponder === f.view)
        f.window.closingSheet = nil; f.store.showVoice = true
        XCTAssertEqual(f.store.voiceInputInitialDraft, "timeout draft")
    }
    func testNewVoicePresentationDuringFakePasteModalCancelsOldInputWithoutClearingNewDraft() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let target = try XCTUnwrap(DeferredTerminalInputTarget.capture(store: f.store, paneID: f.pane.id, applicationActive: {true}))
        let old = UUID(); f.store.voiceInputPresentationID = old
        var newer: UUID?
        f.view.terminalPastePromptPresenter = FakePastePrompt {
            f.store.showVoice = true; newer = f.store.voiceInputPresentationID
            XCTAssertTrue(f.store.voiceInputRecovery.remember("new draft", presentationID: newer!, currentID: newer))
            f.store.showVoice = false
            return true
        }
        target.completeVoice("old\nvoice", presentationID: old, closingSheet: nil)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(f.bytes.text, ""); XCTAssertNotNil(newer)
        XCTAssertEqual(f.store.voiceInputPresentationID, newer)
        XCTAssertEqual(f.store.voiceInputRecovery.reviewOnNextOpen(currentID: newer), "new draft")
    }
    func testSuccessfulVoiceAdmissionClearsItsRecoveryBeforeTheNextExplicitOpen() async throws {
        let f = try fixture(); defer { f.cleanup() }
        let target = try XCTUnwrap(DeferredTerminalInputTarget.capture(store: f.store, paneID: f.pane.id, applicationActive: {true}))
        let id = UUID(); f.store.voiceInputPresentationID = id
        f.view.terminalPastePromptPresenter = FakePastePrompt {true}
        target.completeVoice("복원하지 않을\n완료 입력", presentationID: id, closingSheet: nil)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(target.attempt.consumed)
        XCTAssertEqual(f.bytes.text, "\u{1b}[200~복원하지 않을\n완료 입력\u{1b}[201~")
        f.store.showVoice = true
        XCTAssertEqual(f.store.voiceInputInitialDraft, "")
    }
    func testRepeatedVoiceAppearanceCannotReplaceAnEditedRecoveryDraft() {
        let voice = VoiceInput(authorizeSpeech: {_ in XCTFail("No speech authorization")}, authorizeMicrophone: {_ in XCTFail("No microphone")})
        let id = UUID()
        if voice.bind(to: id) {voice.setDraft("recovered draft", for: id)}
        voice.setDraft("user edited draft", for: id)
        if voice.bind(to: id) {voice.setDraft("old recovered draft", for: id)}
        XCTAssertEqual(voice.text, "user edited draft")
    }
    @MainActor private struct Fixture {
        let root: URL; let store: AppStore; let pane: TerminalSession; let view: TranoView
        let window: PasteInputWindow; let bytes: PasteBytes
        func cleanup() {view.invalidateTerminalInteractions(); view.frameDriver.invalidate(); window.contentView = nil; window.close(); try? FileManager.default.removeItem(at: root)}
    }
    private func fixture() throws -> Fixture {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("t-v-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        let pane = TerminalSession(id: UUID().uuidString.lowercased(), title: "Fixture", cwd: root.path, pid: 4711)
        try runtime.update {$0.sessions = [pane]}
        let binding = SupervisorBinding(paneID: pane.id, backendPID: pane.pid, configuration: SupervisorConfiguration(provider: .claude, cwd: root.path))
        let store = AppStore(runtime: runtime, externalBinding: binding); store.sessions = [pane]; store.state.sessions = [pane]; store.loading = false
        let view = TranoView(frame: NSRect(x: 0, y: 0, width: 320, height: 160)); view.frameDriver.invalidate()
        store.terminalViews[pane.id] = view; view.store = store; view.paneID = pane.id
        let window = PasteInputWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        XCTAssertTrue(window.makeFirstResponder(view))
        view.feed(text: "\u{1b}[?2004h"); XCTAssertTrue(view.terminalInputStateSnapshot()?.bracketedPasteMode == true)
        let bytes = PasteBytes()
        view.setProcessInputHandler {data, origin, _ in if case .user = origin {bytes.record(data)}}
        return Fixture(root: root, store: store, pane: pane, view: view, window: window, bytes: bytes)
    }
}
