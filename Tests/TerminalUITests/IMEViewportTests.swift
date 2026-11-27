#if os(macOS)
import AppKit
import XCTest
@testable import SwiftTerm

@MainActor
final class IMEViewportTests: XCTestCase {
    // Implements: FR-INPUT-1, FR-TRANSP-2
    func testPendingCommitSurvivesCancelAndSingleCommitPartialEcho() throws {
        let (window, view) = try component(metal: false); defer { window.close() }
        let (referenceWindow, reference) = try component(metal: false); defer { referenceWindow.close() }
        view.feed(text: "\u{1b}[2J\u{1b}[H> "); view.frameTick()
        reference.feed(text: "\u{1b}[2J\u{1b}[H> 한글"); reference.frameTick()
        let expected = try expectedCaret(reference)
        view.setMarkedText("한글", selectedRange: NSRange(location: 2, length: 0), replacementRange: .empty)
        view.insertText("한글", replacementRange: .empty)
        view.setMarkedText("ㄱ", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
        view.unmarkText()
        for echo in ["", "한", "글"] {
            if !echo.isEmpty { view.feed(text: echo) }
            view.setMarkedText("전", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
            view.frameTick()
            let overlay = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextView }.first)
            XCTAssertEqual(overlay.frame.minX + (overlay.textContainer?.exclusionPaths.first?.bounds.maxX ?? 0), expected.minX, accuracy: 0.01)
        }
    }

    func testAttributedCommitAndSynchronousEchoPreserveBytesAndDoNotDoubleAdvance() throws {
        for synchronous in [false, true] {
            let (window, view) = try component(metal: false); defer { window.close() }
            let (referenceWindow, reference) = try component(metal: false); defer { referenceWindow.close() }
            view.feed(text: "\u{1b}[2J\u{1b}[H> "); view.frameTick()
            reference.feed(text: "\u{1b}[2J\u{1b}[H> 여"); reference.frameTick()
            let bytes = Locked<[UInt8]>([])
            view.inputSender.replaceDelivery { [weak view] input in
                bytes.withLock { $0.append(contentsOf: input) }
                if synchronous { view?.feed(byteArray: input[...]) }
            }
            view.setMarkedText("여", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
            view.insertText(NSAttributedString(string: "여"), replacementRange: .empty)
            view.setMarkedText("ㅈ", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
            view.frameTick()
            XCTAssertEqual(bytes.withLock { $0 }, Array("여".utf8))
            let expected = try expectedCaret(reference)
            let overlay = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextView }.first)
            XCTAssertEqual(overlay.frame.minX + (overlay.textContainer?.exclusionPaths.first?.bounds.maxX ?? 0), expected.minX, accuracy: 0.01)
        }
    }

    func testBottomMarginPreeditStaysVisibleAndScrollsPresentationWithoutChangingBuffer() throws {
        for (metal, layer) in [(false, false), (true, false), (true, true)] {
          for alternate in [false, true] {
            let (window, view) = try component(metal: metal, layer: layer); defer { window.close() }
            let (referenceWindow, reference) = try component(metal: metal, layer: layer); defer { referenceWindow.close() }
            let dimensions = view.withTerminal { ($0.cols, $0.rows) }
            let prefix = (alternate ? "\u{1b}[?1049h" : "") + "\u{1b}[2J\u{1b}[H" + "\u{1b}[" + String(dimensions.1) + ";" + String(dimensions.0 - 1) + "H"
            view.feed(text: prefix); view.frameTick()
            reference.feed(text: prefix + "여ㅈ\u{1b}[2D"); reference.frameTick()
            let expected = try expectedCaret(reference)
            view.setMarkedText("여", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
            view.insertText("여", replacementRange: .empty)
            for echo in ["", "여"] {
                if !echo.isEmpty { view.feed(text: echo) }
                let original = view.withTerminal { $0.getBufferAsData() }
                view.setMarkedText("ㅈ", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
                view.frameTick()
                let overlay = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextView }.first)
                XCTAssertEqual(overlay.frame.minX + (overlay.textContainer?.exclusionPaths.first?.bounds.maxX ?? 0), expected.minX, accuracy: 0.01)
                XCTAssertEqual(overlay.frame.maxY, expected.maxY, accuracy: 0.01)
                XCTAssertTrue(view.bounds.contains(overlay.frame))
                XCTAssertLessThan(view.markedTextScrollOffset, 0)
                XCTAssertEqual(FrameViewState(view: view).scrollPixelOffset, view.scrollPixelOffset + view.markedTextScrollOffset)
                let cell = view.cellDimension!
                let point = NSPoint(x: cell.width * 1.5,
                    y: view.frame.height - (CGFloat(dimensions.1) - 0.5) * cell.height - view.scrollPixelOffset - view.markedTextScrollOffset)
                let screenPoint = window.convertPoint(toScreen: view.convert(point, to: nil))
                XCTAssertEqual(view.characterIndex(for: screenPoint), (dimensions.1 - 1) * dimensions.0 + 1)
                XCTAssertEqual(view.withTerminal { $0.getBufferAsData() }, original)
            }
          }
        }
    }

    func testKittyIgnoredIMEEditDoesNotDiscardEarlierCommittedText() throws {
        let (window, view) = try component(metal: false); defer { window.close() }
        let (referenceWindow, reference) = try component(metal: false); defer { referenceWindow.close() }
        view.feed(text: "\u{1b}[2J\u{1b}[H> \u{1b}[>1u"); view.frameTick()
        reference.feed(text: "\u{1b}[2J\u{1b}[H> 여"); reference.frameTick()
        view.setMarkedText("여", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
        view.insertText("여", replacementRange: .empty)
        view.setMarkedText("ㄱ", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
        view.insertText("\u{7f}", replacementRange: .empty)
        view.setMarkedText("ㅈ", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
        let overlay = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextView }.first)
        XCTAssertEqual(overlay.frame.minX + (overlay.textContainer?.exclusionPaths.first?.bounds.maxX ?? 0), try expectedCaret(reference).minX, accuracy: 0.01)
    }

    func testControlCancellationRetiresPendingTextBeforeAReplacementPrompt() throws {
        let (window, view) = try component(metal: false); defer { window.close() }
        view.feed(text: "\u{1b}[2J\u{1b}[H> "); view.frameTick()
        view.setMarkedText("한글", selectedRange: NSRange(location: 2, length: 0), replacementRange: .empty)
        view.insertText("한글", replacementRange: .empty)
        view.unmarkText()
        let cancel = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{03}", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        view.keyDown(with: cancel)
        view.feed(text: "\rNEW>"); view.frameTick()
        view.setMarkedText("ㅈ", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
        let overlay = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextView }.first)
        XCTAssertEqual(overlay.frame.minX + (overlay.textContainer?.exclusionPaths.first?.bounds.maxX ?? 0), try expectedCaret(view).minX, accuracy: 0.01)
    }

    func testEchoConsumingVirtualScrollRefreshesImmediateContextAndOffsetOnlyFrame() throws {
        let (window, view) = try component(metal: false); defer { window.close() }
        let dimensions = view.withTerminal { ($0.cols, $0.rows) }
        view.feed(text: "\u{1b}[2J\u{1b}[H\u{1b}[" + String(dimensions.1) + ";" + String(dimensions.0 - 1) + "H")
        view.setMarkedText("여", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
        view.insertText("여", replacementRange: .empty)
        view.setMarkedText("ㅈ", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
        view.frameTick()
        view.feed(text: "여ㅈ\u{1b}[2D")
        let before = FrameViewState(view: view)
        XCTAssertLessThan(before.scrollPixelOffset, 0)
        view.refreshInputMethodGeometry()
        let after = FrameViewState(view: view)
        XCTAssertEqual(before.markedTextOcclusionRects, after.markedTextOcclusionRects)
        XCTAssertEqual(after.scrollPixelOffset, 0)
        view.renderOwner.withSnapshotForDrawing(viewState: after) { _, context in
            XCTAssertEqual(context.scrollPixelOffset, 0)
        }
        let snapshot = TerminalSnapshot()
        view.withTerminal { _ = snapshot.refresh(terminal: $0, viewState: before, selection: .empty) }
        let region = view.withTerminal { snapshot.refresh(terminal: $0, viewState: after, selection: .empty) }
        XCTAssertNotNil(region)
    }

    func testPartialScrollRegionDoesNotProjectCompositionOverTheFixedFooter() throws {
        let (window, view) = try component(metal: false); defer { window.close() }
        let dimensions = view.withTerminal { ($0.cols, $0.rows) }
        let bottom = dimensions.1 - 1
        view.feed(text: "\u{1b}[2J\u{1b}[H\u{1b}[" + String(dimensions.1) + ";1HFOOTER" + "\u{1b}[2;" + String(bottom) + "r\u{1b}[" + String(bottom) + ";" + String(dimensions.0 - 1) + "H")
        view.setMarkedText("여", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
        view.insertText("여", replacementRange: .empty)
        let original = view.withTerminal { $0.getBufferAsData() }
        view.setMarkedText("ㅈ", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
        view.frameTick()
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedTextScrollOffset, 0)
        XCTAssertTrue(view.markedTextOcclusionRects.isEmpty)
        XCTAssertEqual(view.withTerminal { $0.getBufferAsData() }, original)
        view.insertText("ㅈ", replacementRange: .empty)
        view.feed(text: "여ㅈ")
        view.setMarkedText("전", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
        view.frameTick()
        XCTAssertNotNil(view.subviews.compactMap { $0 as? NSTextView }.first)
        XCTAssertEqual(view.markedTextScrollOffset, 0)
        let footer = view.withTerminal { $0.buffer.lines[$0.buffer.yBase + dimensions.1 - 1].translateToString(trimRight: true) }
        XCTAssertEqual(footer, "FOOTER")
    }

    func testFixedFooterInputBelowScrollingRegionKeepsItsHorizontalIMEAnchor() throws {
        let (window, view) = try component(metal: false); defer { window.close() }
        let (referenceWindow, reference) = try component(metal: false); defer { referenceWindow.close() }
        let rows = view.withTerminal { $0.rows }
        let prefix = "\u{1b}[2J\u{1b}[H\u{1b}[2;" + String(rows - 1) + "r\u{1b}[" + String(rows) + ";1H> "
        view.feed(text: prefix); view.frameTick()
        reference.feed(text: prefix + "여"); reference.frameTick()
        view.setMarkedText("여", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
        XCTAssertNotNil(view.subviews.compactMap { $0 as? NSTextView }.first)
        view.insertText("여", replacementRange: .empty)
        view.setMarkedText("ㅈ", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
        let overlay = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextView }.first)
        let expected = try expectedCaret(reference)
        XCTAssertEqual(overlay.frame.minX + (overlay.textContainer?.exclusionPaths.first?.bounds.maxX ?? 0), expected.minX, accuracy: 0.01)
        XCTAssertEqual(overlay.frame.maxY, expected.maxY, accuracy: 0.01)
        XCTAssertEqual(view.markedTextScrollOffset, 0)
    }

    func testNextHangulPreeditWrapsBeforeAndAfterMarginEcho() throws {
        for remaining in [1, 2] {
            let (window, view) = try component(metal: false); defer { window.close() }
            let (referenceWindow, reference) = try component(metal: false); defer { referenceWindow.close() }
            let cols = view.withTerminal { $0.cols }
            let prefix = "\u{1b}[2J\u{1b}[H\u{1b}[1;" + String(cols - remaining + 1) + "H"
            view.feed(text: prefix); view.frameTick()
            reference.feed(text: prefix + "여ㅈ\u{1b}[2D"); reference.frameTick()
            let expected = try expectedCaret(reference)
            view.setMarkedText("여", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
            view.insertText("여", replacementRange: .empty)
            for echo in ["", "여"] {
                if !echo.isEmpty { view.feed(text: echo) }
                view.setMarkedText("ㅈ", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
                view.frameTick()
                let overlay = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextView }.first)
                XCTAssertEqual(overlay.frame.minX + (overlay.textContainer?.exclusionPaths.first?.bounds.maxX ?? 0), expected.minX, accuracy: 0.01)
                XCTAssertEqual(overlay.frame.maxY, expected.maxY, accuracy: 0.01)
            }
        }
    }

    func testUnrelatedCursorMoveAndBufferSwitchRetirePendingCommit() throws {
        let (window, view) = try component(metal: false); defer { window.close() }
        for output in ["\u{1b}[3;6H", "\u{1b}[?1049h", "\u{1b}[?7l"] {
            view.setMarkedText("여", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
            view.insertText("여", replacementRange: .empty)
            view.feed(text: output); view.frameTick()
            view.setMarkedText("ㅈ", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
            let expected = try expectedCaret(view)
            let overlay = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextView }.first)
            XCTAssertEqual(overlay.frame.minX + (overlay.textContainer?.exclusionPaths.first?.bounds.maxX ?? 0), expected.minX, accuracy: 0.01)
            XCTAssertEqual(overlay.frame.maxY, expected.maxY, accuracy: 0.01)
        }
    }

    func testNextHangulPreeditStartsAfterCommittedSyllableBeforeAnyEcho() throws {
        for (metal, layer) in [(false, false), (true, false), (true, true)] {
            let (window, view) = try component(metal: metal, layer: layer); defer { window.close() }
            let (referenceWindow, reference) = try component(metal: metal, layer: layer); defer { referenceWindow.close() }
            view.feed(text: "> "); view.frameTick()
            reference.feed(text: "> 여"); reference.frameTick()
            let expected = try expectedCaret(reference)
            let originalBuffer = view.withTerminal { $0.getBufferAsData() }
            view.setMarkedText("여", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
            view.insertText("여", replacementRange: .empty)
            view.setMarkedText("ㅈ", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
            view.frameTick()
            let overlay = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextView }.first)
            let start = overlay.frame.minX + (overlay.textContainer?.exclusionPaths.first?.bounds.maxX ?? 0)
            XCTAssertEqual(start, expected.minX, accuracy: 0.01, "Next syllable must not occupy the unacknowledged committed syllable")
            XCTAssertEqual(overlay.frame.maxY, expected.maxY, accuracy: 0.01)
            XCTAssertEqual(view.withTerminal { $0.getBufferAsData() }, originalBuffer)
            let candidate = view.firstRect(forCharacterRange: .empty, actualRange: nil)
            let candidateInView = view.convert(window.convertFromScreen(candidate), from: nil)
            XCTAssertEqual(candidateInView.minX, expected.minX, accuracy: 0.01)
            XCTAssertTrue(view.markedTextOcclusionRects.allSatisfy { $0.minX >= expected.minX - 0.01 })
            if !metal { try capture(view, name: "before-echo-next-preedit") }
            view.feed(text: "여"); view.frameTick()
            if !metal { try capture(view, name: "after-echo-next-preedit") }
            let afterEcho = overlay.frame.minX + (overlay.textContainer?.exclusionPaths.first?.bounds.maxX ?? 0)
            XCTAssertEqual(afterEcho, expected.minX, accuracy: 0.01, "Echo must not advance composition twice")
        }
    }

    func testMultipleCommittedHangulSyllablesKeepNextPreeditStableAcrossPartialEcho() throws {
        let (window, view) = try component(metal: false); defer { window.close() }
        let (referenceWindow, reference) = try component(metal: false); defer { referenceWindow.close() }
        view.feed(text: "> "); view.frameTick()
        reference.feed(text: "> 여전"); reference.frameTick()
        let expected = try expectedCaret(reference)
        for syllable in ["여", "전"] {
            view.setMarkedText(syllable, selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
            view.insertText(syllable, replacementRange: .empty)
        }
        view.setMarkedText("히", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
        for echo in ["", "여", "전"] {
            if !echo.isEmpty { view.feed(text: echo) }
            view.frameTick()
            let overlay = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextView }.first)
            let start = overlay.frame.minX + (overlay.textContainer?.exclusionPaths.first?.bounds.maxX ?? 0)
            XCTAssertEqual(start, expected.minX, accuracy: 0.01, "Partial echo must preserve the full pending commit endpoint")
        }
    }

    func testImmediateCompositionDrawUsesCurrentOcclusionAndRestoresUnderlyingInkOnCancel() throws {
        let (window, view) = try component(metal: false); defer { window.close() }
        view.feed(text: "\u{1b}[2J\u{1b}[H> 여전\u{1b}[1;3H"); view.frameTick()
        let original = view.withTerminal { $0.getBufferAsData() }
        func drawingText() throws -> String {
            var result = ""
            view.renderOwner.withSnapshotForDrawing(viewState: FrameViewState(view: view)) { snapshot, context in
                guard let row = snapshot.row(atAbsolute: snapshot.yBase) else { XCTFail("Missing fixture row"); return }
                result = SnapshotTextBuilder().buildAttributedString(row: row, absoluteRow: snapshot.yBase,
                    context: context).segments.map { $0.attributedString.string }.joined()
            }
            return result
        }
        view.setMarkedText("ㅈ", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
        XCTAssertFalse(try drawingText().contains("여"), "The current composition must hide underlying ink before a frame tick")
        XCTAssertTrue(try drawingText().contains("전"), "Uncovered terminal ink must remain visible")
        view.unmarkText()
        XCTAssertTrue(try drawingText().contains("여전"), "Cancelling composition must restore underlying ink immediately")
        XCTAssertEqual(view.withTerminal { $0.getBufferAsData() }, original)
    }

    // Implements: FR-INPUT-1, FR-TRANSP-2
    func testCompositionOnlyMaskChangesScheduleACoreGraphicsRepaintWithoutTerminalOutput() throws {
        let (window, view) = try component(metal: false); defer { window.close() }
        view.feed(text: "\u{1b}[2J\u{1b}[H> 여전\u{1b}[1;3H"); view.frameTick()
        _ = view.prepareFrame(viewState: FrameViewState(view: view))
        XCTAssertNil(try XCTUnwrap(view.prepareFrame(viewState: FrameViewState(view: view))).region)
        view.setMarkedText("ㅈ", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
        XCTAssertNotNil(try XCTUnwrap(view.prepareFrame(viewState: FrameViewState(view: view))).region,
            "Changing the composition mask must repaint even when no terminal bytes arrived")
        view.unmarkText()
        XCTAssertNotNil(try XCTUnwrap(view.prepareFrame(viewState: FrameViewState(view: view))).region,
            "Removing the composition mask must repaint without requiring Space or more output")
    }

    // Implements: FR-INPUT-1, FR-TRANSP-2
    func testImmediateNativeCompositionCompositeMatchesItsNextFrame() throws {
        let (window, view) = try component(metal: false); defer { window.close() }
        realizeBacking(window)
        view.feed(text: "\u{1b}[2J\u{1b}[H> 여전\u{1b}[1;3H"); view.frameTick()
        func capture() throws -> NSBitmapImageRep {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return bitmap
        }
        view.setMarkedText("ㅈ", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
        let immediate = try capture()
        view.frameTick()
        let next = try capture()
        XCTAssertEqual(immediate.pixelsWide, next.pixelsWide)
        XCTAssertEqual(immediate.pixelsHigh, next.pixelsHigh)
        let a = try XCTUnwrap(immediate.bitmapData), b = try XCTUnwrap(next.bitmapData)
        let different = (0..<(next.bytesPerRow * next.pixelsHigh)).filter { a[$0] != b[$0] }.count
        XCTAssertEqual(different, 0, "The first composite must not retain older terminal ink beneath transparent preedit")
        try captureBitmap(immediate, name: "immediate-marked-composite")
        try captureBitmap(next, name: "next-frame-marked-composite")
    }

    // Implements: FR-INPUT-1
    func testSecondSyllableReportsItsSelectionInsideTheMarkedText() throws {
        let (window, view) = try component(metal: false); defer { window.close() }
        view.feed(text: "\u{1b}[2J\u{1b}[H> 한"); view.frameTick()
        for text in ["ㄱ", "그", "글"] {
            view.setMarkedText(text, selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
            XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 0))
            let range = NSRange(location: view.selectedRange().location - 1, length: 1)
            var actual = NSRange.empty
            XCTAssertEqual(view.attributedSubstring(forProposedRange: range, actualRange: &actual)?.string, text)
            XCTAssertEqual(actual, NSRange(location: 0, length: 1))
        }
        view.unmarkText()
        XCTAssertEqual(view.selectedRange(), NSRange(location: 4, length: 0))
    }

    // Implements: FR-INPUT-1
    func testMarkedSelectionPreservesUTF16OffsetsAndBoundsOversizedRanges() throws {
        let (window, view) = try component(metal: false); defer { window.close() }
        let cases: [(String, NSRange, NSRange)] = [
            ("한글", NSRange(location: 1, length: 1), NSRange(location: 1, length: 1)),
            ("한글", NSRange(location: 3, length: 1), NSRange(location: 3, length: 1)),
            ("😀글", NSRange(location: 2, length: 1), NSRange(location: 2, length: 1)),
            ("😀글", NSRange(location: 2, length: Int.max), NSRange(location: 2, length: 1)),
            ("한글", NSRange(location: Int.max - 1, length: Int.max), NSRange(location: 2, length: 0)),
            ("한글", .empty, .empty)
        ]
        for (text, selection, expected) in cases {
            view.setMarkedText(text, selectedRange: selection, replacementRange: .empty)
            XCTAssertEqual(view.selectedRange(), expected)
            XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: (text as NSString).length))
            XCTAssertEqual(view.attributedSubstring(forProposedRange: view.markedRange(), actualRange: nil)?.string, text)
        }
    }

    // Implements: FR-INPUT-1, FR-TRANSP-2
    func testTransparentPreeditRepaintClearsEarlierSyllableInkAtBothCaptureScales() throws {
        for scale in [1, 2] {
            let (window, view) = try component(metal: false); defer { window.close() }
            realizeBacking(window)
            view.feed(text: "\u{1b}[2J\u{1b}[H> "); view.frameTick()
            view.setMarkedText("ㄱ", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
            let overlay = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextView }.first)
            XCTAssertFalse(overlay.isOpaque)
            _ = try captureCompositionLayer(overlay, scale: scale)
            let originalLayer = try XCTUnwrap(overlay.layer)
            view.feed(text: "한"); view.frameTick()
            for text in ["그", "글"] {
                view.setMarkedText(text, selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
                view.frameTick()
                _ = try captureCompositionLayer(overlay, scale: scale)
            }
            let retained = try captureCompositionLayer(overlay, scale: scale)
            XCTAssertTrue(overlay.layer === originalLayer)
            let (referenceWindow, reference) = try component(metal: false); defer { referenceWindow.close() }
            realizeBacking(referenceWindow)
            reference.feed(text: "\u{1b}[2J\u{1b}[H> 한"); reference.frameTick()
            reference.setMarkedText("글", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
            reference.frameTick()
            let fresh = try captureCompositionLayer(XCTUnwrap(reference.subviews.compactMap { $0 as? NSTextView }.first), scale: scale)
            let a = try XCTUnwrap(retained.bitmapData), b = try XCTUnwrap(fresh.bitmapData)
            guard retained.pixelsWide == fresh.pixelsWide, retained.pixelsHigh == fresh.pixelsHigh,
                  retained.bytesPerRow == fresh.bytesPerRow else {
                XCTFail("The retained and fresh composition must have identical dimensions")
                continue
            }
            let count = fresh.bytesPerRow * fresh.pixelsHigh
            XCTAssertGreaterThan((0..<count).filter { b[$0] != 0 }.count, 20, "The reference must contain rendered text")
            let inkRows = (0..<fresh.pixelsHigh).filter { y in
                (0..<fresh.pixelsWide).contains { x in b[y * fresh.bytesPerRow + x * 4 + 3] > 32 }
            }
            XCTAssertGreaterThan(inkRows.count, 7 * scale, "The reference must contain the full glyph, not just its underline")
            let different = (0..<count).filter { a[$0] != b[$0] }.count
            try captureBitmap(retained, name: "retained-preedit-\(scale)x")
            try captureBitmap(fresh, name: "fresh-preedit-\(scale)x")
            XCTAssertEqual(different, 0, "A transparent repaint must contain only the current syllable, not the earlier ㄱ or 그")
        }
    }

    private func realizeBacking(_ window: NSWindow) {
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.animationBehavior = .none
        window.orderBack(nil)
        window.displayIfNeeded()
        CATransaction.flush()
    }

    private func compositionBitmap(_ overlay: NSTextView, scale: Int) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(overlay.bounds.width * CGFloat(scale))),
            pixelsHigh: Int(ceil(overlay.bounds.height * CGFloat(scale))),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = overlay.bounds.size
        try XCTUnwrap(bitmap.bitmapData).initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        return bitmap
    }

    private func captureCompositionLayer(_ overlay: NSTextView, scale: Int) throws -> NSBitmapImageRep {
        overlay.window?.displayIfNeeded()
        CATransaction.flush()
        overlay.displayIfNeeded()
        let layer = try XCTUnwrap(overlay.layer)
        layer.displayIfNeeded()
        let bitmap = try compositionBitmap(overlay, scale: scale)
        let context = try XCTUnwrap(CGContext(data: bitmap.bitmapData, width: bitmap.pixelsWide,
            height: bitmap.pixelsHigh, bitsPerComponent: 8, bytesPerRow: bitmap.bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(bitmap.pixelsHigh))
        context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        context.translateBy(x: -layer.bounds.minX, y: -layer.bounds.minY)
        layer.render(in: context)
        return bitmap
    }

    // Implements: FR-INPUT-1, FR-TRANSP-2
    func testParentCompositeRetainsCommittedHangulBesideTheMarkedSyllable() throws {
        let (window, view) = try component(metal: false); defer { window.close() }
        view.nativeForegroundColor = .white
        view.nativeBackgroundColor = .black
        view.feed(text: "\u{1b}[2J\u{1b}[H> 한"); view.frameTick()
        let prefixWidth = try expectedCaret(view).minX
        for scale in [1, 2] {
            func capture() throws -> NSBitmapImageRep {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                    pixelsWide: Int(view.bounds.width * CGFloat(scale)), pixelsHigh: Int(view.bounds.height * CGFloat(scale)),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                bitmap.size = view.bounds.size
                view.cacheDisplay(in: view.bounds, to: bitmap)
                return bitmap
            }
            view.unmarkText(); view.frameTick()
            let before = try capture()
            view.setMarkedText("글", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
            view.frameTick()
            let after = try capture()
            var ink = 0, changed = 0
            for y in 0..<before.pixelsHigh {
                for x in 0..<Int(prefixWidth * CGFloat(scale)) {
                    let a = try XCTUnwrap(before.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    let b = try XCTUnwrap(after.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    if a.alphaComponent > 0.05, max(a.redComponent, a.greenComponent, a.blueComponent) > 0.2 { ink += 1 }
                    if zip([a.redComponent, a.greenComponent, a.blueComponent, a.alphaComponent],
                           [b.redComponent, b.greenComponent, b.blueComponent, b.alphaComponent])
                        .contains(where: { abs($0 - $1) > 0.01 }) { changed += 1 }
                }
            }
            XCTAssertGreaterThan(ink, 20)
            XCTAssertEqual(changed, 0, "Composition must preserve the existing > 한 pixels")
            try captureBitmap(after, name: "parent-composite-\(scale)x")
        }
    }

    // Implements: FR-INPUT-1
    func testConsecutiveHangulSyllablesKeepEarlierInkAndReplaceEachPreeditPhase() async throws {
        for (metal, layer) in [(false, false), (true, false), (true, true)] {
            for delayedEcho in [false, true] {
                let (window, view) = try component(metal: metal, layer: layer)
                defer { window.close() }
                view.feed(text: "\u{1b}[2J\u{1b}[H> "); view.frameTick()
                for text in ["ㅎ", "하", "한"] {
                    view.setMarkedText(text, selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
                    view.frameTick()
                }
                view.insertText("한", replacementRange: .empty)
                if !delayedEcho { view.feed(text: "한"); view.frameTick() }
                view.setMarkedText("ㄱ", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
                view.frameTick()
                if delayedEcho { view.feed(text: "한"); view.frameTick() }
                let expected = try expectedCaret(view)
                for text in ["ㄱ", "그", "글"] {
                    view.setMarkedText(text, selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
                    view.frameTick()
                    let overlay = try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextView }.first)
                    try await waitForOverlay(overlay, at: expected)
                    XCTAssertEqual(overlay.string, text)
                    let manager = try XCTUnwrap(overlay.layoutManager)
                    let container = try XCTUnwrap(overlay.textContainer)
                    let glyphs = manager.boundingRect(forGlyphRange: manager.glyphRange(for: container), in: container)
                    let actual = view.convert(glyphs.offsetBy(dx: overlay.textContainerOrigin.x,
                                                           dy: overlay.textContainerOrigin.y), from: overlay)
                    XCTAssertGreaterThanOrEqual(actual.minX, expected.minX - 0.01)
                    let snapshot = TerminalSnapshot(), state = FrameViewState(view: view)
                    view.withTerminal { snapshot.refresh(terminal: $0, viewState: state, selection: .empty) }
                    let row = try XCTUnwrap(snapshot.row(atAbsolute: snapshot.yBase))
                    let context = SnapshotRenderContext(viewState: state, snapshot: snapshot)
                    let rendered = SnapshotTextBuilder().buildAttributedString(row: row, absoluteRow: snapshot.yBase,
                        context: context).segments.map { $0.attributedString.string }.joined()
                    XCTAssertTrue(rendered.hasPrefix("> 한"), "The first committed syllable must remain visible during \(text): \(rendered)")
                    if !metal { try capture(view, name: "two-syllable-\(delayedEcho)-\(text)") }
                }
                view.insertText("글", replacementRange: .empty)
                view.feed(text: "글 "); view.frameTick()
                XCTAssertFalse(view.hasMarkedText())
                XCTAssertTrue(view.markedTextOcclusionRects.isEmpty)
            }
        }
    }

    // Implements: FR-INPUT-1, FR-TRANSP-2
    func testPreeditHidesOnlyOverlappingInkAndRestoresItOnCommitCancelAndEmptyText() throws {
        for metal in [false, true] {
            for mode in ["5", "6", "3", "4"] {
              for end in 0..<3 {
                let (window, view) = try component(metal: metal); defer { window.close() }
                view.feed(text: "\u{1b}[2J\u{1b}[H\u{1b}#\(mode)\u{1b}[48;2;24;48;72mABCDEFGHIJKLMNOP\u{1b}[1;3H")
                view.frameTick()
                let before = view.withTerminal { $0.getBufferAsData() }
                let builder = SnapshotTextBuilder()
                func line() throws -> (NSAttributedString, PlainRow) {
                    let state = FrameViewState(view: view), snapshot = TerminalSnapshot()
                    view.withTerminal { snapshot.refresh(terminal: $0, viewState: state, selection: .empty) }
                    let row = snapshot.yBase
                    let source = try XCTUnwrap(snapshot.row(atAbsolute: row))
                    let context = SnapshotRenderContext(viewState: state, snapshot: snapshot)
                    let result = NSMutableAttributedString()
                    for segment in builder.buildAttributedString(row: source, absoluteRow: row, context: context).segments {
                        result.append(segment.attributedString)
                    }
                    return (result, try XCTUnwrap(builder.plainRow(row: source, absoluteRow: row, context: context)))
                }
                let original = try line()
                XCTAssertTrue(original.0.string.hasPrefix("ABCD"))
                    view.setMarkedText("한글", selectedRange: .empty, replacementRange: .empty)
                    view.frameTick()
                    let during = try line()
                    XCTAssertTrue(during.0.string.hasPrefix("AB "))
                    XCTAssertTrue(during.0.string.contains("KLMN"))
                    XCTAssertEqual(during.1.codes[3], 0x20)
                    XCTAssertEqual(during.1.codes[10], UInt8(ascii: "K"))
                    XCTAssertEqual(try XCTUnwrap(during.0.attribute(.backgroundColor, at: 3, effectiveRange: nil) as? NSColor),
                                   try XCTUnwrap(original.0.attribute(.backgroundColor, at: 3, effectiveRange: nil) as? NSColor))
                    XCTAssertEqual(view.withTerminal { $0.getBufferAsData() }, before)
                    switch end {
                    case 0: view.insertText("한글", replacementRange: .empty)
                    case 1: view.unmarkText()
                    default: view.setMarkedText("", selectedRange: .empty, replacementRange: .empty)
                    }
                    view.frameTick()
                    XCTAssertTrue(view.markedTextOcclusionRects.isEmpty)
                    XCTAssertEqual(try line().0, original.0)
                    XCTAssertEqual(try line().1.codes, original.1.codes)
                    XCTAssertEqual(view.withTerminal { $0.getBufferAsData() }, before)
                }
            }
        }
    }

    // Implements: FR-INPUT-1
    func testMarkedTextDoesNotRepaintTheTransparentRowPastItsGlyphs() throws {
        let (window, view) = try component(metal: false); defer { window.close() }
        view.nativeBackgroundColor = NSColor.black.withAlphaComponent(0.46)
        view.setMarkedText("한글", selectedRange: .empty, replacementRange: .empty)
        let overlay = try markedOverlay(view)
        for scale in [1, 2] {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(ceil(overlay.bounds.width * CGFloat(scale))),
                pixelsHigh: Int(ceil(overlay.bounds.height * CGFloat(scale))),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = overlay.bounds.size
            overlay.cacheDisplay(in: overlay.bounds, to: bitmap)
            try captureBitmap(bitmap, name: "composition-background-\(scale)x")
            for x in (bitmap.pixelsWide - 40 * scale)..<(bitmap.pixelsWide - 4 * scale) {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2))
                XCTAssertLessThan(color.alphaComponent, 0.01, "IME must not paint an extra background strip across the empty input row")
            }
        }
    }

    // Implements: FR-INPUT-1
    func testMarkedHangulReplacesTheOrdinaryCursorUntilCommitCancelOrEmptyPreedit() throws {
        for (metal, layer) in [(false, false), (true, false), (true, true)] {
            let (window, view) = try component(metal: metal, layer: layer)
            defer { window.close() }
            view.forcedCursorStyle = .steadyBar
            for end in 0..<3 {
                XCTAssertFalse(try renderedCursorIsHidden(view))
                let before = view.withTerminal { $0.getBufferAsData() }
                view.setMarkedText("한글", selectedRange: NSRange(location: 2, length: 0), replacementRange: .empty)
                view.frameTick()
                XCTAssertTrue(try renderedCursorIsHidden(view), "Composition must replace the cursor in both CG and Metal snapshots")
                XCTAssertTrue(view.caretView.isHidden || view.caretView.superview == nil,
                              "A native cursor must not remain beside the marked text")
                XCTAssertFalse(view.withTerminal { $0.cursorHidden }, "Composition must not change the program's cursor mode")
                XCTAssertEqual(view.withTerminal { $0.getBufferAsData() }, before)
                XCTAssertEqual(view.forcedCursorStyle?.tagName, "steadyBar")
                switch end {
                case 0: view.insertText("한글", replacementRange: .empty)
                case 1: view.unmarkText()
                default: view.setMarkedText("", selectedRange: .empty, replacementRange: .empty)
                }
                view.frameTick()
                XCTAssertFalse(view.hasMarkedText())
                XCTAssertFalse(try renderedCursorIsHidden(view))
                if !metal { XCTAssertTrue(view.caretView.superview === view) }
                XCTAssertEqual(view.forcedCursorStyle?.tagName, "steadyBar")
            }
            view.feed(text: "\u{1b}[?25l")
            view.setMarkedText("한글", selectedRange: .empty, replacementRange: .empty)
            view.unmarkText()
            XCTAssertTrue(try renderedCursorIsHidden(view), "A program-hidden cursor must stay hidden after composition")
        }
    }

    // Implements: FR-INPUT-1
    func testMarkedUnderlineFillsMissingStylesWithoutReplacingIMEClauseEmphasis() throws {
        let (window, view) = try component(metal: false); defer { window.close() }
        view.setMarkedText("한글", selectedRange: .empty, replacementRange: .empty)
        let overlay = try markedOverlay(view)
        XCTAssertEqual(overlay.textStorage?.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int,
                       NSUnderlineStyle.single.rawValue)
        XCTAssertNil(view.attributedSubstring(forProposedRange: NSRange(location: 0, length: 2), actualRange: nil)?
            .attribute(.underlineStyle, at: 0, effectiveRange: nil))
        let marked = NSMutableAttributedString(string: "한글", attributes: [.underlineStyle: 0])
        marked.addAttribute(.underlineStyle, value: NSUnderlineStyle.double.rawValue, range: NSRange(location: 1, length: 1))
        view.setMarkedText(marked, selectedRange: NSRange(location: 1, length: 1), replacementRange: .empty)
        XCTAssertEqual(overlay.textStorage?.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int,
                       NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(overlay.textStorage?.attribute(.underlineStyle, at: 1, effectiveRange: nil) as? Int,
                       NSUnderlineStyle.double.rawValue)
        XCTAssertEqual(marked.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, 0)
    }

    // Implements: FR-INPUT-1
    func testMarkedHangulPaintsAHorizontalUnderlineBelowItsGlyphsAtBothScales() throws {
        let (window, view) = try component(metal: false); defer { window.close() }
        view.nativeForegroundColor = .white
        view.nativeBackgroundColor = NSColor.black.withAlphaComponent(0.7)
        view.caretColor = .magenta
        view.forcedCursorStyle = .steadyBar
        view.updateTypography(font: NSFont.monospacedSystemFont(ofSize: 20, weight: .regular), lineSpacing: 1.2)
        view.setMarkedText(NSAttributedString(string: "한글", attributes: [
            .underlineColor: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        ]), selectedRange: NSRange(location: 2, length: 0), replacementRange: .empty)
        let overlay = try markedOverlay(view)
        for scale in [1, 2] {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(ceil(overlay.bounds.width * CGFloat(scale))),
                pixelsHigh: Int(ceil(overlay.bounds.height * CGFloat(scale))),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = overlay.bounds.size
            overlay.cacheDisplay(in: overlay.bounds, to: bitmap)
            try captureBitmap(bitmap, name: "underline-\(scale)x")
            var ink: [NSPoint] = []
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if color.greenComponent > 0.6, color.redComponent < 0.25, color.blueComponent < 0.25,
                       color.alphaComponent > 0.5 { ink.append(NSPoint(x: x, y: y)) }
                }
            }
            guard let minX = ink.map(\.x).min(), let maxX = ink.map(\.x).max(),
                  let minY = ink.map(\.y).min(), let maxY = ink.map(\.y).max() else {
                XCTFail("The marked-text overlay must paint actual underline pixels at \(scale)x")
                continue
            }
            XCTAssertGreaterThan(maxX - minX, 20 * CGFloat(scale))
            XCTAssertLessThanOrEqual(maxY - minY, 3 * CGFloat(scale))
            XCTAssertGreaterThan(minY, CGFloat(bitmap.pixelsHigh) * 0.5, "The horizontal stroke belongs below the glyphs")
        }
        try capture(view, name: "composition-underline")
    }

    private func renderedCursorIsHidden(_ view: TerminalView) throws -> Bool {
        let snapshot = TerminalSnapshot()
        view.withTerminal { _ = snapshot.refresh(terminal: $0, viewState: FrameViewState(view: view),
            selection: SnapshotSelectionState(selection: view.selection)) }
        return try XCTUnwrap(snapshot.cursor).hidden
    }

    private func captureBitmap(_ bitmap: NSBitmapImageRep, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["TRANO_IME_CAPTURE_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent(name + ".png"))
    }

    private func component(metal: Bool, layer: Bool = true) throws -> (NSWindow, TerminalView) {
        let window = NSWindow(contentRect: NSRect(x: 410, y: 230, width: 360, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = TerminalView(frame: NSRect(x: 17, y: 11, width: 320, height: 150),
                                font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                                options: TerminalOptions(cols: 24, rows: 6, scrollback: 100))
        window.contentView?.addSubview(view)
        view.feed(text: (0..<30).map { "row-\($0) 한글\r\n" }.joined() + "prompt> ")
        view.scrollTo(row: Int.max)
        view.caretViewTracksFocus = false
        if metal { try view.setUsesMetalLayerSurface(layer); try view.setUseMetal(true) }
        view.frameTick()
        return (window, view)
    }

    private func wheel(_ pixels: Int32) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                        wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0))
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    private func expectedCaret(_ view: TerminalView) throws -> NSRect {
        let snapshot = TerminalSnapshot()
        view.withTerminal {
            _ = snapshot.refresh(terminal: $0, viewState: FrameViewState(view: view),
                                 selection: SnapshotSelectionState(selection: view.selection))
        }
        let cursor = try XCTUnwrap(snapshot.cursor)
        let cell = FrameViewState(view: view).cellDimension
        let factor: CGFloat = cursor.renderMode == .single ? 1 : 2
        return NSRect(x: cell.width * factor * CGFloat(cursor.visualCol),
                      y: view.frame.height - cell.height * CGFloat(cursor.screenRow + 1) - view.scrollPixelOffset,
                      width: cell.width * factor * CGFloat(cursor.columnWidth), height: cell.height)
    }

    private func markedOverlay(_ view: TerminalView) throws -> NSTextView {
        try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextView }.first { $0.string == "한글" })
    }

    // Implements: FR-INPUT-1, FR-SET-86
    func testLateCommittedHangulEchoMovesExistingPreeditPastThePreviousSyllable() async throws {
        for (metal, layer) in [(false, false), (true, false), (true, true)] {
            let (window, view) = try component(metal: metal, layer: layer)
            defer { window.close() }
            view.setMarkedText("앞", selectedRange: NSRange(location: 1, length: 0), replacementRange: .empty)
            view.insertText("앞", replacementRange: .empty)
            view.setMarkedText("한글", selectedRange: NSRange(location: 2, length: 0), replacementRange: .empty)
            let overlay = try markedOverlay(view)
            let oldCaret = try expectedCaret(view)
            view.feed(text: "앞")
            let afterEcho = view.withTerminal { $0.getBufferAsData() }
            view.frameTick()
            let expected = try expectedCaret(view)
            try await waitForOverlay(overlay, at: expected)
            if !metal { try capture(view, name: "late-echo") }
            XCTAssertGreaterThan(expected.minX, oldCaret.minX)
            let exclusion = try XCTUnwrap(overlay.textContainer?.exclusionPaths.first)
            XCTAssertEqual(overlay.frame.minX + exclusion.bounds.maxX, expected.minX, accuracy: 0.001,
                           "The next Hangul preedit must follow the echoed syllable without another input-method event")
            XCTAssertEqual(overlay.string, "한글")
            XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 2))
            XCTAssertEqual(view.withTerminal { $0.getBufferAsData() }, afterEcho)
            if metal { XCTAssertTrue(view.caretView.isHidden) }
        }
    }

    // Implements: FR-INPUT-1, FR-SET-86
    func testTerminalRedrawReanchorsRetainedPreeditToTheNewRowWithoutChangingComposition() async throws {
        for (metal, layer) in [(false, false), (true, false), (true, true)] {
            let (window, view) = try component(metal: metal, layer: layer)
            defer { window.close() }
            view.feed(text: "\u{1b}[2;1Hprompt> "); view.frameTick()
            view.setMarkedText("한글", selectedRange: NSRange(location: 2, length: 0), replacementRange: .empty)
            let overlay = try markedOverlay(view)
            let oldTop = overlay.frame.maxY
            view.feed(text: "\r\n앞")
            view.frameTick()
            let expected = try expectedCaret(view)
            try await waitForOverlay(overlay, at: expected)
            XCTAssertLessThan(expected.maxY, oldTop)
            XCTAssertEqual(overlay.frame.maxY, expected.maxY, accuracy: 0.001)
            XCTAssertEqual(overlay.string, "한글")
            XCTAssertTrue(view.hasMarkedText())
        }
    }

    private func waitForOverlay(_ overlay: NSTextView, at caret: NSRect) async throws {
        for _ in 0..<50 {
            let x = overlay.frame.minX + (overlay.textContainer?.exclusionPaths.first?.bounds.maxX ?? 0)
            if abs(x - caret.minX) < 0.001, abs(overlay.frame.maxY - caret.maxY) < 0.001 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func capture(_ view: TerminalView, name: String) throws {
        guard let destination = ProcessInfo.processInfo.environment["TRANO_IME_CAPTURE_DIR"] else { return }
        let directory = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }

    // Implements: FR-SET-86
    func testScreenCoordinateCharacterIndexMatchesFractionalMouseHit() throws {
        let (window, view) = try component(metal: false)
        defer { window.close() }
        view.smoothScrolling = true
        view.scrollWheel(with: try wheel(3))
        let cell = FrameViewState(view: view).cellDimension
        let local = NSPoint(x: cell.width * 4 + 1, y: view.bounds.height - cell.height - 1)
        let screen = window.convertPoint(toScreen: view.convert(local, to: nil))
        let expected = view.withTerminal { terminal -> Int in
            let hit = view.calculateMouseHitLocked(at: local).grid
            return (hit.row - terminal.displayBuffer.yDisp) * terminal.cols + hit.col
        }
        XCTAssertEqual(view.characterIndex(for: screen), expected)
    }

    // Implements: FR-SET-86
    func testMarkedHangulFirstRectUsesCurrentGeometryForCGAndMetal() throws {
        for metal in [false, true] {
            let (window, view) = try component(metal: metal)
            defer { window.close() }
            view.smoothScrolling = true
            view.scrollWheel(with: try wheel(3))
            view.caretView.frame = .zero
            view.setMarkedText("한글", selectedRange: NSRange(location: 2, length: 0), replacementRange: .empty)
            let expected = try expectedCaret(view)
            let expectedScreen = window.convertToScreen(view.convert(expected, to: nil))
            var actualRange = NSRange.empty
            let actual = view.firstRect(forCharacterRange: NSRange(location: 0, length: 2), actualRange: &actualRange)
            XCTAssertEqual(actual, expectedScreen, "Input candidates must use the same cursor geometry as the visible renderer")
            XCTAssertEqual(view.caretFrame, expected)
            XCTAssertEqual(actualRange, NSRange(location: 0, length: 2))
            XCTAssertTrue(view.hasMarkedText())
            XCTAssertEqual(view.attributedSubstring(forProposedRange: NSRange(location: 0, length: 2), actualRange: nil)?.string, "한글")
            XCTAssertEqual(try markedOverlay(view).frame.maxY, expected.maxY, accuracy: 0.001)
            if metal { XCTAssertTrue(view.caretView.isHidden, "Input anchoring must not show a second native caret over Metal") }
        }
    }

    // Implements: FR-SET-86
    func testFractionalScrollMovesMarkedHangulOverlayWithoutChangingPreeditOrCells() throws {
        for metal in [false, true] {
            let (window, view) = try component(metal: metal)
            defer { window.close() }
            view.setMarkedText("한글", selectedRange: NSRange(location: 2, length: 0), replacementRange: .empty)
            let overlay = try markedOverlay(view)
            let original = overlay.frame
            let before = view.withTerminal { terminal in terminal.getBufferAsData() }
            view.smoothScrolling = true
            view.scrollWheel(with: try wheel(3))
            XCTAssertEqual(overlay.frame.origin.y, original.origin.y - 3, accuracy: 0.001)
            XCTAssertEqual(overlay.string, "한글")
            XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 2))
            XCTAssertEqual(view.withTerminal { $0.getBufferAsData() }, before)
            view.smoothScrolling = false
            XCTAssertEqual(overlay.frame, original)
        }
    }
    // Implements: FR-SET-66, FR-SET-67, FR-SET-86
    func testModeSafeTypographyReanchorsExistingMarkedTextWithoutInstallingMetalCaret() throws {
        for metal in [false, true] {
            let (window, view) = try component(metal: metal)
            defer { window.close() }
            view.feed(text: "\u{1b}[?2004h")
            view.setMarkedText("한글", selectedRange: NSRange(location: 2, length: 0), replacementRange: .empty)
            let overlay = try markedOverlay(view)
            view.updateTypography(font: NSFont.monospacedSystemFont(ofSize: 23, weight: .regular), lineSpacing: 1.4)
            let expected = try expectedCaret(view)
            XCTAssertEqual(overlay.frame.maxY, expected.maxY, accuracy: 0.001)
            XCTAssertEqual(overlay.string, "한글")
            XCTAssertTrue(view.terminalStateSnapshot().bracketedPasteMode)
            if metal { XCTAssertTrue(view.caretView.isHidden) }
        }
    }

    // Implements: FR-SET-86, FR-SET-87
    func testResizeReanchorsRetainedMarkedHangulForCGAndMetalWithoutResettingModes() throws {
        for metal in [false, true] {
            let (window, view) = try component(metal: metal)
            defer { window.close() }
            view.feed(text: "\u{1b}[?2004h")
            view.setMarkedText("한글", selectedRange: NSRange(location: 2, length: 0), replacementRange: .empty)
            let overlay = try markedOverlay(view)
            view.setFrameSize(NSSize(width: 250, height: 180))
            let expected = try expectedCaret(view)
            XCTAssertEqual(overlay.frame.maxY, expected.maxY, accuracy: 0.001)
            XCTAssertEqual(view.firstRect(forCharacterRange: NSRange(location: 0, length: 2), actualRange: nil),
                           window.convertToScreen(view.convert(expected, to: nil)))
            XCTAssertEqual(overlay.string, "한글")
            XCTAssertTrue(view.terminalStateSnapshot().bracketedPasteMode)
        }
    }

}
#endif
