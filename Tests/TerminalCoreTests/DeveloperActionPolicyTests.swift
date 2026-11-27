import XCTest
@testable import TerminalCore

final class DeveloperActionPolicyTests: XCTestCase {
    // Implements: FR-SET-104
    func testQuickLookLeavesCompositionAndInputOverlaysAlone() {
        var preferences = DeveloperPreferences(); preferences.enabled = true; preferences.quickLookLinks = true
        XCTAssertTrue(DeveloperActionPolicy.mayPreviewLink(preferences: preferences, hasMarkedText: false, hasModal: false, inputBusy: false))
        XCTAssertFalse(DeveloperActionPolicy.mayPreviewLink(preferences: preferences, hasMarkedText: true, hasModal: false, inputBusy: false))
        XCTAssertFalse(DeveloperActionPolicy.mayPreviewLink(preferences: preferences, hasMarkedText: false, hasModal: true, inputBusy: false))
        XCTAssertFalse(DeveloperActionPolicy.mayPreviewLink(preferences: preferences, hasMarkedText: false, hasModal: false, inputBusy: true))
        preferences.quickLookLinks = false
        XCTAssertFalse(DeveloperActionPolicy.mayPreviewLink(preferences: preferences, hasMarkedText: false, hasModal: false, inputBusy: false))
    }

    // Implements: FR-SET-100
    func testAutomaticInstallWaitsUntilAppIsNotVisibleAndInputIsSafe() {
        var preferences = DeveloperPreferences(); preferences.installUpdatesAutomatically = true
        XCTAssertFalse(DeveloperActionPolicy.mayInstallUpdate(preferences: preferences, appHidden: false, visibleWindowCount: 1, inputBusy: false))
        XCTAssertTrue(DeveloperActionPolicy.mayInstallUpdate(preferences: preferences, appHidden: true, visibleWindowCount: 1, inputBusy: false))
        XCTAssertTrue(DeveloperActionPolicy.mayInstallUpdate(preferences: preferences, appHidden: false, visibleWindowCount: 0, inputBusy: false))
        XCTAssertFalse(DeveloperActionPolicy.mayInstallUpdate(preferences: preferences, appHidden: true, visibleWindowCount: 0, inputBusy: true))
        preferences.installUpdatesAutomatically = false
        XCTAssertFalse(DeveloperActionPolicy.mayInstallUpdate(preferences: preferences, appHidden: true, visibleWindowCount: 0, inputBusy: false))
    }
}
