import SwiftTerm
import XCTest

private final class InputClassificationRecorder: TerminalDelegate {
    var user: [[UInt8]] = []
    var response: [[UInt8]] = []
    func send(source: Terminal, data: ArraySlice<UInt8>) { response.append(Array(data)) }
    func sendUserInput(source: Terminal, data: ArraySlice<UInt8>) { user.append(Array(data)) }
    func kittyClipboardCapabilities(source: Terminal) -> KittyClipboardCapabilities { .standard }
}

private final class LegacyInputRecorder: TerminalDelegate {
    var bytes: [[UInt8]] = []
    func send(source: Terminal, data: ArraySlice<UInt8>) { bytes.append(Array(data)) }
}

final class TransportClassificationTests: XCTestCase {
    // Implements: FR-QUEUE-5
    func testExistingDelegateRetainsUserInputFallbackWithoutNewImplementation() {
        let recorder = LegacyInputRecorder()
        let terminal = Terminal(delegate: recorder)
        let payload = Array("legacy\r".utf8)
        terminal.sendUserInput(payload[...])
        XCTAssertEqual(recorder.bytes, [payload])
    }

    // Implements: FR-QUEUE-5
    func testSemanticPointerCursorMovementReachesUserDelegate() {
        let recorder = InputClassificationRecorder()
        let terminal = Terminal(delegate: recorder)
        terminal.feed(text: "\u{1b}]133;A;cl=line\u{7}$ \u{1b}]133;B\u{7}hello")
        XCTAssertTrue(terminal.handleSemanticPromptClick(at: Position(col: 4, row: 0)))
        XCTAssertFalse(recorder.user.isEmpty)
        XCTAssertTrue(recorder.response.isEmpty)
    }

    // Implements: FR-QUEUE-5
    func testSemanticPointerClickEventReachesUserDelegate() {
        let recorder = InputClassificationRecorder()
        let terminal = Terminal(delegate: recorder)
        terminal.feed(text: "\u{1b}]133;A;click_events=1\u{7}$ \u{1b}]133;B\u{7}hello")
        XCTAssertTrue(terminal.handleSemanticPromptClick(at: Position(col: 4, row: 0)))
        XCTAssertEqual(recorder.user, [Array("\u{1b}[<0;5;1M".utf8)])
        XCTAssertTrue(recorder.response.isEmpty)
    }

    // Implements: FR-QUEUE-5
    func testBracketedTextPasteReachesUserDelegate() {
        let recorder = InputClassificationRecorder()
        let terminal = Terminal(delegate: recorder)
        terminal.feed(text: "\u{1b}[?2004h")
        XCTAssertEqual(terminal.paste(TerminalPasteRequest(text: "한글\nsecond")), .textSent)
        XCTAssertEqual(recorder.user, [Array("\u{1b}[200~한글\nsecond\u{1b}[201~".utf8)])
        XCTAssertTrue(recorder.response.isEmpty)
    }

    // Implements: FR-QUEUE-5
    func testKittyPasteEventReachesUserDelegate() {
        let recorder = InputClassificationRecorder()
        let terminal = Terminal(delegate: recorder, options: TerminalOptions(kittyClipboardPolicy: .all))
        terminal.feed(text: "\u{1b}[?5522h")
        let snapshot = TerminalClipboardSnapshot(location: .standard, mimeTypes: ["text/plain"], read: { _, _ in false })
        XCTAssertEqual(terminal.paste(TerminalPasteRequest(snapshot: snapshot)), .eventSent)
        XCTAssertEqual(recorder.user.count, 1)
        XCTAssertTrue(recorder.user[0].starts(with: Array("\u{1b}]5522;type=read:status=OK".utf8)))
        XCTAssertTrue(recorder.response.isEmpty)
    }

    // Implements: FR-QUEUE-5
    func testFocusReportRemainsProtocolResponse() {
        let recorder = InputClassificationRecorder()
        let terminal = Terminal(delegate: recorder)
        terminal.feed(text: "\u{1b}[?1004h")
        terminal.setTerminalFocus(false)
        XCTAssertTrue(recorder.user.isEmpty)
        XCTAssertTrue(recorder.response.contains(Array("\u{1b}[O".utf8)))
    }

    // Implements: FR-QUEUE-5
    func testUserInputReachesUserDelegateRatherThanResponseDelegate() {
        let recorder = InputClassificationRecorder()
        let terminal = Terminal(delegate: recorder)
        let payload = Array("한글 e\u{301} 👩🏽‍💻\r".utf8)
        terminal.sendUserInput(payload[...])
        XCTAssertEqual(recorder.user, [payload])
        XCTAssertTrue(recorder.response.isEmpty)
    }

    // Implements: FR-QUEUE-5
    func testProtocolRepliesDoNotReachUserDelegate() {
        let recorder = InputClassificationRecorder()
        let terminal = Terminal(delegate: recorder)
        terminal.feed(text: "\u{1b}[5n")
        XCTAssertTrue(recorder.user.isEmpty)
        XCTAssertEqual(recorder.response, [Array("\u{1b}[0n".utf8)])
    }

    // Implements: FR-QUEUE-5
    func testCoreMousePacketsReachUserDelegateRatherThanResponseDelegate() {
        let recorder = InputClassificationRecorder()
        let terminal = Terminal(delegate: recorder)
        terminal.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        XCTAssertTrue(terminal.sendHostMouse(action: .press, button: .left, modifiers: 0, col: 2, row: 1, pixelX: 2, pixelY: 1))
        XCTAssertEqual(recorder.user, [Array("\u{1b}[<0;3;2M".utf8)])
        XCTAssertTrue(recorder.response.isEmpty)
    }
}
