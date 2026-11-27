import AppKit
import SwiftUI
import SwiftTerm
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class URLHintsTests: XCTestCase {
    // Implements: FR-HINT-2, FR-INPUT-1
    @MainActor func testCompositionStartingDuringHintsPassesInputThroughWithoutOpeningAURL() async throws {
        let f = try await fixture(text: "https://example.test")
        defer { f.window.close() }
        let hints = f.view.urlHints
        var opened = 0
        hints.openURL = { _ in opened += 1 }
        XCTAssertTrue(hints.start())
        f.view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let range = f.view.markedRange()
        let content = f.view.terminalContentSnapshot(region: .viewport)
        XCTAssertFalse(hints.handle(try key("a", code: 0, in: f.window)))
        XCTAssertFalse(hints.isActive)
        XCTAssertNil(hints.overlay)
        XCTAssertTrue(f.view.hasMarkedText())
        XCTAssertEqual(f.view.markedRange(), range)
        XCTAssertEqual(f.view.terminalContentSnapshot(region: .viewport), content)
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(f.sent.bytes, [])
        f.view.unmarkText()
    }

    // Implements: FR-HINT-1, FR-HINT-2, FR-NAV-2
    @MainActor func testAppDelegateRoutesDefaultAndCustomizedHintKeysInTheOwningWindow() async throws {
        for custom in [false, true] {
            _ = NSApplication.shared
            let root = URL(fileURLWithPath: "/tmp/trano-url-key-" + UUID().uuidString)
            let runtime = try TerminalRuntime(root: root)
            let pane = try runtime.create(title: "Hints", cwd: root.path, shell: "/usr/bin/env", arguments: [
                "HOME=" + root.path, "ZDOTDIR=" + root.path, "CODEX_HOME=" + root.appendingPathComponent("codex").path,
                "CLAUDE_CONFIG_DIR=" + root.appendingPathComponent("claude").path, "/bin/zsh", "-df"
            ])
            try runtime.update { state in
                state.settings.automaticRestore = false
                if custom { state.settings.keyBindings["terminal.url_hints"] = ["ctrl+shift+y"] }
                state.layout.addWorkspace(title: "Hints")
                state.layout.addTab(paneID: pane.id)
            }
            let store = AppStore(runtime: runtime, recoverOnStartup: false)
            let window = WorkspaceWindow.make(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                contentView: NSHostingView(rootView: WorkspaceView(store: store)))
            window.setFrameOrigin(NSPoint(x: -14000, y: -14000))
            window.orderFrontRegardless()
            let delegate = ApplicationDelegate()
            delegate.window = window; delegate.store = store; delegate.windows[window] = store
            delegate.observeSettings(store, window: window)
            defer {
                window.close()
                for view in store.terminalViews.values { view.terminate() }
                try? runtime.terminate(pane.id)
                runtime.shutdownTestHost()
                try? FileManager.default.removeItem(at: root)
            }
            try await wait {
                window.contentView?.layoutSubtreeIfNeeded()
                return !store.loading && store.terminalViews[pane.id]?.process.running == true
            }
            let view = try XCTUnwrap(store.terminalViews[pane.id])
            let recorder = CaptureDelegate()
            recorder.forward = view.terminalDelegate
            view.terminalDelegate = recorder
            try runtime.send(pane.id, text: "printf '\\033[2J\\033[Hhttps://example.test/native-key\\n'; sleep 90", enter: true)
            try await wait { view.terminalContentSnapshot(region: .viewport)?.rows.first?.text.hasPrefix("https://example.test/native-key") == true }
            view.feed(text: "\u{1b}[?1004l")
            try await wait { view.terminalInputStateSnapshot()?.focusReportingEnabled == false }
            let hints = view.urlHints
            var opened: [URL] = []
            hints.openURL = { opened.append($0) }
            let frame = view.frame
            let clientPID = view.process.shellPid
            let bytes = recorder.bytes
            let trigger = try key(custom ? "y" : "e", code: custom ? 16 : 14,
                flags: [.control, .shift], in: window)
            if custom { XCTAssertFalse(delegate.handle(try key("e", code: 14, flags: [.control, .shift], in: window))) }
            XCTAssertTrue(delegate.handle(trigger))
            XCTAssertTrue(hints.isActive)
            guard hints.isActive else { continue }
            XCTAssertTrue(delegate.handle(try key(custom ? "y" : "e", code: custom ? 16 : 14,
                flags: [.control, .shift], repeating: true, in: window)))
            XCTAssertTrue(hints.isActive, "Holding the hint shortcut must not toggle the mode repeatedly")
            if !hints.isActive { XCTAssertTrue(delegate.handle(trigger)) }
            guard hints.isActive else { continue }
            let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            defer { other.close() }
            XCTAssertFalse(delegate.handle(try key(hints.matches[0].label, code: 0, in: other)))
            XCTAssertTrue(hints.isActive)
            XCTAssertTrue(delegate.handle(try key("\u{1b}", code: 53, in: window)))
            XCTAssertFalse(hints.isActive)
            XCTAssertTrue(delegate.handle(trigger))
            XCTAssertTrue(hints.isActive)
            let label = try XCTUnwrap(hints.matches.first?.label)
            for character in label { XCTAssertTrue(delegate.handle(try key(String(character), code: 0, in: window))) }
            XCTAssertEqual(opened.map(\.absoluteString), ["https://example.test/native-key"])
            XCTAssertFalse(hints.isActive)
            XCTAssertTrue(delegate.handle(try key(custom ? "y" : "e", code: custom ? 16 : 14,
                flags: [.control, .shift], repeating: true, in: window)))
            XCTAssertFalse(hints.isActive, "An autorepeat must not reopen an already dismissed mode")
            XCTAssertEqual(view.frame, frame)
            XCTAssertEqual(view.process.shellPid, clientPID)
            XCTAssertEqual(recorder.bytes, bytes)
            XCTAssertEqual(try runtime.list().first?.pid, pane.pid)
            XCTAssertTrue(try runtime.list().first?.alive == true)
        }
    }

    // Implements: FR-HINT-2, FR-INPUT-1
    @MainActor func testHintLettersCanUsePhysicalKeysWithKoreanCharacters() async throws {
        let f = try await fixture(text: "https://example.test")
        defer { f.window.close() }
        let hints = f.view.urlHints
        var opened: [URL] = []
        hints.openURL = { opened.append($0) }
        XCTAssertTrue(hints.start())
        XCTAssertEqual(hints.matches.first?.label, "a")
        XCTAssertTrue(hints.handle(try key("ㅁ", code: 0, in: f.window)))
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.test"])
        XCTAssertFalse(f.view.hasMarkedText())
        XCTAssertEqual(f.sent.bytes, [])
    }

    // Implements: FR-HINT-1, FR-HINT-2
    @MainActor func testClampedLabelCanBeClickedBeforeAWrappedURLsFirstCell() async throws {
        let f = try await fixture(text: "https://seed.test")
        defer { f.window.close() }
        let columns = f.view.terminalDimensions.cols
        f.view.feed(text: "\u{1b}[2J\u{1b}[H" + String(repeating: " ", count: columns - 1) + "https://example.test/wrapped")
        try await wait { f.view.terminalContentSnapshot(region: .viewport)?.rows.contains(where: \.isWrapped) == true }
        let hints = f.view.urlHints
        var opened: [URL] = []
        hints.openURL = { opened.append($0) }
        XCTAssertTrue(hints.start())
        guard hints.isActive else { return }
        let match = try XCTUnwrap(hints.matches.first)
        XCTAssertGreaterThan(match.spans.count, 1)
        let button = try XCTUnwrap(hints.overlay?.subviews.compactMap { $0 as? NSButton }.first)
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: f.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        XCTAssertTrue(hints.handle(event))
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.test/wrapped"])
        XCTAssertFalse(hints.isActive)
        XCTAssertEqual(f.sent.bytes, [])
    }

    // Implements: FR-HINT-2
    @MainActor func testHiddenRetainedRendererCannotPresentOrKeepHints() async throws {
        let f = try await fixture(text: "https://example.test")
        defer { f.window.close() }
        let hints = f.view.urlHints
        f.view.isHidden = true
        XCTAssertFalse(hints.start())
        f.view.isHidden = false
        XCTAssertTrue(hints.start())
        f.view.isHidden = true
        hints.refreshValidity()
        XCTAssertFalse(hints.isActive)
        XCTAssertNil(hints.overlay)
    }

    // Implements: FR-HINT-1
    @MainActor func testNativeHintsUseVisibleCellPositionsWithoutChangingTheTerminal() async throws {
        let f = try await fixture(text: "한글 https://first.test/path\r\nhttps://second.test/path")
        defer { f.window.close() }
        let before = try XCTUnwrap(f.view.terminalContentSnapshot(region: .viewport))
        let frame = f.view.frame
        let hints = f.view.urlHints
        XCTAssertTrue(hints.start())
        guard hints.isActive else { return }
        XCTAssertEqual(hints.matches.map(\.url), ["https://first.test/path", "https://second.test/path"])
        XCTAssertEqual(hints.matches.first?.spans.first?.columns.lowerBound, 5)
        let overlay = try XCTUnwrap(hints.overlay)
        XCTAssertTrue(overlay.window === f.window)
        XCTAssertEqual(overlay.frame, f.view.bounds)
        let labels = overlay.subviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(labels.count, 2)
        for label in labels { XCTAssertTrue(overlay.bounds.contains(label.frame)) }
        let cellWidth = f.view.caretFrame.minX / CGFloat(before.cursorColumn)
        XCTAssertEqual(labels[0].frame.minX, 5 * cellWidth, accuracy: 1)
        XCTAssertEqual(f.view.frame, frame)
        XCTAssertEqual(f.view.terminalContentSnapshot(region: .viewport), before)
        if let path = ProcessInfo.processInfo.environment["TRANO_URL_HINTS_PREVIEW"] {
            for scale in [1, 2] {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(f.view.bounds.width) * scale,
                    pixelsHigh: Int(f.view.bounds.height) * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                bitmap.size = f.view.bounds.size
                f.view.cacheDisplay(in: f.view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path + "-\(scale)x.png"))
            }
        }
        hints.dismiss()
        XCTAssertNil(hints.overlay)
        XCTAssertEqual(f.view.frame, frame)
    }

    // Implements: FR-HINT-2
    @MainActor func testTypingChoosesExactURLAndEscapeOutsideClickAndBackspaceStayLocal() async throws {
        let text = (0..<30).map { "https://example.test/\($0)" }.joined(separator: "\r\n")
        let f = try await fixture(text: text, height: 700)
        defer { f.window.close() }
        let hints = f.view.urlHints
        var opened: [URL] = []
        hints.openURL = { opened.append($0) }
        XCTAssertTrue(hints.start())
        guard hints.isActive else { return }
        let target = try XCTUnwrap(hints.matches.first)
        XCTAssertEqual(target.label.count, 2)
        XCTAssertTrue(hints.handle(try key(String(target.label.prefix(1)), code: 0, in: f.window)))
        XCTAssertEqual(hints.prefix, String(target.label.prefix(1)))
        XCTAssertTrue(hints.handle(try key("\u{7f}", code: 51, in: f.window)))
        XCTAssertEqual(hints.prefix, "")
        for character in target.label { XCTAssertTrue(hints.handle(try key(String(character), code: 0, in: f.window))) }
        XCTAssertEqual(opened.map(\.absoluteString), [target.url])
        XCTAssertFalse(hints.isActive)
        XCTAssertTrue(hints.start())
        XCTAssertTrue(hints.handle(try key("\u{1b}", code: 53, in: f.window)))
        XCTAssertFalse(hints.isActive)
        XCTAssertTrue(hints.start())
        let outside = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 620, y: 12), modifierFlags: [], timestamp: 0, windowNumber: f.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        XCTAssertTrue(hints.handle(outside))
        XCTAssertFalse(hints.isActive)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(f.sent.bytes, [])
    }

    // Implements: FR-HINT-2, FR-INPUT-1
    @MainActor func testCompositionAndChangedOutputOrGeometryCannotOpenStaleURLs() async throws {
        let f = try await fixture(text: "https://example.test/original")
        defer { f.window.close() }
        let hints = f.view.urlHints
        var opened = 0
        hints.openURL = { _ in opened += 1 }
        f.view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(hints.start())
        XCTAssertTrue(f.view.hasMarkedText())
        f.view.unmarkText()
        XCTAssertTrue(hints.start())
        let label = try XCTUnwrap(hints.matches.first?.label)
        f.view.feed(text: "\u{1b}[2J\u{1b}[Hhttps://changed.test")
        try await wait { f.view.terminalContentSnapshot(region: .viewport)?.rows.first?.text.hasPrefix("https://changed.test") == true }
        XCTAssertTrue(hints.handle(try key(label, code: 0, in: f.window)))
        XCTAssertFalse(hints.isActive)
        XCTAssertEqual(opened, 0)
        XCTAssertTrue(hints.start())
        f.view.setFrameSize(NSSize(width: 600, height: 200))
        hints.refreshValidity()
        XCTAssertFalse(hints.isActive)
        XCTAssertEqual(f.sent.bytes, [])
    }

    private struct Fixture {
        let view: TranoView
        let window: NSWindow
        let sent: CaptureDelegate
    }

    @MainActor private func fixture(text: String, height: CGFloat = 240) async throws -> Fixture {
        _ = NSApplication.shared
        let view = TranoView(frame: NSRect(x: 0, y: 0, width: 640, height: height))
        view.configure(TerminalSettings())
        view.suspendsRenderingWhenNotVisible = false
        let sent = CaptureDelegate()
        view.terminalDelegate = sent
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -14000, y: -14000))
        window.orderFrontRegardless()
        view.feed(text: "\u{1b}[2J\u{1b}[H" + text)
        try await wait { view.terminalContentSnapshot(region: .viewport)?.rows.first?.text.contains("https://") == true }
        try await Task.sleep(for: .milliseconds(60))
        return Fixture(view: view, window: window, sent: sent)
    }

    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate())
    }

    @MainActor private func key(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = [], repeating: Bool = false, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: repeating, keyCode: code))
    }

    @MainActor private final class CaptureDelegate: TerminalViewDelegate {
        var bytes: [UInt8] = []
        var forward: TerminalViewDelegate?
        func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes += data; forward?.send(source: source, data: data) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { forward?.sizeChanged(source: source, newCols: newCols, newRows: newRows) }
        func setTerminalTitle(source: TerminalView, title: String) { forward?.setTerminalTitle(source: source, title: title) }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { forward?.hostCurrentDirectoryUpdate(source: source, directory: directory) }
        func scrolled(source: TerminalView, position: Double) { forward?.scrolled(source: source, position: position) }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) { forward?.rangeChanged(source: source, startY: startY, endY: endY) }
    }
}
