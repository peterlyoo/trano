import AppKit
import SwiftTerm
import XCTest
import TerminalCore
@testable import TranoApp

@MainActor private final class ThemePaletteRecorder: NSObject, TerminalViewDelegate {
    var reply = Data()
    func send(source: TerminalView, data: ArraySlice<UInt8>) { reply.append(contentsOf: data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

final class ThemeRenderingTests: XCTestCase {
    // Implements: FR-SET-62, FR-SET-64, surface-import-theme
    @MainActor func testModeColorsAndOptionalCursorSelectionColorsReachTheNativeView() throws {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        var preferences = ThemePreferences()
        let palette = ThemePalette(name: "Native", background: "#102030", foreground: "#DDEEFF",
                                   cursor: "#123456", cursorText: "#ABCDEF", selection: "#234567", selectionForeground: "#FEDCBA")
        try preferences.save(palette); try preferences.select(palette.id, for: .dark)
        TerminalThemeRenderer.apply(preferences.application(for: .dark, legacy: TerminalSettings()), to: view)
        XCTAssertEqual(hex(view.nativeBackgroundColor), "#102030")
        XCTAssertEqual(hex(view.nativeForegroundColor), "#DDEEFF")
        XCTAssertEqual(hex(view.caretColor), "#123456")
        XCTAssertEqual(view.caretTextColor.map(hex), "#ABCDEF")
        XCTAssertEqual(hex(view.selectedTextBackgroundColor), "#234567")
        XCTAssertEqual(hex(view.selectedTextForegroundColor), "#FEDCBA")
        TerminalThemeRenderer.apply(preferences.application(for: .light, legacy: TerminalSettings()), to: view)
        XCTAssertEqual(hex(view.nativeBackgroundColor), "#F7F8FA")
        XCTAssertNil(view.caretTextColor)
        XCTAssertEqual(hex(view.selectedTextForegroundColor), "#202127")
    }

    // Implements: FR-SET-63, FR-SET-65
    @MainActor func testThemeExtendedPaletteAndExplicitOverridesResetToXtermWhenDisabled() throws {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let recorder = ThemePaletteRecorder(); view.terminalDelegate = recorder
        var preferences = ThemePreferences()
        let palette = ThemePalette(name: "Extended", indexedColors: [31: "#123456"])
        try preferences.save(palette); try preferences.select(palette.id, for: .dark)
        preferences.darkExtendedPalette = true
        TerminalThemeRenderer.apply(preferences.application(for: .dark, legacy: TerminalSettings()), to: view)
        switch view.terminalStateSnapshot().ansi256PaletteStrategy {
        case .base16Lab: break
        default: XCTFail("Extended palette strategy was not applied")
        }
        XCTAssertTrue(query(31, view: view, recorder: recorder).contains("4;31;rgb:1212/3434/5656"))
        preferences.darkExtendedPalette = false
        TerminalThemeRenderer.apply(preferences.application(for: .dark, legacy: TerminalSettings()), to: view)
        switch view.terminalStateSnapshot().ansi256PaletteStrategy {
        case .xterm: break
        default: XCTFail("Fixed xterm palette was not restored")
        }
        XCTAssertTrue(query(31, view: view, recorder: recorder).contains("4;31;rgb:0000/8787/afaf"))
    }

    // Implements: FR-SET-62, FR-SET-64
    @MainActor func testThemeApplicationPreservesOpacityAndBackgroundImageTransparency() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        var settings = TerminalSettings(); settings.appearance.opacity = 0.65
        TerminalThemeRenderer.apply(ThemePreferences().application(for: .dark, legacy: settings), to: view)
        XCTAssertEqual(view.nativeBackgroundColor.alphaComponent, 0.65, accuracy: 0.001)
        settings.appearance.backgroundImagePath = "/not-opened-by-renderer.png"
        TerminalThemeRenderer.apply(ThemePreferences().application(for: .dark, legacy: settings), to: view)
        XCTAssertEqual(view.nativeBackgroundColor.alphaComponent, 0, accuracy: 0.001)
    }

    @MainActor private func query(_ index: Int, view: TerminalView, recorder: ThemePaletteRecorder) -> String {
        recorder.reply = Data()
        view.feed(text: "\u{1b}]4;\(index);?\u{7}")
        let deadline = Date().addingTimeInterval(1)
        while recorder.reply.isEmpty && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
        return String(decoding: recorder.reply, as: UTF8.self).lowercased()
    }

    @MainActor private func hex(_ color: NSColor) -> String {
        guard let value = color.usingColorSpace(.sRGB) else { return "unavailable" }
        return String(format: "#%02X%02X%02X", Int((value.redComponent * 255).rounded()), Int((value.greenComponent * 255).rounded()), Int((value.blueComponent * 255).rounded()))
    }
}
