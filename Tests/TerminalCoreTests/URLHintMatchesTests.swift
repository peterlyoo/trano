import XCTest
@testable import TerminalCore

final class URLHintMatchesTests: XCTestCase {
    // Implements: FR-HINT-1
    func testUnicodeWideAndCombiningCellsKeepTheURLsPhysicalColumn() {
        let rowCells = [URLHintCell(text: "한", width: 2), URLHintCell(text: "", width: 0),
                     URLHintCell(text: "e\u{301}"), URLHintCell(text: " ")] + cells("https://example.test/한글?q=한")
        let matches = URLHintMatcher.matches(rows: [URLHintRow(row: 3, cells: rowCells)])
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.url, "https://example.test/한글?q=한")
        XCTAssertEqual(matches.first?.spans.first?.row, 3)
        XCTAssertEqual(matches.first?.spans.first?.columns.lowerBound, 4)
    }

    // Implements: FR-HINT-1
    func testSoftWrappedURLsJoinButHardLinesRemainSeparate() {
        let matches = URLHintMatcher.matches(rows: [
            URLHintRow(row: 0, cells: cells("https://example.")),
            URLHintRow(row: 1, cells: cells("test/path?q=1"), isWrapped: true),
            URLHintRow(row: 2, cells: cells("https://second.test")),
            URLHintRow(row: 3, cells: cells("unrelated-output"))
        ])
        XCTAssertEqual(matches.map(\.url), ["https://example.test/path?q=1", "https://second.test"])
        XCTAssertEqual(matches.first?.spans, [URLHintSpan(row: 0, columns: 0..<16), URLHintSpan(row: 1, columns: 0..<13)])
    }

    // Implements: FR-HINT-1
    func testBalancedURLPunctuationAndOnlyHTTPLinksAreAccepted() {
        let matches = URLHintMatcher.matches(rows: [URLHintRow(row: 0, cells: cells(
            "(https://example.test/a_(b)), HTTPS://second.test?q=1. javascript:alert(1) file:///private/tmp xhttps://not-a-link.test"))])
        XCTAssertEqual(matches.map(\.url), ["https://example.test/a_(b)", "HTTPS://second.test?q=1"])
    }

    // Implements: FR-HINT-1, FR-HINT-2
    func testLabelsAreDistinctAndPrefixFreeWhenThereAreMoreThan26URLs() {
        let rows = (0..<60).map { URLHintRow(row: $0, cells: cells("https://example.test/\($0)")) }
        let matches = URLHintMatcher.matches(rows: rows)
        XCTAssertEqual(matches.count, 60)
        XCTAssertEqual(Set(matches.map(\.label)).count, 60)
        for first in matches {
            XCTAssertEqual(first.label.count, 2)
            for second in matches where first.label != second.label { XCTAssertFalse(second.label.hasPrefix(first.label)) }
        }
    }

    // Implements: FR-HINT-1
    func testBoundsAndEmptyRowsDoNotCreateHints() {
        XCTAssertTrue(URLHintMatcher.matches(rows: []).isEmpty)
        let rows = (0..<300).map { URLHintRow(row: $0, cells: cells("https://example.test/\($0)")) }
        XCTAssertEqual(URLHintMatcher.matches(rows: rows).count, 256)
        XCTAssertEqual(URLHintMatcher.matches(rows: rows, maximumMatches: 2).count, 2)
        XCTAssertTrue(URLHintMatcher.matches(rows: rows, maximumMatches: 0).isEmpty)
        XCTAssertTrue(URLHintMatcher.matches(rows: [URLHintRow(row: 0, cells: cells("https://example.test/" + String(repeating: "a", count: 9000)))]).isEmpty)
    }

    func testKoreanParticlesAndEmphasisAreNotPartOfTheURL() {
        let cases = [("PR https://github.com/example/repo/pull/61에서 확인", "https://github.com/example/repo/pull/61"),
                     ("**https://github.com/a/b**", "https://github.com/a/b"),
                     ("(https://github.com/a/b)를 보세요", "https://github.com/a/b"),
                     ("https://ko.wikipedia.org/wiki/대한민국 문서", "https://ko.wikipedia.org/wiki/대한민국")]
        for (text, url) in cases {
            XCTAssertEqual(URLHintMatcher.matches(rows: [URLHintRow(row: 0, cells: cells(text))]).first?.url, url, text)
        }
    }

    private func cells(_ text: String) -> [URLHintCell] { text.map { URLHintCell(text: String($0)) } }
}
