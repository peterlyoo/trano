import AppKit
import SwiftUI
import SwiftTerm
import XCTest
import TerminalCore
@testable import TranoApp

final class SettingsTerminologyNativeTests: XCTestCase {
    @MainActor func testThemePreviewUsesSelectedSmoothingAndTracksSubsequentChanges() async throws {
        let application = ThemePreferences().application(for: .dark, legacy: TerminalSettings())
        let host = NSHostingView(rootView: ThemeTerminalPreview(application: application, fontSmoothing: true))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 150)
        host.layoutSubtreeIfNeeded()
        let view = try await terminal(in: host)
        XCTAssertNil(host.window)
        XCTAssertTrue(view.fontSmoothing)
        let before = view.terminalInputStateSnapshot()
        host.rootView = ThemeTerminalPreview(application: application, fontSmoothing: false)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(view.fontSmoothing)
        host.rootView = ThemeTerminalPreview(application: application, fontSmoothing: true)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(view.fontSmoothing)
        XCTAssertEqual(view.terminalInputStateSnapshot()?.mouseMode, before?.mouseMode)
        XCTAssertEqual(view.terminalInputStateSnapshot()?.bracketedPasteMode, before?.bracketedPasteMode)
        view.removeFromSuperview()
    }

    @MainActor func testPaletteEditorPreviewUsesSelectedSmoothingWithoutSaving() async throws {
        let legacy = TerminalSettings(); let preferences = ThemePreferences()
        let palette = try XCTUnwrap(preferences.palette(id: preferences.darkThemeID, legacy: legacy))
        let host = NSHostingView(rootView: ThemePaletteEditor(palette: palette, legacy: legacy, fontSmoothing: true,
                                                            commit: { _ in XCTFail("Rendering persisted a theme") }))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 680)
        host.layoutSubtreeIfNeeded()
        let view = try await terminal(in: host)
        XCTAssertNil(host.window); XCTAssertTrue(view.fontSmoothing)
        view.removeFromSuperview()
    }

    @MainActor func testSelectedSmoothingReachesExistingTerminalRendererWithoutChangingFontOrModes() throws {
        let view = SwiftTerm.TerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 150))
        var legacy = TerminalSettings(); legacy.fontName = "Menlo-Regular"; legacy.fontSize = 17
        var preferences = TerminalPreferences(); preferences.fontSmoothing = false
        _ = try TerminalPreferenceRenderer.apply(preferences, legacy: legacy, profileAssigned: false, reduceMotion: true, to: view)
        let dimensions = view.terminalInputStateSnapshot()?.dimensions
        let input = view.terminalInputStateSnapshot()
        XCTAssertFalse(view.fontSmoothing)
        preferences.fontSmoothing = true
        _ = try TerminalPreferenceRenderer.apply(preferences, legacy: legacy, profileAssigned: false, reduceMotion: true, to: view)
        XCTAssertTrue(view.fontSmoothing)
        XCTAssertEqual(view.font.fontName, "Menlo-Regular"); XCTAssertEqual(view.font.pointSize, 17)
        XCTAssertEqual(view.terminalInputStateSnapshot()?.dimensions, dimensions)
        XCTAssertEqual(view.terminalInputStateSnapshot()?.mouseMode, input?.mouseMode)
        XCTAssertEqual(view.terminalInputStateSnapshot()?.bracketedPasteMode, input?.bracketedPasteMode)
        preferences.fontSmoothing = false
        _ = try TerminalPreferenceRenderer.apply(preferences, legacy: legacy, profileAssigned: false, reduceMotion: true, to: view)
        XCTAssertFalse(view.fontSmoothing)
    }

    @MainActor func testNotificationFormLaysOutAllGroupsWithoutAuthorizationOrDelivery() {
        var preferences = NotificationPreferences(); var master = true
        let host = NSHostingView(rootView: NotificationSettingsView(
            preferences: Binding(get: { preferences }, set: { preferences = $0 }),
            deliveryEnabled: Binding(get: { master }, set: { master = $0 }), expandedControls: true,
            authorize: { XCTFail("Rendering requested OS notification authorization") }))
        host.frame = NSRect(x: 0, y: 0, width: 632, height: 430)
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(host.window); XCTAssertGreaterThan(host.fittingSize.width, 0); XCTAssertGreaterThan(host.fittingSize.height, 0)
        XCTAssertTrue(master); XCTAssertEqual(preferences, NotificationPreferences())
    }

    @MainActor private func terminal(in host: NSView) async throws -> SwiftTerm.TerminalView {
        func find(_ view: NSView) -> SwiftTerm.TerminalView? {
            if let terminal = view as? SwiftTerm.TerminalView { return terminal }
            return view.subviews.lazy.compactMap(find).first
        }
        for _ in 0..<20 {
            if let value = find(host) { return value }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(find(host))
    }
}
