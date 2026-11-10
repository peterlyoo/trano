import AppKit
import SwiftTerm
import XCTest
import TerminalCore
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
    // Implements: FR-RECOVERY-2, FR-RECOVERY-3
    @MainActor func testVisiblePaneReconnectsAfterBackendRecreation() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-reconnect-" + UUID().uuidString.prefix(6))
        let runtime = try TerminalRuntime(root: root)
        let pane = try runtime.create(title: "Reconnect", cwd: root.path)
        try runtime.update { $0.layout.addTab(paneID: pane.id) }
        let store = AppStore(runtime: runtime)
        let view = TranoView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        defer { view.terminate(); try? runtime.terminate(pane.id); try? FileManager.default.removeItem(at: root) }
        store.terminalViews[pane.id] = view
        let firstDeadline = Date().addingTimeInterval(5)
        while store.sessions.isEmpty && Date() < firstDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        view.connect(store: store, id: pane.id)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: runtime.executable)
        process.arguments = ["-S", runtime.socketPath, "kill-server"]
        try process.run(); process.waitUntilExit()
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

    // Implements: FR-INPUT-1, FR-INPUT-2. Actual Trano view, tmux and PTY transport.
    @MainActor func testTranoCompositionCommitsExactUTF8ToRealPTY() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-ime-" + UUID().uuidString.prefix(6))
        let runtime = try TerminalRuntime(root: root)
        let pane = try runtime.create(title: "IME", cwd: root.path, arguments: ["-f"])
        let view = TranoView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        defer { view.terminate(); try? runtime.terminate(pane.id); try? FileManager.default.removeItem(at: root) }
        view.configure(TerminalSettings())
        XCTAssertNil(view.terminalDelegate?.clipboardRead(source: view))
        view.startProcess(executable: runtime.executable, args: try runtime.attachArguments(pane.id))
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
