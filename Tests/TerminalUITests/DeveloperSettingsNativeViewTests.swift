import AppKit
import XCTest
@testable import TranoApp
import TerminalCore

final class DeveloperSettingsNativeViewTests: XCTestCase {
    @MainActor private final class EditorFixture: NSTextView {
        var composing = false
        override func hasMarkedText() -> Bool { composing }
    }

    @MainActor func testOriginRemovalFollowsOriginIdentityAcrossReordering() throws {
        let view = DeveloperSettingsNativeView(frame: .zero)
        var preferences = DeveloperPreferences(); preferences.enabled = true
        let one = "https://one.example", two = "https://two.example"
        view.configure(preferences: preferences, readiness: unavailable(), metadata: nil, installationStatus: "Checking", localAPIURL: "unix:///tmp/api.sock", origins: [one, two])
        let removeOne = try XCTUnwrap(find("developer.origin.remove.0", in: view) as? NSButton)
        let rowOne = removeOne.superview
        view.configure(preferences: preferences, readiness: unavailable(), metadata: nil, installationStatus: "Ready", localAPIURL: "unix:///tmp/api.sock", origins: [two, one])
        XCTAssertTrue(find("developer.origin.remove.1", in: view) === removeOne)
        XCTAssertTrue(removeOne.superview === rowOne)
        var changed: [String]?; view.onOriginsChange = { changed = $0 }
        removeOne.performClick(nil)
        XCTAssertEqual(changed, [two])
    }

    @MainActor func testOriginCompositionAndSourceSelectionSurviveStatusRefresh() throws {
        let view = DeveloperSettingsNativeView(frame: .zero)
        var preferences = DeveloperPreferences(); preferences.enabled = true; preferences.installationLocation = .sourceCheckout; preferences.sourceDirectory = "/tmp/old-source"
        view.configure(preferences: preferences, readiness: unavailable(), metadata: nil, installationStatus: "Checking", localAPIURL: "unix:///tmp/api.sock", origins: [])
        let origin = try XCTUnwrap(find("developer.origin.pattern", in: view) as? DeveloperSettingsTextField)
        let source = try XCTUnwrap(find("developer.source.path", in: view) as? DeveloperSettingsTextField)
        let originEditor = EditorFixture(frame: .zero); originEditor.string = "https://한"; originEditor.composing = true; originEditor.setSelectedRange(NSRange(location: 8, length: 1))
        origin.stringValue = "https://prior.example"; origin.editorProvider = { originEditor }
        let sourceEditor = EditorFixture(frame: .zero); sourceEditor.string = source.stringValue; sourceEditor.setSelectedRange(NSRange(location: 5, length: 3)); source.editorProvider = { sourceEditor }
        preferences.sourceDirectory = "/tmp/new-source"
        view.configure(preferences: preferences, readiness: unavailable(), metadata: nil, installationStatus: "Ready", localAPIURL: "unix:///tmp/api.sock", origins: [])
        XCTAssertTrue(find("developer.origin.pattern", in: view) === origin)
        XCTAssertTrue(find("developer.source.path", in: view) === source)
        XCTAssertEqual(source.stringValue, "/tmp/old-source")
        XCTAssertEqual(sourceEditor.selectedRange(), NSRange(location: 5, length: 3))
        XCTAssertEqual(originEditor.string, "https://한")
        var changed: [String]?; view.onOriginsChange = { changed = $0 }
        let add = try XCTUnwrap(find("developer.origin.add", in: view) as? NSButton)
        add.performClick(nil); XCTAssertNil(changed)
        originEditor.composing = false; originEditor.string = "https://composed.example"
        add.performClick(nil)
        XCTAssertEqual(changed, ["https://composed.example"])
    }

    // Implements: FR-SET-98, FR-SET-107, FR-SET-110, FR-SET-111, FR-SET-112, FR-SET-113
    @MainActor func testLongMetadataControlsStayWithinSettingsWidth() {
        let view = DeveloperSettingsNativeView(frame: NSRect(x: 0, y: 0, width: 580, height: 1100))
        var preferences = DeveloperPreferences(); preferences.enabled = true; preferences.installationLocation = .sourceCheckout
        preferences.sourceDirectory = "/tmp/" + String(repeating: "long-project-", count: 20)
        let metadata = DeveloperInstallationMetadata(executable: URL(fileURLWithPath: "/tmp/TranoApp"), version: "0.1.0", commit: String(repeating: "a", count: 40), finalSHA256: String(repeating: "b", count: 64), apiVersion: 1, buildID: String(repeating: "c", count: 64))
        view.configure(preferences: preferences, readiness: unavailable(), metadata: metadata, installationStatus: "Ready", localAPIURL: "unix:///tmp/" + String(repeating: "long-root-", count: 10) + "/api.sock", origins: ["https://" + String(repeating: "subdomain", count: 8) + ".example.com"])
        view.layoutSubtreeIfNeeded()
        func check(_ child: NSView) {
            if child.isHiddenOrHasHiddenAncestor { return }
            if child is NSControl {
                let bounds = view.convert(child.bounds, from: child)
                XCTAssertGreaterThanOrEqual(bounds.minX, -0.5, child.identifier?.rawValue ?? "control")
                XCTAssertLessThanOrEqual(bounds.maxX, view.bounds.maxX + 0.5, child.identifier?.rawValue ?? "control")
            }
            child.subviews.forEach(check)
        }
        check(view)
    }

    // Implements: FR-SET-98
    @MainActor func testMasterControlOwnsNativeActionAndHidesExperimentControls() throws {
        let view = DeveloperSettingsNativeView(frame: NSRect(x: 0, y: 0, width: 580, height: 900))
        let preferences = DeveloperPreferences()
        view.configure(preferences: preferences, readiness: unavailable(), metadata: nil, installationStatus: "Unavailable", localAPIURL: "unix:///tmp/trano/api.sock", origins: [])
        let master = try XCTUnwrap(find("developer.enabled", in: view) as? NSButton)
        let group = try XCTUnwrap(find("developer.options", in: view))
        XCTAssertTrue(group.isHidden)
        var changed: DeveloperPreferences?
        view.onChange = { changed = $0 }
        master.performClick(nil)
        XCTAssertEqual(changed?.enabled, true)
        var enabled = preferences; enabled.enabled = true
        view.configure(preferences: enabled, readiness: unavailable(), metadata: nil, installationStatus: "Unavailable", localAPIURL: "unix:///tmp/trano/api.sock", origins: [])
        XCTAssertFalse(group.isHidden)
    }

    // Implements: FR-SET-99, FR-SET-100, FR-SET-105, FR-SET-106, FR-SET-107, FR-SET-112
    @MainActor func testUnavailableUpdatesDisableTheirControlsButKeepSourceChooserAndLocalURL() throws {
        let view = DeveloperSettingsNativeView(frame: NSRect(x: 0, y: 0, width: 580, height: 900))
        var preferences = DeveloperPreferences(); preferences.enabled = true; preferences.installationLocation = .sourceCheckout; preferences.sourceDirectory = "/tmp/checkout"
        view.configure(preferences: preferences, readiness: unavailable(), metadata: nil, installationStatus: "Not built", localAPIURL: "unix:///tmp/trano/api.sock", origins: [])
        for id in ["developer.download", "developer.install", "developer.channel"] {
            XCTAssertEqual((find(id, in: view) as? NSControl)?.isEnabled, false)
        }
        let choose = try XCTUnwrap(find("developer.source.choose", in: view) as? NSButton)
        var invoked = false; view.onChooseSource = { invoked = true }; choose.performClick(nil)
        XCTAssertTrue(invoked)
        XCTAssertEqual((find("developer.api.url", in: view) as? NSTextField)?.stringValue, "unix:///tmp/trano/api.sock")
    }

    // Implements: FR-SET-113, FR-SET-114
    @MainActor func testOriginAddAndRemoveUseDraftCallbacksAndSurfaceValidationFailure() throws {
        let view = DeveloperSettingsNativeView(frame: NSRect(x: 0, y: 0, width: 580, height: 900))
        var preferences = DeveloperPreferences(); preferences.enabled = true
        view.configure(preferences: preferences, readiness: unavailable(), metadata: nil, installationStatus: "Unavailable", localAPIURL: "unix:///tmp/trano/api.sock", origins: ["https://example.com"])
        let field = try XCTUnwrap(find("developer.origin.pattern", in: view) as? NSTextField)
        let add = try XCTUnwrap(find("developer.origin.add", in: view) as? NSButton)
        var received: [String]?
        view.onOriginsChange = { received = $0 }
        field.stringValue = "https://*.example.com"; add.performClick(nil)
        XCTAssertEqual(received, ["https://example.com", "https://*.example.com"])
        view.configure(preferences: preferences, readiness: unavailable(), metadata: nil, installationStatus: "Unavailable", localAPIURL: "unix:///tmp/trano/api.sock", origins: received ?? [])
        let remove = try XCTUnwrap(find("developer.origin.remove.0", in: view) as? NSButton)
        remove.performClick(nil)
        XCTAssertEqual(received, ["https://*.example.com"])
        view.onOriginsChange = { _ in throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid origin"]) }
        field.stringValue = "*"; add.performClick(nil)
        XCTAssertEqual((find("developer.origin.error", in: view) as? NSTextField)?.stringValue, "Invalid origin")
    }

    private func unavailable() -> DeveloperUpdateReadiness {
        DeveloperUpdateReadiness(available: false, reason: "No signed update feed", automaticDownloads: false, immediateInstallation: false, channels: [])
    }
    @MainActor private func find(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { self.find(id, in: $0) }.first
    }
}
