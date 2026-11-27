import XCTest
@testable import TerminalCore

final class HexColorMatchesTests: XCTestCase {
    private func cells(_ text: String) -> [URLHintCell] {
        text.flatMap { character -> [URLHintCell] in
            let wide = character.unicodeScalars.first.map { (0xAC00...0xD7A3).contains($0.value) } == true
            return wide ? [URLHintCell(text: String(character), width: 2), URLHintCell(text: "", width: 0)] : [URLHintCell(text: String(character))]
        }
    }

    func testSixDigitColorUnderThePointerIsParsed() throws {
        let row = cells("color: #2da44e;")
        let match = try XCTUnwrap(HexColorMatcher.match(cells: row, column: 9))
        XCTAssertEqual(match.text, "#2da44e")
        XCTAssertEqual(match.columns, 7..<14)
        XCTAssertEqual(match.red, 0x2d / 255, accuracy: 0.0001)
        XCTAssertEqual(match.green, 0xa4 / 255, accuracy: 0.0001)
        XCTAssertEqual(match.blue, 0x4e / 255, accuracy: 0.0001)
        XCTAssertEqual(match.alpha, 1)
        XCTAssertNil(HexColorMatcher.match(cells: row, column: 2), "pointer outside the token")
    }

    func testShortAndAlphaFormsExpand() throws {
        let short = try XCTUnwrap(HexColorMatcher.match(cells: cells("#fa0"), column: 1))
        XCTAssertEqual(short.red, 1); XCTAssertEqual(short.green, 0xaa / 255, accuracy: 0.0001); XCTAssertEqual(short.blue, 0)
        let alpha = try XCTUnwrap(HexColorMatcher.match(cells: cells("#11223380"), column: 4))
        XCTAssertEqual(alpha.alpha, 0x80 / 255, accuracy: 0.0001)
    }

    func testIssueNumbersAnchorsAndLongerHexAreNotColors() {
        XCTAssertNil(HexColorMatcher.match(cells: cells("PR #204 merged"), column: 4))
        XCTAssertNil(HexColorMatcher.match(cells: cells("#1234"), column: 2))
        XCTAssertNil(HexColorMatcher.match(cells: cells("commit #2da44e9f1"), column: 9), "nine hex digits is a hash, not a color")
        XCTAssertNil(HexColorMatcher.match(cells: cells("page.html#abcdef"), column: 11), "URL fragment")
        XCTAssertNil(HexColorMatcher.match(cells: cells("&#123456;"), column: 3), "HTML entity")
    }

    func testWideCellsKeepPhysicalColumns() throws {
        let match = try XCTUnwrap(HexColorMatcher.match(cells: cells("색상 #2da44e"), column: 6))
        XCTAssertEqual(match.columns, 5..<12)
    }
}
