import Foundation
import XCTest
@testable import TerminalCore

final class ThemeImportTests: XCTestCase {
    // Implements: surface-import-theme
    func testGhosttyImportPreservesUnicodeNamesAndExplicitExtendedPalette() throws {
        var lines = ["# ignored comment", "background = 102030", "foreground = #DDEEFF", "cursor-color = #123456", "cursor-text = cell-background", "selection-background = #234567", "selection-foreground = cell-foreground"]
        for index in 0..<16 { lines.append("palette = \(index)=#" + String(format: "%06X", index * 0x010101)) }
        lines += ["palette = 0x10=#AABBCC", "palette = 0b11111111=123ABC", "font-family = not imported", "command = not executed"]
        let palette = try ThemeImport.parse(data: Data(lines.joined(separator: "\n").utf8), filename: "새 테마 👩‍💻.ghostty")
        XCTAssertEqual(palette.name, "새 테마 👩‍💻")
        XCTAssertEqual(palette.background, "#102030")
        XCTAssertEqual(palette.foreground, "#DDEEFF")
        XCTAssertEqual(palette.cursor, "#123456")
        XCTAssertEqual(palette.cursorText, palette.background)
        XCTAssertEqual(palette.selection, "#234567")
        XCTAssertEqual(palette.selectionForeground, palette.foreground)
        XCTAssertEqual(palette.ansiColors, (0..<16).map { "#" + String(format: "%06X", $0 * 0x010101) })
        XCTAssertEqual(palette.indexedColors, [16: "#AABBCC", 255: "#123ABC"])
    }

    // Implements: surface-import-theme
    func testGhosttyNamedX11ColorsAndRepeatedPaletteEntriesFollowTheFile() throws {
        let data = Data("background = navy\nforeground = medium spring green\npalette = 0o7=gray42\npalette = 1=red\npalette = 1=#010203\n".utf8)
        let palette = try ThemeImport.parse(data: data, filename: "Named")
        XCTAssertEqual(palette.background, "#000080")
        XCTAssertEqual(palette.foreground, "#00FA9A")
        XCTAssertEqual(palette.ansiColors.dropFirst(7).first, "#6B6B6B")
        XCTAssertEqual(palette.ansiColors.dropFirst(1).first, "#010203")
    }

    // Implements: surface-import-theme
    func testGhosttyRejectsMalformedKnownFieldsWithoutExecutingUnknownSettings() throws {
        for text in ["background = #12", "foreground = invented color", "palette = 256=#AABBCC", "palette = -1=#AABBCC", "palette = 0xGG=#AABBCC", "palette = 3=bad", "font-size=14", "background"] {
            XCTAssertThrowsError(try ThemeImport.parse(data: Data(text.utf8), filename: "Invalid"), text)
        }
        let minimal = try ThemeImport.parse(data: Data("font-family=ignored\nbackground=#102030".utf8), filename: "Minimal")
        XCTAssertEqual(minimal.background, "#102030")
    }

    // Implements: surface-import-theme
    func testITermXMLAndBinaryImportsReadActualRGBComponents() throws {
        var source: [String: Any] = ["Background Color": color(0.1, 0.2, 0.3), "Foreground Color": color(1, 1, 1),
                                     "Cursor Color": color(1, 0, 0), "Cursor Text Color": color(0, 0, 0),
                                     "Selection Color": color(0.2, 0.3, 0.4), "Selected Text Color": color(0.5, 0.5, 0.5),
                                     "Ansi 255 Color": color(0, 1, 1)]
        for index in 0..<16 { source["Ansi \(index) Color"] = color(Double(index) / 15, 0, 0) }
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            let data = try PropertyListSerialization.data(fromPropertyList: source, format: format, options: 0)
            let palette = try ThemeImport.parse(data: data, filename: "한국어.itermcolors")
            XCTAssertEqual(palette.name, "한국어")
            XCTAssertEqual(palette.background, "#1A334D")
            XCTAssertEqual(palette.foreground, "#FFFFFF")
            XCTAssertEqual(palette.cursorText, "#000000")
            XCTAssertEqual(palette.selectionForeground, "#808080")
            XCTAssertEqual(palette.indexedColors[255], "#00FFFF")
            XCTAssertEqual(palette.ansiColors.count, 16)
            XCTAssertEqual(palette.ansiColors.last, "#FF0000")
        }
    }

    // Implements: surface-import-theme
    func testITermRejectsNonNumericNonFiniteOutOfRangeAndUnsupportedSpaces() throws {
        let invalid: [[String: Any]] = [
            ["Red Component": "1", "Green Component": 0, "Blue Component": 0],
            ["Red Component": true, "Green Component": 0, "Blue Component": 0],
            ["Red Component": 1.1, "Green Component": 0, "Blue Component": 0],
            ["Red Component": -0.1, "Green Component": 0, "Blue Component": 0],
            ["Red Component": Double.nan, "Green Component": 0, "Blue Component": 0],
            ["Red Component": 1, "Green Component": 0],
            ["Red Component": 1, "Green Component": 0, "Blue Component": 0, "Color Space": "Unsupported"]
        ]
        for value in invalid {
            let data = try PropertyListSerialization.data(fromPropertyList: ["Background Color": value], format: .binary, options: 0)
            XCTAssertThrowsError(try ThemeImport.parse(data: data, filename: "bad.itermcolors"))
        }
    }

    // Implements: surface-import-theme
    func testImportBoundsAndXMLExternalEntitiesAreRejected() throws {
        for data in [Data(), Data([0xFF, 0xFE, 0xFD]), Data(repeating: 0x20, count: ThemeImport.maximumBytes + 1),
                     Data("<!DOCTYPE plist [<!ENTITY x SYSTEM 'file:///not-read'>]><plist><dict/></plist>".utf8)] {
            XCTAssertThrowsError(try ThemeImport.parse(data: data, filename: "invalid"))
        }
        let empty = try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .xml, options: 0)
        XCTAssertThrowsError(try ThemeImport.parse(data: empty, filename: "empty.itermcolors"))
    }

    private func color(_ red: Double, _ green: Double, _ blue: Double) -> [String: Any] {
        ["Red Component": red, "Green Component": green, "Blue Component": blue, "Color Space": "sRGB"]
    }
}
