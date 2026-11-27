import AppKit
@testable import SwiftTerm
import XCTest
@testable import TranoApp

@MainActor final class HangulAvailabilityNativeTests: XCTestCase {
    func testTranoNativeResponderAndKoreanCommitRemainAvailableAcrossKeyboardModes() throws {
        _ = NSApplication.shared
        for flagValue in [0, 1, 9, 31] {
            let view = TranoView(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
            view.frameDriver.invalidate()
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.contentView = view
            let captured = Bytes()
            view.setProcessInputHandler { bytes, origin, _ in
                if case .user = origin { captured.append(bytes) }
            }
            defer {
                view.setProcessInputHandler(nil)
                window.contentView = nil
                window.close()
            }
            XCTAssertTrue(window.makeFirstResponder(view))
            XCTAssertTrue(window.firstResponder === view)
            XCTAssertNotNil(view.inputContext)
            XCTAssertFalse(view.started)
            XCTAssertFalse(view.process.running)
            XCTAssertFalse(view.inputBlocked)
            view.keyDown(with: try key(window: window, code: 36, text: "\r"))
            XCTAssertEqual(captured.value, Array("\r".utf8), "Known-working transport positive control")
            captured.clear()
            if flagValue != 0 { view.feed(text: "\u{1b}[>\(flagValue)u") }
            XCTAssertEqual(view.keyboardEnhancementFlags.rawValue, flagValue)
            for commit in ["한", "글", "한글".decomposedStringWithCanonicalMapping] {
                view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                XCTAssertTrue(view.hasMarkedText())
                XCTAssertTrue(captured.value.isEmpty)
                view.insertText(commit, replacementRange: NSRange(location: NSNotFound, length: 0))
                let expected = flagValue == 31
                    ? "\u{1b}[0;;" + commit.unicodeScalars.map { String($0.value) }.joined(separator: ":") + "u"
                    : commit
                XCTAssertEqual(captured.value, Array(expected.utf8), "flags=\(flagValue), commit=\(commit)")
                XCTAssertFalse(view.hasMarkedText())
                XCTAssertTrue(window.firstResponder === view)
                captured.clear()
            }
        }
    }

    func testPrintableKeyDownReachesNativeInterpretationBeforeAndDuringPreeditAcrossKeyboardModes() throws {
        _ = NSApplication.shared
        for flagValue in [0, 1, 9, 31] {
            let view = InterpretationProbe(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
            view.frameDriver.invalidate()
            let recorder = Delegate()
            view.terminalDelegate = recorder
            if flagValue != 0 { view.feed(text: "\u{1b}[>\(flagValue)u") }
            XCTAssertEqual(view.keyboardEnhancementFlags.rawValue, flagValue)
            view.keyDown(with: try key(window: nil, code: 5, text: "g"))
            XCTAssertEqual(view.interpretations, 1)
            XCTAssertTrue(view.hasMarkedText())
            XCTAssertTrue(recorder.bytes.isEmpty)
            view.keyDown(with: try key(window: nil, code: 0, text: "k"))
            XCTAssertEqual(view.interpretations, 2)
            XCTAssertFalse(view.hasMarkedText())
            let expected = flagValue == 31 ? "\u{1b}[0;;54620u" : "한"
            XCTAssertEqual(recorder.bytes, Array(expected.utf8))
            view.terminalDelegate = nil
        }
    }

    private func key(window: NSWindow?, code: UInt16, text: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
    }

    private final class Bytes: @unchecked Sendable {
        private let storage = SwiftTerm.Locked<[UInt8]>([])
        var value: [UInt8] { storage.withLock { $0 } }
        func append(_ bytes: [UInt8]) { storage.withLock { $0.append(contentsOf: bytes) } }
        func clear() { storage.withLock { $0.removeAll() } }
    }

    @MainActor private final class InterpretationProbe: TerminalView {
        var interpretations = 0
        override func interpretKeyEvents(_ events: [NSEvent]) {
            interpretations += 1
            if interpretations == 1 {
                setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            } else {
                insertText("한", replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
    }

    @MainActor private final class Delegate: NSObject, TerminalViewDelegate {
        var bytes: [UInt8] = []
        func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes.append(contentsOf: data) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
