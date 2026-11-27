import XCTest
@testable import TerminalCore

final class TerminalUserInputScannerTests: XCTestCase {
    // Implements: FR-QUEUE-5
    func testEnterSeparatesTrailingManualDraftRevision() {
        var scanner = TerminalUserInputScanner()
        let segments = scanner.feed(Array("prompt\rnew draft".utf8))
        XCTAssertEqual(segments.map(\.submissionCandidate), [true, false])
        XCTAssertEqual(segments.map { String(decoding: $0.bytes, as: UTF8.self) }, ["prompt\r", "new draft"])
    }
    // Implements: FR-QUEUE-5
    func testBracketedPasteNewlinesAndSplitMarkersAreNotSubmissions() {
        var scanner = TerminalUserInputScanner()
        let parts = ["\u{1b}[20", "0~line1\rline2\n\u{1b}[201", "~\r"]
        var results: [TerminalUserInputSegment] = []
        for part in parts { results += scanner.feed(Array(part.utf8)) }
        XCTAssertEqual(results.filter(\.submissionCandidate).count, 1)
        XCTAssertEqual(results.flatMap(\.bytes), Array(parts.joined().utf8))
    }
    // Implements: FR-QUEUE-5
    func testKittyUnmodifiedEnterPressIsCapturedButReleaseAndShiftAreNot() {
        var scanner = TerminalUserInputScanner()
        let parts = ["\u{1b}[13;1u", "\u{1b}[13;1:3u", "\u{1b}[13;2u", "\u{1b}[13;1:1u", "tail"]
        let result = scanner.feed(Array(parts.joined().utf8))
        XCTAssertEqual(result.filter(\.submissionCandidate).count, 2)
        XCTAssertFalse(result.last!.submissionCandidate)
        XCTAssertEqual(result.flatMap(\.bytes), Array(parts.joined().utf8))
    }
    // Implements: FR-QUEUE-5
    func testOpaqueEscapePayloadDoesNotInventSubmission() {
        var scanner = TerminalUserInputScanner()
        let bytes = Array("\u{1b}]ignored\r\u{7}draft".utf8)
        XCTAssertFalse(scanner.feed(bytes).contains(where: \.submissionCandidate))
    }
    // Implements: FR-QUEUE-5
    func testSplitUTF8IMECommitPreservesExactBytesAndRemainsDirty() {
        var scanner = TerminalUserInputScanner()
        let bytes = Array("한글 입력".utf8)
        let first = scanner.feed(Array(bytes.prefix(2)))
        let second = scanner.feed(Array(bytes.dropFirst(2)))
        XCTAssertEqual((first + second).flatMap(\.bytes), bytes)
        XCTAssertFalse((first + second).contains(where: \.submissionCandidate))
    }
    // Implements: FR-QUEUE-5
    func testExtremeAndOpaqueKittyModifiersRemainDirtyWithoutOverflow() {
        var scanner = TerminalUserInputScanner()
        let bytes = Array("\u{1b}[13;-9223372036854775808u".utf8)
        XCTAssertFalse(scanner.feed(bytes).contains(where: \.submissionCandidate))
    }
    // Implements: FR-QUEUE-5
    func testKittyReleaseAfterEnterDoesNotInventANewDraftRevision() {
        var scanner = TerminalUserInputScanner()
        let segments = scanner.feed(Array("prompt\u{1b}[13;1:1u\u{1b}[13;1:3u".utf8))
        XCTAssertEqual(segments.filter(\.mutatesInput).map(\.submissionCandidate), [true])
        XCTAssertEqual(segments.filter { !$0.mutatesInput }.count, 1)
    }

}
