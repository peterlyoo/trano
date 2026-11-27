import AppKit
import SwiftTerm
import XCTest

private final class TransportLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(LocalProcessInputOrigin, [UInt8])] = []
    private var writer: LocalProcessInputWriter?
    private var writes: [Result<Int, LocalProcessError>] = []

    func record(_ bytes: [UInt8], origin: LocalProcessInputOrigin, writer: @escaping LocalProcessInputWriter) {
        lock.lock(); defer { lock.unlock() }
        entries.append((origin, bytes))
        self.writer = writer
    }
    var values: [(LocalProcessInputOrigin, [UInt8])] {
        lock.lock(); defer { lock.unlock() }; return entries
    }
    var savedWriter: LocalProcessInputWriter? {
        lock.lock(); defer { lock.unlock() }; return writer
    }
    func complete(_ result: Result<Int, LocalProcessError>) {
        lock.lock(); defer { lock.unlock() }; writes.append(result)
    }
    var results: [Result<Int, LocalProcessError>] {
        lock.lock(); defer { lock.unlock() }; return writes
    }
}

@MainActor private final class LegacyNativeInputRecorder: TerminalViewDelegate {
    var bytes: [[UInt8]] = []
    func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes.append(Array(data)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

@MainActor private final class NativeProtocolInputRecorder: TerminalViewDelegate {
    var user: [[UInt8]] = []
    var response: [[UInt8]] = []
    func send(source: TerminalView, data: ArraySlice<UInt8>) { response.append(Array(data)) }
    func sendUserInput(source: TerminalView, data: ArraySlice<UInt8>) { user.append(Array(data)) }
    func clipboardRead(source: TerminalView) -> Data? { Data("fixture".utf8) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

final class LocalProcessTransportTests: XCTestCase {
    // Implements: FR-QUEUE-5
    @MainActor func testExistingNativeDelegateCapturesKeyboardAndTextPasteWithoutNewImplementation() async throws {
        _ = NSApplication.shared
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        let recorder = LegacyNativeInputRecorder()
        view.terminalDelegate = recorder
        view.send(txt: "keyboard")
        view.pasteText("한글 paste")
        let deadline = Date().addingTimeInterval(2)
        while recorder.bytes.count < 2 && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(recorder.bytes, [Array("keyboard".utf8), Array("한글 paste".utf8)])
    }

    // Implements: FR-QUEUE-5
    @MainActor func testOSC52ClipboardQueryReplyDoesNotBecomeUserInput() async throws {
        _ = NSApplication.shared
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        let recorder = NativeProtocolInputRecorder()
        view.terminalDelegate = recorder
        view.feed(text: "\u{1b}]52;c;?\u{7}")
        let deadline = Date().addingTimeInterval(2)
        while recorder.response.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(recorder.user.isEmpty)
        XCTAssertEqual(recorder.response, [Array("\u{1b}]52;c;Zml4dHVyZQ==\u{1b}\\".utf8)])
    }

    // Implements: FR-QUEUE-5
    @MainActor func testNativeIMEPreeditIsSilentAndCommitRemainsExactUserInput() throws {
        _ = NSApplication.shared
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        let log = TransportLog()
        view.setProcessInputHandler { bytes, origin, writer in log.record(bytes, origin: origin, writer: writer) }
        view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(log.values.isEmpty)
        XCTAssertTrue(view.hasMarkedText())
        let commit = "한글 e\u{301} 👩🏽‍💻"
        view.insertText(commit, replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(log.values.count, 1)
        guard case .user = log.values[0].0 else { return XCTFail("IME commit was a response") }
        XCTAssertEqual(log.values[0].1, Array(commit.utf8))
        XCTAssertTrue(log.results.isEmpty)
    }

    // Implements: FR-QUEUE-5
    @MainActor func testNativeUserAndParserResponseRoutesRemainDistinct() async throws {
        _ = NSApplication.shared
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        let log = TransportLog()
        view.setProcessInputHandler { bytes, origin, writer in log.record(bytes, origin: origin, writer: writer) }
        view.send(txt: "manual")
        view.feed(text: "\u{1b}[5n")
        let deadline = Date().addingTimeInterval(2)
        while log.values.count < 2 && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(log.values.count, 2)
        guard log.values.count == 2 else { return }
        guard case .user = log.values[0].0 else { return XCTFail("Keyboard input was a response") }
        guard case .response = log.values[1].0 else { return XCTFail("Parser reply was user input") }
        XCTAssertEqual(log.values.map(\.1), [Array("manual".utf8), Array("\u{1b}[0n".utf8)])
    }

    // Implements: FR-QUEUE-5
    @MainActor func testNativeMouseEventReachesUserHandler() {
        _ = NSApplication.shared
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        let log = TransportLog()
        view.setProcessInputHandler { bytes, origin, writer in log.record(bytes, origin: origin, writer: writer) }
        view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        view.sendMouseEvent(button: 0, release: false, col: 2, row: 1)
        XCTAssertEqual(log.values.count, 1)
        guard log.values.count == 1, case .user = log.values[0].0 else { return XCTFail("Mouse edit bypassed user route") }
        XCTAssertEqual(log.values[0].1, Array("\u{1b}[<0;3;2M".utf8))
    }

    // Implements: FR-QUEUE-5
    @MainActor func testDeferredWriterCompletesInactiveFailureExactlyOnceWithoutReenteringHandler() throws {
        _ = NSApplication.shared
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        let log = TransportLog()
        view.setProcessInputHandler { bytes, origin, writer in log.record(bytes, origin: origin, writer: writer) }
        view.send(txt: "held")
        XCTAssertTrue(log.results.isEmpty)
        let writer = try XCTUnwrap(log.savedWriter)
        writer(Array("held".utf8)) { log.complete($0) }
        XCTAssertEqual(log.results.count, 1)
        XCTAssertEqual(try log.results[0].getError(), .notRunning)
        XCTAssertEqual(log.values.count, 1)
    }

    // Implements: FR-QUEUE-5
    @MainActor func testClearingHandlerRestoresDirectDeliveryWithoutRetainingInterception() {
        _ = NSApplication.shared
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        let log = TransportLog()
        view.setProcessInputHandler { bytes, origin, writer in log.record(bytes, origin: origin, writer: writer) }
        view.send(txt: "intercepted")
        view.setProcessInputHandler(nil)
        view.send(txt: "direct")
        XCTAssertEqual(log.values.count, 1)
    }

    // Implements: FR-QUEUE-5
    @MainActor func testSavedWriterDoesNotRetainTerminalViewOrProcess() throws {
        _ = NSApplication.shared
        let log = TransportLog()
        weak var released: LocalProcessTerminalView?
        autoreleasepool {
            let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
            released = view
            view.setProcessInputHandler { bytes, origin, writer in log.record(bytes, origin: origin, writer: writer) }
            view.send(txt: "old")
        }
        XCTAssertNil(released)
        let writer = try XCTUnwrap(log.savedWriter)
        writer([65]) { log.complete($0) }
        XCTAssertEqual(log.results.count, 1)
        XCTAssertEqual(try log.results[0].getError(), .notRunning)
    }
}

private extension Result where Success == Int, Failure == LocalProcessError {
    func getError() throws -> LocalProcessError? {
        switch self { case .success: return nil; case .failure(let error): return error }
    }
}
