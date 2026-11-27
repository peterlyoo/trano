import AppKit
import CoreText
import XCTest
import TerminalCore
@testable import TranoApp

@MainActor
final class TerminalFontAdapterTests: XCTestCase {
    // Implements: FR-SET-66, FR-SET-67, FR-SET-68
    func testSelectedPostScriptFaceAndSizeAreUsedWithoutChangingFamily() throws {
        var preferences = ResolvedTerminalPreferences()
        preferences.fontName = "Menlo-Regular"; preferences.fontSize = 18
        preferences.fontStyle = "Menlo-Italic"
        let font = try TerminalFontAdapter.font(for: preferences)
        XCTAssertEqual(font.fontName, "Menlo-Italic")
        XCTAssertEqual(font.pointSize, 18)
        XCTAssertEqual(font.familyName, NSFont(name: "Menlo-Regular", size: 18)?.familyName)
    }

    // Implements: FR-SET-68
    func testFacePickerContainsOnlyAvailableFacesForSelectedFamily() throws {
        let font = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 14))
        let family = try XCTUnwrap(font.familyName)
        let faces = TerminalFontAdapter.faces(inFamily: family)
        XCTAssertTrue(faces.contains("Menlo-Regular"))
        XCTAssertTrue(faces.contains("Menlo-Italic"))
        for face in faces { XCTAssertEqual(NSFont(name: face, size: 14)?.familyName, family) }
    }

    // Implements: FR-SET-69
    func testNonvariableFontDoesNotPretendToSupportVariableWeight() throws {
        var preferences = ResolvedTerminalPreferences()
        preferences.fontName = "Menlo-Regular"; preferences.fontWeight = 650
        let normal = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 14))
        XCTAssertNil(TerminalFontAdapter.weightAxis(for: normal))
        XCTAssertThrowsError(try TerminalFontAdapter.font(for: preferences))
    }

    // Implements: FR-SET-69
    func testVariableFontWeightUsesItsRealAxisAndRejectsValuesOutsideItsBounds() throws {
        let available = ["Skia-Regular", "Skia", "SFPro-Regular", "SFCompact-Regular"]
        let candidate = available.lazy.compactMap { NSFont(name: $0, size: 14) }
            .first { font in
                guard let axes = CTFontCopyVariationAxes(font as CTFont) as? [[CFString: Any]] else { return false }
                return axes.contains { ($0[kCTFontVariationAxisIdentifierKey] as? NSNumber)?.intValue == 0x77676874 }
            }
        guard let variable = candidate else { throw XCTSkip("No installed variable font exposes a wght axis") }
        let axis = try XCTUnwrap(TerminalFontAdapter.weightAxis(for: variable))
        XCTAssertEqual(axis.identifier, 0x77676874)
        XCTAssertLessThan(axis.minimum, axis.maximum)
        var preferences = ResolvedTerminalPreferences()
        preferences.fontName = variable.fontName
        preferences.fontWeight = axis.maximum
        let maximum = try TerminalFontAdapter.font(for: preferences)
        let variation = try XCTUnwrap(CTFontCopyVariation(maximum as CTFont) as? [NSNumber: NSNumber])
        XCTAssertEqual(try XCTUnwrap(variation[NSNumber(value: axis.identifier)]).doubleValue, axis.maximum, accuracy: 0.001)
        preferences.fontWeight = axis.maximum + 1000
        XCTAssertThrowsError(try TerminalFontAdapter.font(for: preferences))
    }

    // Implements: FR-SET-71
    func testPixelsUseBackingScaleAndPercentUsesBaseCellWidth() {
        let pixels = TerminalCharacterSpacing(value: 2, unit: .pixels)
        XCTAssertEqual(TerminalFontAdapter.spacingPoints(pixels, cellWidth: 10, backingScale: 1), 2)
        XCTAssertEqual(TerminalFontAdapter.spacingPoints(pixels, cellWidth: 10, backingScale: 2), 1)
        let percent = TerminalCharacterSpacing(value: 12, unit: .percent)
        XCTAssertEqual(TerminalFontAdapter.spacingPoints(percent, cellWidth: 10, backingScale: 2), 1.2, accuracy: 0.001)
    }

    // Implements: FR-SET-76
    func testOrderedFallbackFontsReachTheFontCascade() throws {
        var preferences = ResolvedTerminalPreferences()
        preferences.fontName = "Menlo-Regular"
        preferences.fallbackFonts = ["AppleSDGothicNeo-Regular", "Monaco"]
        let font = try TerminalFontAdapter.font(for: preferences)
        let cascade = try XCTUnwrap(font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor])
        XCTAssertEqual(cascade.map(\.postscriptName), ["AppleSDGothicNeo-Regular", "Monaco"])
        preferences.fallbackFonts = []
        let plain = try TerminalFontAdapter.font(for: preferences)
        let empty = plain.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor]
        XCTAssertTrue(empty?.isEmpty ?? true)
    }
}
