import Foundation
import XCTest
@testable import TerminalCore

final class TerminalPreferencesTests: XCTestCase {
    // Implements: FR-SET-66, FR-SET-67, FR-SET-68, FR-SET-69, FR-SET-70, FR-SET-75, FR-SET-76, FR-SET-82, FR-SET-85, FR-SET-90, FR-SET-91
    func testDefaultsInheritExistingAppearanceInsteadOfReplacingUserChoices() throws {
        var legacy = TerminalSettings()
        legacy.fontName = "Monaco"; legacy.fontSize = 17
        legacy.optionAsMeta = true
        legacy.appearance.lineSpacing = 1.4
        legacy.appearance.fallbackFontName = "Custom-Hangul-Fallback"
        legacy.appearance.cursorStyle = .beam
        legacy.appearance.cursorBlink = true
        legacy.appearance.foreground = "#123456"; legacy.appearance.selection = "#334455"
        let value = TerminalPreferences().resolved(legacy: legacy)
        XCTAssertEqual(value.fontName, "Monaco"); XCTAssertEqual(value.fontSize, 17)
        XCTAssertEqual(value.lineHeight, 1.4)
        XCTAssertEqual(value.fallbackFonts, ["Custom-Hangul-Fallback"])
        XCTAssertEqual(value.cursorStyle, .beam)
        XCTAssertEqual(value.cursorBlinkInterval, 0.7)
        XCTAssertEqual(value.selectionForeground, "#123456")
        XCTAssertEqual(value.selectionBackground, "#334455")
        XCTAssertTrue(value.optionAsMeta)
        XCTAssertFalse(value.fontSmoothing)
    }

    // Implements: FR-SET-66, FR-SET-67, FR-SET-68, FR-SET-69, FR-SET-70, FR-SET-71, FR-SET-72, FR-SET-73, FR-SET-74, FR-SET-75, FR-SET-76, FR-SET-77, FR-SET-78, FR-SET-79
    func testExplicitTypographyAndColorChoicesResolveWithoutMutatingLegacySettings() throws {
        let legacy = TerminalSettings()
        let before = legacy
        var preferences = TerminalPreferences()
        preferences.fontName = "CustomMono-Regular"; preferences.fontSize = 19
        preferences.fontStyle = "CustomMono-Italic"; preferences.fontWeight = 650
        preferences.lineHeight = 1.25
        preferences.characterSpacing = TerminalCharacterSpacing(value: 8, unit: .percent)
        preferences.ligatures = false; preferences.fontStyles = .italicOnly
        preferences.forceFontStyles = true; preferences.fontSmoothing = true
        preferences.fallbackFonts = ["Hangul-First", "Symbol-Second"]
        preferences.minimumContrastRatio = 4.5; preferences.forceThemePaletteForText = true; preferences.useDisplayP3 = true
        let value = preferences.resolved(legacy: legacy)
        XCTAssertEqual(value.fontName, "CustomMono-Regular"); XCTAssertEqual(value.fontSize, 19)
        XCTAssertEqual(value.fontStyle, "CustomMono-Italic"); XCTAssertEqual(value.fontWeight, 650)
        XCTAssertEqual(value.lineHeight, 1.25); XCTAssertEqual(value.characterSpacing, preferences.characterSpacing)
        XCTAssertFalse(value.ligatures); XCTAssertEqual(value.fontStyles, .italicOnly)
        XCTAssertTrue(value.forceFontStyles); XCTAssertTrue(value.fontSmoothing)
        XCTAssertEqual(value.fallbackFonts, ["Hangul-First", "Symbol-Second"])
        XCTAssertEqual(value.minimumContrastRatio, 4.5)
        XCTAssertTrue(value.forceThemePaletteForText); XCTAssertTrue(value.useDisplayP3)
        XCTAssertEqual(legacy, before)
    }

    // Implements: FR-SET-80, FR-SET-81, FR-SET-82, FR-SET-83
    func testEveryCursorRateHasAnExplicitIntervalAndOffDoesNotBlink() {
        var preferences = TerminalPreferences()
        let expected: [(TerminalBlinkSpeed, Double?)] = [(.off, nil), (.slow, 1.2), (.normal, 0.7), (.fast, 0.35), (.custom, 0.425)]
        preferences.cursorBlinkIntervalMS = 425
        preferences.cursorStyle = .underline; preferences.forceCursorStyle = true
        for (rate, interval) in expected {
            preferences.cursorBlinkSpeed = rate
            let value = preferences.resolved(legacy: TerminalSettings())
            XCTAssertEqual(value.cursorBlinkInterval, interval)
            XCTAssertEqual(value.cursorStyle, .underline)
            XCTAssertTrue(value.forceCursorStyle)
        }
    }

    // Implements: FR-SET-84, FR-SET-85, FR-SET-86, FR-SET-87, FR-SET-88, FR-SET-89, FR-SET-90, FR-SET-91, FR-SET-92, FR-SET-95, FR-SET-96
    func testInputSelectionAndTitlePolicyValuesHaveObservableResolvedEffects() {
        var preferences = TerminalPreferences()
        preferences.showKeySequenceHints = false; preferences.optionKey = .meta
        preferences.smoothScrolling = false; preferences.smoothResizing = false
        preferences.copyOnSelection = true; preferences.animateCopy = true
        preferences.selectionForeground = "#AABBCC"; preferences.selectionBackground = "#113355"
        preferences.selectionCornerRadius = 4
        preferences.showRecentPaths = false; preferences.preferGeneratedTitles = false
        let value = preferences.resolved(legacy: TerminalSettings())
        XCTAssertFalse(value.showKeySequenceHints); XCTAssertTrue(value.optionAsMeta)
        XCTAssertFalse(value.smoothScrolling); XCTAssertFalse(value.smoothResizing)
        XCTAssertTrue(value.copyOnSelection); XCTAssertTrue(value.animateCopy)
        XCTAssertEqual(value.selectionForeground, "#AABBCC"); XCTAssertEqual(value.selectionBackground, "#113355")
        XCTAssertEqual(value.selectionCornerRadius, 4)
        XCTAssertFalse(value.showRecentPaths); XCTAssertFalse(value.preferGeneratedTitles)
    }

    // Implements: FR-SET-66, FR-SET-67, FR-SET-70, FR-SET-71, FR-SET-77, FR-SET-81, FR-SET-92
    func testRejectsInvalidNumbersAndControlCharactersBeforePersistence() {
        let mutations: [(inout TerminalPreferences) -> Void] = [
            { $0.fontSize = .nan }, { $0.fontSize = 2 }, { $0.fontSize = 257 },
            { $0.lineHeight = .infinity }, { $0.lineHeight = 0 },
            { $0.fontWeight = .nan }, { $0.characterSpacing.value = .nan },
            { $0.characterSpacing.value = 1000 }, { $0.minimumContrastRatio = 22 },
            { $0.cursorBlinkIntervalMS = 10 }, { $0.selectionCornerRadius = -1 },
            { $0.fontName = "Bad\u{0}Font" }, { $0.fontStyle = "Bad\nFace" },
            { $0.selectionForeground = "transparent" }, { $0.selectionBackground = "#1234" }
        ]
        for mutation in mutations { var value = TerminalPreferences(); mutation(&value); XCTAssertThrowsError(try value.validate()) }
    }

    // Implements: FR-SET-76
    func testFallbackOrderIsPreservedAndAnExplicitEmptyCascadeDiffersFromInheritance() throws {
        var value = TerminalPreferences()
        value.fallbackFonts = ["한글", "Symbols"]
        XCTAssertNoThrow(try value.validate())
        XCTAssertEqual(value.resolved(legacy: TerminalSettings()).fallbackFonts, ["한글", "Symbols"])
        value.fallbackFonts = []
        XCTAssertEqual(value.resolved(legacy: TerminalSettings()).fallbackFonts, [])
        value.fallbackFonts = ["Same", "Same"]
        XCTAssertThrowsError(try value.validate())
        value.fallbackFonts = [String(repeating: "a", count: 201)]
        XCTAssertThrowsError(try value.validate())
    }

    // Implements: FR-SET-93, FR-SET-94
    func testApplicationLinkDefaultsAskWhileWebLinksOpenAndDangerousSchemesStayDenied() throws {
        let value = TerminalPreferences()
        XCTAssertEqual(value.linkDecision(for: try XCTUnwrap(URL(string: "https://example.test/path"))), .open)
        XCTAssertEqual(value.linkDecision(for: try XCTUnwrap(URL(string: "ssh://user@example.test"))), .ask)
        for link in ["javascript:alert(1)", "data:text/plain,hello", "about:blank"] {
            XCTAssertEqual(value.linkDecision(for: try XCTUnwrap(URL(string: link))), .deny)
        }
    }

    // Implements: FR-SET-93, FR-SET-94
    func testTrustedAppLinksUseExactSchemeHostAndPortAndCanBeRevoked() throws {
        var value = TerminalPreferences()
        value.trustedLinks = [TerminalTrustedLink(scheme: "ssh", host: "example.test", port: 2222)]
        XCTAssertEqual(value.linkDecision(for: try XCTUnwrap(URL(string: "ssh://user@example.test:2222/path"))), .open)
        XCTAssertEqual(value.linkDecision(for: try XCTUnwrap(URL(string: "ssh://example.test.evil:2222/path"))), .ask)
        XCTAssertEqual(value.linkDecision(for: try XCTUnwrap(URL(string: "vscode://example.test:2222/path"))), .ask)
        XCTAssertEqual(value.linkDecision(for: try XCTUnwrap(URL(string: "ssh://example.test:22/path"))), .ask)
        value.trustedLinks.removeAll()
        XCTAssertEqual(value.linkDecision(for: try XCTUnwrap(URL(string: "ssh://example.test:2222/path"))), .ask)
        value.applicationLinks = .never
        XCTAssertEqual(value.linkDecision(for: try XCTUnwrap(URL(string: "ssh://example.test"))), .deny)
        value.applicationLinks = .always
        XCTAssertEqual(value.linkDecision(for: try XCTUnwrap(URL(string: "ssh://example.test"))), .open)
    }

    // Implements: FR-SET-94
    func testTrustedLinkValidationDoesNotAcceptWildcardsCredentialsOrInvalidPorts() {
        for rule in [TerminalTrustedLink(scheme: "javascript"), TerminalTrustedLink(scheme: "ssh", host: "*.test"), TerminalTrustedLink(scheme: "ssh", host: "user:password@example.test"), TerminalTrustedLink(scheme: "ssh", port: -1)] {
            var value = TerminalPreferences(); value.trustedLinks = [rule]
            XCTAssertThrowsError(try value.validate())
        }
    }

    // Implements: FR-SET-97
    func testStartupCommandKeepsExactUnicodeArgumentsAndNeverBuildsAShellString() throws {
        var value = TerminalPreferences()
        let command = TerminalStartupCommand(executable: "/tmp/한글 shell", arguments: ["--literal", "'quotes'", "$VALUE", "a;b", "한글"])
        value.startupCommand = command
        XCTAssertNoThrow(try value.validate())
        XCTAssertEqual(value.startup(), command)
        let actual = value.startup().arguments
        XCTAssertEqual(actual.count, command.arguments.count)
        guard actual.count == command.arguments.count else { return }
        XCTAssertEqual(Array(actual[4].utf8), Array(command.arguments[4].utf8))
        value.startupCommand = nil
        XCTAssertEqual(value.startup(), TerminalStartupCommand(executable: "/bin/zsh", arguments: ["-l"]))
        for command in [TerminalStartupCommand(executable: "relative"), TerminalStartupCommand(executable: "/bin/zsh", arguments: ["bad\u{0}"]), TerminalStartupCommand(executable: "/bin/zsh", arguments: Array(repeating: "x", count: 65))] {
            value.startupCommand = command
            XCTAssertThrowsError(try value.validate())
        }
    }

    // Implements: FR-SET-66, FR-SET-67, FR-SET-86, FR-SET-88, FR-SET-94
    func testPreferenceRoundTripRetainsFalseNilEmptyAndExactStrings() throws {
        var value = TerminalPreferences()
        value.fontName = "한글Mono"; value.fontSize = 18
        value.smoothScrolling = false; value.copyOnSelection = true
        value.fallbackFonts = []; value.trustedLinks = [TerminalTrustedLink(scheme: "ssh", host: "host.test")]
        XCTAssertEqual(try JSONDecoder().decode(TerminalPreferences.self, from: JSONEncoder().encode(value)), value)
        XCTAssertEqual(try JSONDecoder().decode(TerminalPreferences.self, from: Data("{}".utf8)), TerminalPreferences())
    }

    // Implements: FR-SET-66, FR-SET-67, FR-SET-86, FR-SET-88
    func testSaveMergesOnlyFieldsEditedAgainstTheDraftBaseline() throws {
        let baseline = TerminalPreferences()
        var current = baseline
        current.fontName = "ConcurrentFont"; current.copyOnSelection = true
        var draft = baseline
        draft.smoothScrolling = false
        draft.characterSpacing = TerminalCharacterSpacing(value: 3, unit: .pixels)
        current.merge(draft, from: baseline)
        XCTAssertEqual(current.fontName, "ConcurrentFont"); XCTAssertTrue(current.copyOnSelection)
        XCTAssertFalse(current.smoothScrolling); XCTAssertEqual(current.characterSpacing, draft.characterSpacing)
    }

    // Implements: FR-SET-95
    func testRecentPathsAreBoundedDistinctByHostAndPreserveExactUnicode() throws {
        var history = TerminalPathHistory()
        let nfd = "/tmp/한글 path"
        for index in 0..<25 { try history.record("/tmp/local-\(index)", at: Date(timeIntervalSince1970: Double(index))) }
        try history.record(nfd, at: Date(timeIntervalSince1970: 100))
        try history.record(nfd, hostID: "remote", at: Date(timeIntervalSince1970: 101))
        XCTAssertEqual(history.recent().count, 20)
        XCTAssertEqual(Array(try XCTUnwrap(history.recent().first).path.utf8), Array(nfd.utf8))
        XCTAssertEqual(history.recent(hostID: "remote").map(\.path), [nfd])
        XCTAssertTrue(history.recent(enabled: false).isEmpty)
        try history.record("/tmp/local-24", at: Date(timeIntervalSince1970: 102))
        XCTAssertEqual(history.recent().first?.path, "/tmp/local-24")
        XCTAssertThrowsError(try history.record("relative", at: Date()))
    }

    // Implements: FR-SET-66, FR-SET-97
    func testIndependentSidecarSurvivesPrimaryStateRewritesAndUsesPrivateOwnedFile() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TerminalPreferenceStore(root: root)
        var value = TerminalPreferences(); value.fontName = "Monaco"; value.startupCommand = TerminalStartupCommand(executable: "/bin/zsh", arguments: ["-df"])
        try store.save(value)
        try Data("{\"schemaVersion\":1}".utf8).write(to: root.appendingPathComponent("state.json"))
        XCTAssertEqual(try store.load(), value)
        let attrs = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try TerminalPreferenceStore(root: root).load(), value)
    }

    // Implements: FR-SET-66
    func testStoreRejectsSymlinkOversizedAndUnknownVersionWithoutOverwritingTargets() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TerminalPreferenceStore(root: root)
        let target = root.appendingPathComponent("target")
        try Data("unchanged".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: store.url, withDestinationURL: target)
        XCTAssertThrowsError(try store.load()); XCTAssertThrowsError(try store.save(TerminalPreferences()))
        XCTAssertEqual(try Data(contentsOf: target), Data("unchanged".utf8))
        try FileManager.default.removeItem(at: store.url)
        try Data("{\"schemaVersion\":99,\"preferences\":{}}".utf8).write(to: store.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.url.path)
        XCTAssertThrowsError(try store.load()); XCTAssertThrowsError(try store.save(TerminalPreferences()))
        try FileManager.default.removeItem(at: store.url)
        try Data(repeating: 0, count: 1_048_577).write(to: store.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.url.path)
        XCTAssertThrowsError(try store.load())
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trano-terminal-prefs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
}
