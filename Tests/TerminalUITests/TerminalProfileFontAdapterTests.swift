import AppKit
import XCTest
import TerminalCore
@testable import TranoApp

@MainActor
final class TerminalProfileFontAdapterTests: XCTestCase {
    // Implements: FR-SET-66, FR-SET-67, FR-SET-68, FR-SET-69, FR-SET-76
    func testProfileMenloDoesNotReceiveGlobalVariableWeightOrOtherFamilyFace() throws {
        var profile = TerminalSettings()
        profile.fontName = "Menlo-Regular"
        profile.fontSize = 21
        profile.appearance.fallbackFontName = "AppleSDGothicNeo-Regular"
        var preferences = TerminalPreferences()
        preferences.fontName = "Skia-Regular"
        preferences.fontSize = 33
        preferences.fontStyle = "Helvetica-Bold"
        preferences.fontWeight = 650
        preferences.fallbackFonts = ["Monaco"]
        let resolved = preferences.resolved(legacy: profile, profileAssigned: true)
        let font = try TerminalFontAdapter.font(for: resolved)
        XCTAssertEqual(font.fontName, "Menlo-Regular")
        XCTAssertEqual(font.pointSize, 21)
        let cascade = try XCTUnwrap(font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor])
        XCTAssertEqual(cascade.map(\.postscriptName), ["AppleSDGothicNeo-Regular"])
        XCTAssertNil(resolved.fontStyle)
        XCTAssertNil(resolved.fontWeight)
    }

    // Implements: FR-SET-66, FR-SET-67, FR-SET-68
    func testUnprofiledCustomFaceAndSizeStillReachNativeAdapter() throws {
        var preferences = TerminalPreferences()
        preferences.fontName = "Menlo-Regular"
        preferences.fontStyle = "Menlo-Italic"
        preferences.fontSize = 18
        let font = try TerminalFontAdapter.font(for: preferences.resolved(legacy: TerminalSettings()))
        XCTAssertEqual(font.fontName, "Menlo-Italic")
        XCTAssertEqual(font.pointSize, 18)
    }
}
