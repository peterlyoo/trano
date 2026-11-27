import Foundation
import XCTest
@testable import TerminalCore

final class ThemePreferencesTests: XCTestCase {
    // Implements: FR-SET-62, FR-SET-64
    func testDefaultDarkPreservesLegacyAppearanceAndLightHasAnIndependentPalette() throws {
        let preferences = ThemePreferences()
        var legacy = TerminalSettings()
        legacy.background = "#123456"; legacy.appearance.foreground = "#FEDCBA"
        legacy.fontName = "Custom Font"; legacy.fontSize = 17; legacy.appearance.opacity = 0.65
        XCTAssertEqual(preferences.application(for: .dark, legacy: legacy).settings, legacy)
        let light = preferences.application(for: .light, legacy: legacy)
        XCTAssertEqual(light.settings.background, "#F7F8FA")
        XCTAssertEqual(light.settings.appearance.foreground, "#202127")
        XCTAssertEqual(light.settings.fontName, legacy.fontName)
        XCTAssertEqual(light.settings.fontSize, legacy.fontSize)
        XCTAssertEqual(light.settings.appearance.opacity, legacy.appearance.opacity)
        XCTAssertTrue(ThemePreferences.builtIns.contains { $0.id == ThemePreferences.defaultLightPaletteID })
    }

    // Implements: FR-SET-62, FR-SET-63, FR-SET-64, FR-SET-65
    func testModesAndExplicitFalseValuesRoundTripIndependently() throws {
        var value = ThemePreferences()
        try value.select("contrast", for: .dark)
        try value.select("black", for: .light)
        value.lightExtendedPalette = true
        value.darkExtendedPalette = false
        let decoded = try JSONDecoder().decode(ThemePreferences.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded.darkThemeID, "contrast")
        XCTAssertEqual(decoded.lightThemeID, "black")
        XCTAssertTrue(decoded.lightExtendedPalette)
        XCTAssertFalse(decoded.darkExtendedPalette)
        XCTAssertEqual(try JSONDecoder().decode(ThemePreferences.self, from: Data("{}".utf8)), ThemePreferences())
    }

    // Implements: FR-SET-63, FR-SET-65
    func testExtendedPaletteUsesOnlySelectedModeAndExplicitOverridesStayBounded() throws {
        var value = ThemePreferences()
        let palette = ThemePalette(name: "Extended", foreground: "#FFFFFF", cursorText: "#102030", selectionForeground: "#405060",
                                   indexedColors: [16: "#123456", 255: "#ABCDEF"])
        try value.save(palette)
        try value.select(palette.id, for: .dark)
        value.darkExtendedPalette = true
        let plan = value.application(for: .dark, legacy: TerminalSettings())
        XCTAssertTrue(plan.useExtendedPalette)
        XCTAssertEqual(plan.indexedColors, palette.indexedColors)
        XCTAssertEqual(plan.cursorText, palette.cursorText)
        XCTAssertEqual(plan.selectionForeground, palette.selectionForeground)
        XCTAssertEqual(plan.paletteOSC(), "\u{1b}]4;16;#123456;255;#ABCDEF\u{1b}\\")
        value.darkExtendedPalette = false
        let standard = value.application(for: .dark, legacy: TerminalSettings())
        XCTAssertFalse(standard.useExtendedPalette)
        XCTAssertTrue(standard.indexedColors.isEmpty)
        XCTAssertTrue(standard.paletteOSC().isEmpty)
        XCTAssertFalse(value.application(for: .light, legacy: TerminalSettings()).useExtendedPalette)
    }

    // Implements: FR-SET-62, FR-SET-64
    func testExplicitAppearanceProfileKeepsItsColorsAndOptionalThemeColorsDoNotLeak() throws {
        var value = ThemePreferences()
        try value.select("contrast", for: .dark)
        value.darkExtendedPalette = true
        var profile = TerminalSettings()
        profile.background = "#112233"; profile.appearance.foreground = "#445566"
        let plan = value.application(for: .dark, legacy: profile, profileAssigned: true)
        XCTAssertEqual(plan.settings, profile)
        XCTAssertTrue(plan.useExtendedPalette)
        XCTAssertTrue(plan.indexedColors.isEmpty)
        XCTAssertNil(plan.cursorText)
        XCTAssertNil(plan.selectionForeground)
    }

    // Implements: FR-SET-62, FR-SET-64
    func testPaletteValidationRejectsInvalidColorsIdentifiersNamesAndIndexes() throws {
        let original = ThemePalette(name: "Valid")
        for modify in [
            { (p: inout ThemePalette) in p.background = "#123" },
            { (p: inout ThemePalette) in p.foreground = "#GG0000" },
            { (p: inout ThemePalette) in p.id = "black" },
            { (p: inout ThemePalette) in p.name = "\n" },
            { (p: inout ThemePalette) in p.name = String(repeating: "x", count: 81) },
            { (p: inout ThemePalette) in _ = p.ansiColors.popLast() },
            { (p: inout ThemePalette) in p.indexedColors[256] = "#123456" },
            { (p: inout ThemePalette) in p.indexedColors[15] = "#123456" },
            { (p: inout ThemePalette) in p.selectionForeground = "white" }
        ] {
            var palette = original; modify(&palette)
            XCTAssertThrowsError(try palette.validate())
        }
        var preferences = ThemePreferences()
        preferences.customThemes = [original, original]
        XCTAssertThrowsError(try preferences.validate())
        preferences = ThemePreferences(); preferences.darkThemeID = "missing"
        XCTAssertThrowsError(try preferences.validate())
        preferences = ThemePreferences(); preferences.schemaVersion = 2
        XCTAssertThrowsError(try preferences.validate())
    }

    // Implements: FR-SET-62, FR-SET-64
    func testDuplicateEditDeletePreserveBuiltInsAndResetBothDeletedSelections() throws {
        var preferences = ThemePreferences()
        let builtIns = ThemePreferences.builtIns
        let id = try preferences.duplicate("black", name: "한국어 👩‍💻 테마")
        XCTAssertNotEqual(id, "black")
        XCTAssertNotNil(UUID(uuidString: id))
        var custom = try XCTUnwrap(preferences.customThemes.first { $0.id == id })
        XCTAssertEqual(custom.name, "한국어 👩‍💻 테마")
        custom.foreground = "#AABBCC"
        try preferences.save(custom)
        try preferences.select(id, for: .light); try preferences.select(id, for: .dark)
        XCTAssertEqual(preferences.application(for: .light, legacy: TerminalSettings()).settings.appearance.foreground, "#AABBCC")
        XCTAssertEqual(ThemePreferences.builtIns, builtIns)
        XCTAssertThrowsError(try preferences.remove("black"))
        try preferences.remove(id)
        XCTAssertTrue(preferences.customThemes.isEmpty)
        XCTAssertEqual(preferences.darkThemeID, ThemePreferences.currentPaletteID)
        XCTAssertEqual(preferences.lightThemeID, ThemePreferences.defaultLightPaletteID)
    }

    // Implements: FR-SET-62, FR-SET-64
    func testLeafMergePreservesConcurrentModeAndPaletteEdits() throws {
        var baseline = ThemePreferences()
        let palette = ThemePalette(name: "Baseline", indexedColors: [16: "#112233", 17: "#223344"])
        try baseline.save(palette)
        var draft = baseline
        draft.darkExtendedPalette = true
        var edited = try XCTUnwrap(draft.customThemes.first { $0.id == palette.id })
        edited.name = "User rename"
        edited.indexedColors[16] = "#ABCDEF"
        draft.customThemes = [edited]
        var current = baseline
        current.lightExtendedPalette = true
        var concurrent = try XCTUnwrap(current.customThemes.first { $0.id == palette.id })
        concurrent.foreground = "#FFAA33"
        concurrent.indexedColors[17] = "#778899"
        current.customThemes = [concurrent]
        let other = ThemePalette(name: "Concurrent")
        current.customThemes.append(other)
        try current.merge(draft, from: baseline)
        XCTAssertTrue(current.darkExtendedPalette)
        XCTAssertTrue(current.lightExtendedPalette)
        XCTAssertEqual(current.customThemes.first { $0.id == palette.id }?.name, "User rename")
        XCTAssertEqual(current.customThemes.first { $0.id == palette.id }?.foreground, "#FFAA33")
        XCTAssertEqual(current.customThemes.first { $0.id == palette.id }?.indexedColors[16], "#ABCDEF")
        XCTAssertEqual(current.customThemes.first { $0.id == palette.id }?.indexedColors[17], "#778899")
        XCTAssertTrue(current.customThemes.contains(other))
    }

    // Implements: FR-SET-62, FR-SET-64, surface-import-theme
    func testImportDoesNotOverwriteSameNameOrMutateOnFailure() throws {
        var preferences = ThemePreferences()
        let data = Data("background = #102030\nforeground = #F0E0D0\n".utf8)
        let first = try preferences.importTheme(data: data, filename: "한글.ghostty", for: .dark)
        let second = try preferences.importTheme(data: data, filename: "한글.ghostty", for: .light)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(preferences.customThemes.map(\.name), ["한글", "한글 (2)"])
        XCTAssertEqual(preferences.darkThemeID, first)
        XCTAssertEqual(preferences.lightThemeID, second)
        let before = preferences
        XCTAssertThrowsError(try preferences.importTheme(data: Data("background = invalid".utf8), filename: "bad.conf", for: .dark))
        XCTAssertEqual(preferences, before)
    }

    // Implements: FR-SET-62, FR-SET-64
    func testStorePersistsPrivatelyAndAnOldPrimaryWriterCannotEraseThemes() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ThemePreferencesStore(root: root)
        XCTAssertEqual(try store.load(), ThemePreferences())
        var preferences = ThemePreferences()
        try preferences.select("contrast", for: .dark)
        preferences.darkExtendedPalette = true
        XCTAssertEqual(try store.save(preferences), preferences)
        let path = root.appendingPathComponent("theme-preferences.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try Data("{\"settings\":{}}".utf8).write(to: root.appendingPathComponent("state.json"))
        XCTAssertEqual(try ThemePreferencesStore(root: root).load(), preferences)
        let baseline = preferences
        preferences.lightExtendedPalette = true
        _ = try store.save(preferences)
        var draft = baseline; draft.darkExtendedPalette = false
        let merged = try store.save(draft, baseline: baseline)
        XCTAssertTrue(merged.lightExtendedPalette)
        XCTAssertFalse(merged.darkExtendedPalette)
    }

    // Implements: FR-SET-62, FR-SET-64
    func testStoreRejectsSymlinksHardLinksPublicAndMalformedFiles() throws {
        for kind in ["symlink", "hardlink", "public", "malformed", "large"] {
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let target = root.appendingPathComponent("theme-preferences.json")
            let data = try JSONEncoder().encode(ThemePreferences())
            if kind == "symlink" || kind == "hardlink" {
                let other = root.appendingPathComponent("other")
                try data.write(to: other)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: other.path)
                if kind == "symlink" { try FileManager.default.createSymbolicLink(at: target, withDestinationURL: other) }
                else { try FileManager.default.linkItem(at: other, to: target) }
            } else {
                try (kind == "large" ? Data(repeating: 0x20, count: 2_097_153) : kind == "malformed" ? Data("{".utf8) : data).write(to: target)
                try FileManager.default.setAttributes([.posixPermissions: kind == "public" ? 0o644 : 0o600], ofItemAtPath: target.path)
            }
            XCTAssertThrowsError(try ThemePreferencesStore(root: root).load(), kind)
            XCTAssertThrowsError(try ThemePreferencesStore(root: root).save(ThemePreferences()), kind)
        }
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trano-theme-unit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
}
