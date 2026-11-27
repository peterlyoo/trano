import Foundation
import XCTest
@testable import TerminalCore

final class KeyboardLayoutSearchTests: XCTestCase {
    // Implements: FR-SEARCH-1, FR-SEARCH-2
    func testRoyRequiresAContiguousSubstringInEitherKeyboardLayout() {
        XCTAssertEqual(KeyboardLayoutSearch.latinKeystrokes(for: "개ㅛ"), "roy")
        for query in ["roy", "개ㅛ", "개ㅛ".decomposedStringWithCanonicalMapping] {
            let search = KeyboardLayoutSearch(query: query)
            XCTAssertNotNil(search.match(title: "roy"))
            XCTAssertNotNil(search.match(title: "project-ROY-dev"))
            XCTAssertNil(search.match(title: "proxysql", detail: "2 tabs"))
            XCTAssertNil(search.match(title: "r-o-y"))
        }
    }

    // Implements: FR-SEARCH-1
    func testComposedCompatibilityAndCanonicalHangulProduceTheSameKeystrokes() {
        for query in ["재가리ㅐㅈ", "ㅈㅐㄱㅏㄹㅣㅐㅈ", "재가리ㅐㅈ".decomposedStringWithCanonicalMapping] {
            XCTAssertEqual(KeyboardLayoutSearch.latinKeystrokes(for: query), "workflow")
        }
        for query in ["한글", "ㅎㅏㄴㄱㅡㄹ", "한글".decomposedStringWithCanonicalMapping] {
            XCTAssertEqual(KeyboardLayoutSearch.latinKeystrokes(for: query), "gksrmf")
        }
        XCTAssertEqual(KeyboardLayoutSearch.latinKeystrokes(for: "힣"), "glg")
    }

    // Implements: FR-SEARCH-1
    func testCompoundVowelsFinalsAndShiftedKeysPreserveTheirTwoSetKeystrokes() {
        let examples = [
            ("꿰", "Rnp"), ("똠", "Eha"), ("뺨 쐐 밖 값 닭", "Qia Tho qkR rkqt ekfr"),
            ("괜찮아", "rhoscksgdk"), ("왜외워웨위의", "dhodhldnjdnpdnldml"),
            ("ㄲㄸㅃㅆㅉㅒㅖ", "REQTWOP"), ("ㄳㄵㄶㄺㄻㄼㄽㄾㄿㅀㅄ", "rtswsgfrfafqftfxfvfgqt")
        ]
        for (query, expected) in examples {
            XCTAssertEqual(KeyboardLayoutSearch.latinKeystrokes(for: query), expected, query)
            XCTAssertEqual(KeyboardLayoutSearch.latinKeystrokes(for: query.decomposedStringWithCanonicalMapping), expected, query)
        }
    }

    // Implements: FR-SEARCH-1, FR-SEARCH-2
    func testMixedASCIIWhitespacePunctuationAndUnsupportedScalarsRemainByteExact() {
        let query = "  Docs/재가리ㅐㅈ-42_A🙂\u{0301}\t\u{1113}"
        let expected = "  Docs/workflow-42_A🙂\u{0301}\t\u{1113}"
        XCTAssertEqual(KeyboardLayoutSearch.latinKeystrokes(for: query).map { Data($0.utf8) }, Data(expected.utf8))
        for literal in ["", "Workflow-42", "🙂e\u{0301}", "日本語", "\u{1113}\u{3164}"] {
            XCTAssertNil(KeyboardLayoutSearch.latinKeystrokes(for: literal))
        }
    }

    // Implements: FR-SEARCH-1, FR-SEARCH-2
    func testLiteralMatchesAlwaysOutrankAlternatesAndEachEntryHasOnlyOneRank() {
        let search = KeyboardLayoutSearch(query: "한글")
        XCTAssertEqual(search.match(title: "한글"), .literalExact)
        XCTAssertEqual(search.match(title: "prefix 한글"), .literal)
        XCTAssertEqual(search.match(title: "gksrmf"), .alternateExact)
        XCTAssertEqual(search.match(title: "prefix gksrmf"), .alternate)
        XCTAssertEqual(search.match(title: "한글 gksrmf"), .literal)
        XCTAssertEqual(search.match(title: "gksrmf", detail: "한글"), .literal)
        XCTAssertNil(search.match(title: "other", detail: "0 tabs"))
        XCTAssertLessThan(KeyboardLayoutSearch.Match.literalExact.rawValue, KeyboardLayoutSearch.Match.literal.rawValue)
        XCTAssertLessThan(KeyboardLayoutSearch.Match.literal.rawValue, KeyboardLayoutSearch.Match.alternateExact.rawValue)
        XCTAssertLessThan(KeyboardLayoutSearch.Match.alternateExact.rawValue, KeyboardLayoutSearch.Match.alternate.rawValue)
    }

    // Implements: FR-SEARCH-1, FR-SEARCH-2
    func testCaseInsensitiveAndMetadataMatchingRemainAvailable() {
        XCTAssertEqual(KeyboardLayoutSearch(query: "재가리ㅐㅈ").match(title: "WORKFLOW"), .alternateExact)
        XCTAssertEqual(KeyboardLayoutSearch(query: "ㅅㅁㅠㄴ").match(title: "Home", detail: "2 tabs"), .alternate)
        XCTAssertEqual(KeyboardLayoutSearch(query: "Closed").match(title: "Home", detail: "Closed · 2 tabs"), .literal)
        XCTAssertEqual(KeyboardLayoutSearch(query: "WORKFLOW").match(title: "workflow"), .literalExact)
        XCTAssertNil(KeyboardLayoutSearch(query: "workflow").match(title: "재가리ㅐㅈ"))
    }

    // Implements: FR-SEARCH-2
    func testEmptyQueryKeepsAllRowsInTheirOriginalTier() {
        let search = KeyboardLayoutSearch(query: "")
        for title in ["", "home", "한글", "gksrmf"] { XCTAssertEqual(search.match(title: title), .literal) }
    }

    // Implements: FR-SEARCH-2
    func testLongInputHasOneBoundedAlternateAndPreservesItsSuffix() throws {
        let input = String(repeating: "한글/", count: 8_192) + "🙂suffix"
        let expected = String(repeating: "gksrmf/", count: 8_192) + "🙂suffix"
        let result = try XCTUnwrap(KeyboardLayoutSearch.latinKeystrokes(for: input))
        XCTAssertEqual(result, expected)
        XCTAssertEqual(result.utf8.count, expected.utf8.count)
    }
}
