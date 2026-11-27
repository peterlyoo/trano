import AppKit
import SwiftTerm
import XCTest
@testable import TerminalCore
@testable import TranoApp

@MainActor private final class InputRecorder: NSObject, TerminalViewDelegate {
    var committed = Data()
    func send(source: TerminalView, data: ArraySlice<UInt8>) { committed.append(contentsOf: data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

final class InputTests: XCTestCase {
    // Implements: FR-DECISION-4, FR-QUEUE-4
    @MainActor func testDecisionEditingBlocksUserInputWithoutBlockingTerminalReplies() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-input-" + UUID().uuidString.prefix(6))
        let runtime = try TerminalRuntime(root: root)
        let pane = try runtime.create(title: "Input guard", cwd: root.path, arguments: ["-df"])
        let store = AppStore(runtime: runtime)
        let loaded = Date().addingTimeInterval(3)
        while store.loading && Date() < loaded { try await Task.sleep(for: .milliseconds(10)) }
        let view = TranoView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.store = store
        view.configure(TerminalSettings())
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()
        defer { view.terminate(); window.close(); try? runtime.terminate(pane.id); runtime.shutdownTestHost(); try? FileManager.default.removeItem(at: root) }
        let attach = try runtime.attachCommand(pane.id)
        view.startProcess(executable: attach.executable, args: attach.arguments, environment: runtime.testAttachEnvironment(pane.id))
        try runtime.send(pane.id, text: "stty raw -echo; printf ready > ready; cat > received", enter: true)
        let ready = root.appendingPathComponent("ready"), received = root.appendingPathComponent("received")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: ready.path) && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        let recorder = InputRecorder()
        view.terminalDelegate = recorder
        let delegate = ApplicationDelegate()
        delegate.windows[window] = store
        store.decisionPaneID = pane.id
        window.makeFirstResponder(view)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        XCTAssertTrue(delegate.handle(event))
        view.insertText("must not reach the PTY", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual((try? Data(contentsOf: received)) ?? Data(), Data())
        view.feed(text: "\u{1b}]10;?\u{7}")
        while recorder.committed.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(String(decoding: recorder.committed, as: UTF8.self).contains("rgb:"))
        store.decisionPaneID = nil
        view.insertText("한글", replacementRange: NSRange(location: NSNotFound, length: 0))
        while (try? Data(contentsOf: received)) != Data("한글".utf8) && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(try Data(contentsOf: received), Data("한글".utf8))
    }

    // Implements: FR-RECOVERY-2, FR-RECOVERY-3
    @MainActor func testVisiblePaneReconnectsAfterBackendRecreation() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-reconnect-" + UUID().uuidString.prefix(6))
        let runtime = try TerminalRuntime(root: root)
        let pane = try runtime.create(title: "Reconnect", cwd: root.path)
        try runtime.update { $0.layout.addTab(paneID: pane.id) }
        let store = AppStore(runtime: runtime)
        let view = TranoView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        defer { view.terminate(); try? runtime.terminate(pane.id); runtime.shutdownTestHost(); try? FileManager.default.removeItem(at: root) }
        store.terminalViews[pane.id] = view
        let firstDeadline = Date().addingTimeInterval(5)
        while store.sessions.isEmpty && Date() < firstDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        view.connect(store: store, id: pane.id)
        try runtime.crashTestHost()
        _ = try runtime.recoverSessions()
        store.refresh()
        let deadline = Date().addingTimeInterval(5)
        while store.sessions.first?.pid == pane.pid && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        view.synchronize(store: store, id: pane.id)
        try runtime.send(pane.id, text: "printf '\\nRESTORED_RENDERER_OK\\n'", enter: true)
        while !String(decoding: view.getBufferAsData(), as: UTF8.self).contains("RESTORED_RENDERER_OK") && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(String(decoding: view.getBufferAsData(), as: UTF8.self).contains("RESTORED_RENDERER_OK"))
    }
    // Implements: FR-INPUT-1. NSTextInputClient contract only; real OS IME remains a release gate.
    @MainActor func testKoreanPreeditDoesNotReachPTYAndCommitPreservesBytes() throws {
        _ = NSApplication.shared
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let recorder = InputRecorder()
        view.terminalDelegate = recorder
        view.optionAsMetaKey = false
        view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(recorder.committed.isEmpty)
        XCTAssertTrue(view.hasMarkedText())
        view.insertText("한글", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(recorder.committed, Data("한글".utf8))
        XCTAssertFalse(view.hasMarkedText())
        recorder.committed.removeAll()
        let decomposed = "한글".decomposedStringWithCanonicalMapping + " 👩🏽‍💻 e\u{301}"
        view.insertText(decomposed, replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(recorder.committed, Data(decomposed.utf8))
    }

    // Implements: FR-INPUT-1. Control-Option-Space switches the source while Option stays held.
    @MainActor func testOptionHeldFromInputSourceShortcutDoesNotComposeTheNextKey() throws {
        _ = NSApplication.shared
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let recorder = InputRecorder()
        view.terminalDelegate = recorder
        view.optionAsMetaKey = false
        var source = "com.apple.inputmethod.Korean.2SetKorean"
        view.currentKeyboardInputSourceID = { source }
        func flags(_ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58))
        }
        let optionP = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0,
            windowNumber: 0, context: nil, characters: "π", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35))

        view.flagsChanged(with: try flags([.control]))
        view.flagsChanged(with: try flags([.control, .option]))
        source = "com.apple.keylayout.ABC"
        view.flagsChanged(with: try flags([.option]))
        view.keyDown(with: optionP)
        XCTAssertEqual(String(decoding: recorder.committed, as: UTF8.self), "p")

        recorder.committed.removeAll()
        view.flagsChanged(with: try flags([]))
        view.flagsChanged(with: try flags([.option]))
        view.keyDown(with: optionP)
        XCTAssertEqual(String(decoding: recorder.committed, as: UTF8.self), "π")
    }

    // Implements: FR-INPUT-1, FR-INPUT-2. Actual Trano view, PTY host attach and PTY transport.
    @MainActor func testTranoCompositionCommitsExactUTF8ToRealPTY() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-ime-" + UUID().uuidString.prefix(6))
        let runtime = try TerminalRuntime(root: root)
        let pane = try runtime.create(title: "IME", cwd: root.path, arguments: ["-f"])
        let view = TranoView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        defer { view.terminate(); try? runtime.terminate(pane.id); runtime.shutdownTestHost(); try? FileManager.default.removeItem(at: root) }
        view.configure(TerminalSettings())
        XCTAssertNil(view.terminalDelegate?.clipboardRead(source: view))
        let attach = try runtime.attachCommand(pane.id)
        view.startProcess(executable: attach.executable, args: attach.arguments, environment: runtime.testAttachEnvironment(pane.id))
        try runtime.send(pane.id, text: "stty raw -echo; printf ready > ready; cat > received", enter: true)
        let ready = root.appendingPathComponent("ready"), received = root.appendingPathComponent("received")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: ready.path) && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual((try? Data(contentsOf: received)) ?? Data(), Data())
        let expected = "한글 " + "한글".decomposedStringWithCanonicalMapping + " 👩🏽‍💻 e\u{301}"
        view.insertText(expected, replacementRange: NSRange(location: NSNotFound, length: 0))
        while (try? Data(contentsOf: received)) != Data(expected.utf8) && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(try Data(contentsOf: received), Data(expected.utf8))
        XCTAssertFalse(view.hasMarkedText())
    }

    // Implements: FR-CORE-3, FR-INPUT-2
    @MainActor func testRealRendererRetainsUnicodeAndFindsTextAfterANSIOutput() throws {
        _ = NSApplication.shared
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.feed(text: "\u{1b}[38;2;133;215;193m한글 검색 👩🏽‍💻\u{1b}[0m\r\nhttps://example.com\r\n")
        let deadline = Date().addingTimeInterval(3)
        while !String(decoding: view.getBufferAsData(), as: UTF8.self).contains("한글 검색") && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(String(decoding: view.getBufferAsData(), as: UTF8.self).contains("한글 검색"))
        XCTAssertTrue(view.findNext("검색"))
        XCTAssertTrue(view.findNext("https://example.com"))
    }
}
