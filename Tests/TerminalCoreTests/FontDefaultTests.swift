import XCTest
@testable import TerminalCore

final class FontDefaultTests: XCTestCase {
    // Implements: U05, U21
    func testNewAndMissingFontPreferencesUseMenlo() throws {
        XCTAssertEqual(TerminalSettings().fontName, "Menlo-Regular")
        XCTAssertEqual(try JSONDecoder().decode(TerminalSettings.self, from: Data("{}".utf8)).fontName, "Menlo-Regular")
        XCTAssertEqual(TerminalSettings().fontSize, 14)
    }

    // Implements: U05, U21
    func testLegacyDefaultTypefaceMigratesWithoutChangingSize() throws {
        let settings = try JSONDecoder().decode(TerminalSettings.self, from: Data(#"{"fontName":"SFMono-Regular","fontSize":18}"#.utf8))
        XCTAssertEqual(settings.fontName, "Menlo-Regular")
        XCTAssertEqual(settings.fontSize, 18)
        let roundTrip = try JSONDecoder().decode(TerminalSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(roundTrip.fontName, "Menlo-Regular")
    }

    // Implements: U05, U21
    func testCustomFontPreferencesSurviveDecodingAndRoundTrip() throws {
        let settings = try JSONDecoder().decode(TerminalSettings.self, from: Data(#"{"fontName":"Monaco","fontSize":16}"#.utf8))
        XCTAssertEqual(settings.fontName, "Monaco")
        XCTAssertEqual(settings.fontSize, 16)
        XCTAssertEqual(try JSONDecoder().decode(TerminalSettings.self, from: JSONEncoder().encode(settings)), settings)
    }
}
