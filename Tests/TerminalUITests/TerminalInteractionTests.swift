import AppKit
import XCTest
import TerminalCore
@testable import TranoApp

@MainActor
final class TerminalInteractionTests: XCTestCase {
    @MainActor private final class Fixture {
        let window: NSWindow
        var owner: TerminalInteractionOwner?
        var preferences = TerminalPreferences()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.trano.interaction-tests." + UUID().uuidString))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        init() {
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            owner = TerminalInteractionOwner(paneID: "pane-one", windowID: ObjectIdentifier(window), generation: UUID())
        }
        func rebind() { owner = TerminalInteractionOwner(paneID: "pane-two", windowID: ObjectIdentifier(window), generation: UUID()) }
    }
    @MainActor private final class Prompt: TerminalApplicationLinkPromptPresenting {
        var alerts: [NSAlert] = []
        var completions: [(NSApplication.ModalResponse) -> Void] = []
        var cancellations = 0
        func present(_ alert: NSAlert, in window: NSWindow, completion: @escaping (NSApplication.ModalResponse) -> Void) -> () -> Void {
            alerts.append(alert); completions.append(completion)
            return { [weak self] in self?.cancellations += 1 }
        }
    }
    private func linkHandler(_ fixture: Fixture, prompt: Prompt, opened: @escaping (URL) -> Void,
                             write: ((TerminalTrustedLink, Bool, TerminalInteractionOwner) throws -> Void)? = nil) -> TerminalApplicationLinkHandler {
        TerminalApplicationLinkHandler(preferences: { fixture.preferences }, owner: { fixture.owner }, opener: opened, presentPrompt: prompt, setTrustedRule: write ?? { rule, enabled, _ in
            fixture.preferences.trustedLinks.removeAll { $0 == rule }
            if enabled { fixture.preferences.trustedLinks.append(rule) }
        })
    }
    private func choose(_ item: NSMenuItem) throws {
        let action = try XCTUnwrap(item.action)
        let target = try XCTUnwrap(item.target)
        XCTAssertTrue(NSApp.sendAction(action, to: target, from: item))
    }

    // Implements: FR-SET-88, FR-SET-89
    func testSelectionCopiesOnlyCompletedUserIntentWithoutDragBurstsOrRedundantWrites() throws {
        let fixture = Fixture()
        let controller = TerminalSelectionController(pasteboard: fixture.pasteboard, preferences: { fixture.preferences }, owner: { fixture.owner })
        XCTAssertFalse(controller.selectionChanged(text: "hello", intent: .userCompleted, isComposing: false, hostView: fixture.host))
        fixture.preferences.copyOnSelection = true
        let originalCount = fixture.pasteboard.changeCount
        for index in 0..<100 { XCTAssertFalse(controller.selectionChanged(text: "drag-\(index)", intent: .dragging, isComposing: false, hostView: fixture.host)) }
        XCTAssertEqual(fixture.pasteboard.changeCount, originalCount)
        let text = "한글 NFC/NFD e\u{301}; 'path'\n"
        XCTAssertTrue(controller.selectionChanged(text: text, intent: .userCompleted, isComposing: false, hostView: fixture.host))
        XCTAssertTrue(try XCTUnwrap(fixture.pasteboard.string(forType: .string)).utf8.elementsEqual(text.utf8))
        let copiedCount = fixture.pasteboard.changeCount
        XCTAssertFalse(controller.selectionChanged(text: text, intent: .userCompleted, isComposing: false, hostView: fixture.host))
        XCTAssertEqual(fixture.pasteboard.changeCount, copiedCount)
        XCTAssertFalse(controller.selectionChanged(text: "programmatic", intent: .programmatic, isComposing: false, hostView: fixture.host))
        XCTAssertFalse(controller.selectionChanged(text: "preedit", intent: .userCompleted, isComposing: true, hostView: fixture.host))
        fixture.preferences.copyOnSelection = false
        XCTAssertTrue(controller.copy(text: "explicit", isComposing: false, hostView: fixture.host))
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "explicit")
        XCTAssertFalse(controller.copy(text: "", isComposing: false, hostView: fixture.host))
    }
    // Implements: FR-SET-88
    func testCopyRevalidatesOwnerAndPreservesDistinctUTF8Selections() throws {
        let fixture = Fixture()
        fixture.preferences.copyOnSelection = true
        let controller = TerminalSelectionController(pasteboard: fixture.pasteboard, preferences: { fixture.preferences }, owner: { fixture.owner })
        let nfc = "/한글"
        let nfd = nfc.decomposedStringWithCanonicalMapping
        XCTAssertTrue(controller.copy(text: nfc, isComposing: false, hostView: fixture.host))
        XCTAssertTrue(controller.copy(text: nfd, isComposing: false, hostView: fixture.host))
        XCTAssertTrue(try XCTUnwrap(fixture.pasteboard.string(forType: .string)).utf8.elementsEqual(nfd.utf8))
        fixture.owner = nil
        XCTAssertFalse(controller.copy(text: "stale", isComposing: false, hostView: fixture.host))
        let guarded = TerminalSelectionController(pasteboard: fixture.pasteboard, preferences: {
            fixture.owner = nil
            return fixture.preferences
        }, owner: { fixture.owner })
        fixture.rebind()
        XCTAssertFalse(guarded.copy(text: "changed-during-preference-read", isComposing: false, hostView: fixture.host))
        XCTAssertTrue(try XCTUnwrap(fixture.pasteboard.string(forType: .string)).utf8.elementsEqual(nfd.utf8))
    }
    // Implements: FR-SET-89
    func testCopyFeedbackIsNativeTemporaryNoninteractiveAndRespectsReduceMotion() throws {
        let fixture = Fixture()
        var reduceMotion = false
        var scheduled: [TerminalCopyFeedbackExpiration] = []
        let feedback = TerminalCopyFeedback(reduceMotion: { reduceMotion }, schedule: { _, action in scheduled.append(action) })
        fixture.preferences.animateCopy = true
        let controller = TerminalSelectionController(pasteboard: fixture.pasteboard, preferences: { fixture.preferences }, owner: { fixture.owner }, feedback: feedback)
        XCTAssertTrue(controller.copy(text: "copied", isComposing: false, hostView: fixture.host))
        let overlay = try XCTUnwrap(feedback.feedbackView)
        XCTAssertTrue(overlay.superview === fixture.host)
        XCTAssertTrue(feedback.usesAnimation)
        XCTAssertNil(overlay.hitTest(NSPoint(x: 10, y: 10)))
        XCTAssertTrue(overlay.subviews.contains { ($0 as? NSTextField)?.stringValue == "Copied" })
        feedback.show(in: fixture.host)
        let newer = try XCTUnwrap(feedback.feedbackView)
        try XCTUnwrap(scheduled.first)()
        XCTAssertTrue(newer.superview === fixture.host, "Old expiry cannot hide a newer copy confirmation")
        reduceMotion = true
        feedback.show(in: fixture.host)
        XCTAssertFalse(feedback.usesAnimation)
        try XCTUnwrap(scheduled.last)()
        XCTAssertNil(feedback.feedbackView)
        feedback.show(in: fixture.host)
        fixture.preferences.animateCopy = false
        controller.preferencesDidChange()
        XCTAssertNil(feedback.feedbackView, "Disabling the animation removes current feedback immediately")
        XCTAssertTrue(controller.copy(text: "quiet", isComposing: false, hostView: fixture.host))
        XCTAssertNil(feedback.feedbackView)
        controller.ownerDidChange()
    }
    // Implements: FR-SET-93
    func testWebLinksOpenAndDangerousSchemesStayDeniedWithoutPrompting() {
        let fixture = Fixture()
        fixture.preferences.applicationLinks = .never
        let prompt = Prompt()
        var opened: [URL] = []
        let handler = linkHandler(fixture, prompt: prompt) { opened.append($0) }
        for value in ["https://example.test/path", "http://example.test:8080/"] { handler.requestOpen(URL(string: value)!, in: fixture.window) }
        for value in ["javascript:alert(1)", "data:text/plain,hello", "about:blank", "blob:https://example.test/id", "vbscript:evil", "custom://example.test/"] { handler.requestOpen(URL(string: value)!, in: fixture.window) }
        XCTAssertEqual(opened.count, 2)
        XCTAssertTrue(prompt.alerts.isEmpty)
        fixture.owner = nil
        handler.requestOpen(URL(string: "https://example.test/blocked")!, in: fixture.window)
        XCTAssertEqual(opened.count, 2)
    }
    // Implements: FR-SET-93, FR-SET-94
    func testAskBuildsNativeAlertAndAlwaysOpenRemembersExactOriginWithoutCredentials() throws {
        let fixture = Fixture()
        let prompt = Prompt()
        var opened: [URL] = []
        let handler = linkHandler(fixture, prompt: prompt) { opened.append($0) }
        let url = try XCTUnwrap(URL(string: "demo://username:password@Host.Example:9443/private?q=secret"))
        handler.requestOpen(url, in: fixture.window)
        let alert = try XCTUnwrap(prompt.alerts.last)
        XCTAssertEqual(alert.buttons.map(\.title), ["Open", "Always Open", "Cancel"])
        XCTAssertFalse(alert.informativeText.contains("password"))
        XCTAssertTrue(opened.isEmpty)
        try XCTUnwrap(prompt.completions.last)(.alertSecondButtonReturn)
        XCTAssertEqual(opened, [url])
        XCTAssertEqual(fixture.preferences.trustedLinks, [TerminalTrustedLink(scheme: "demo", host: "host.example", port: 9443)])
        handler.requestOpen(URL(string: "demo://host.example:9443/different-path")!, in: fixture.window)
        XCTAssertEqual(opened.count, 2)
        XCTAssertEqual(prompt.alerts.count, 1)
        handler.requestOpen(URL(string: "demo://sub.host.example:9443/path")!, in: fixture.window)
        XCTAssertEqual(prompt.alerts.count, 2)
        handler.cancelPending()
        handler.requestOpen(URL(string: "demo://host.example:9444/path")!, in: fixture.window)
        XCTAssertEqual(prompt.alerts.count, 3)
    }
    // Implements: FR-SET-93, FR-SET-94
    func testOutstandingAppLinkCancelsForOwnerOrPolicyChangesAndTrustCanBeRevoked() throws {
        let fixture = Fixture()
        let prompt = Prompt()
        var opened: [URL] = []
        let handler = linkHandler(fixture, prompt: prompt) { opened.append($0) }
        let url = URL(string: "demo://host.example:9443/path")!
        handler.requestOpen(url, in: fixture.window)
        let staleReply = try XCTUnwrap(prompt.completions.last)
        fixture.rebind()
        handler.cancelIfOwnerChanged()
        XCTAssertEqual(prompt.cancellations, 1)
        staleReply(.alertFirstButtonReturn)
        XCTAssertTrue(opened.isEmpty)
        handler.requestOpen(url, in: fixture.window)
        fixture.preferences.applicationLinks = .never
        try XCTUnwrap(prompt.completions.last)(.alertSecondButtonReturn)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertTrue(fixture.preferences.trustedLinks.isEmpty)
        fixture.preferences.applicationLinks = .ask
        handler.requestOpen(url, in: fixture.window)
        try XCTUnwrap(prompt.completions.last)(.alertSecondButtonReturn)
        let rule = try XCTUnwrap(fixture.preferences.trustedLinks.first)
        XCTAssertTrue(handler.revoke(rule))
        XCTAssertTrue(fixture.preferences.trustedLinks.isEmpty)
        handler.requestOpen(url, in: fixture.window)
        XCTAssertEqual(prompt.alerts.count, 4)
        try XCTUnwrap(prompt.completions.last)(.alertThirdButtonReturn)
        XCTAssertEqual(opened.count, 1)
    }
    @MainActor private final class WeakPrompt: TerminalApplicationLinkPromptPresenting {
        weak var alert: NSAlert?
        var completion: ((NSApplication.ModalResponse) -> Void)?
        func present(_ alert: NSAlert, in window: NSWindow, completion: @escaping (NSApplication.ModalResponse) -> Void) -> () -> Void {
            self.alert = alert
            self.completion = completion
            return {}
        }
    }
    // Implements: FR-SET-93
    func testPendingAlertIsRetainedWithoutRelyingOnPresenterOwnership() {
        let fixture = Fixture()
        let presenter = WeakPrompt()
        let handler = TerminalApplicationLinkHandler(preferences: { fixture.preferences }, owner: { fixture.owner }, opener: { _ in XCTFail("No link approval") }, presentPrompt: presenter, setTrustedRule: { _, _, _ in XCTFail("No trust write") })
        autoreleasepool { handler.requestOpen(URL(string: "demo://host.example/path")!, in: fixture.window) }
        XCTAssertNotNil(presenter.alert, "Native alert must survive the request stack until response/cancellation")
        handler.cancelPending()
        XCTAssertNil(presenter.alert)
    }
    // Implements: FR-SET-93
    func testDirectOpenCannotBypassNewAskPolicyDuringFinalRecheck() {
        let fixture = Fixture()
        let prompt = Prompt()
        var opened: [URL] = []
        var reads = 0
        let handler = TerminalApplicationLinkHandler(preferences: {
            reads += 1
            var preferences = fixture.preferences
            preferences.applicationLinks = reads == 1 ? .always : .ask
            return preferences
        }, owner: { fixture.owner }, opener: { opened.append($0) }, presentPrompt: prompt, setTrustedRule: { _, _, _ in XCTFail("No trust write") })
        handler.requestOpen(URL(string: "demo://host.example/path")!, in: fixture.window)
        XCTAssertTrue(opened.isEmpty, "A new Ask policy requires fresh user approval")
    }
    // Implements: FR-SET-93, FR-SET-94
    func testOpenOnceNeverRemembersAndFailedAlwaysPersistenceDoesNotOpen() throws {
        let fixture = Fixture()
        let prompt = Prompt()
        var opened: [URL] = []
        let handler = linkHandler(fixture, prompt: prompt) { opened.append($0) }
        let url = URL(string: "demo://host.example/path")!
        handler.requestOpen(url, in: fixture.window)
        try XCTUnwrap(prompt.completions.last)(.alertFirstButtonReturn)
        XCTAssertEqual(opened, [url])
        XCTAssertTrue(fixture.preferences.trustedLinks.isEmpty)
        handler.requestOpen(url, in: fixture.window)
        XCTAssertEqual(prompt.alerts.count, 2)
        handler.cancelPending()
        let failed = linkHandler(fixture, prompt: prompt, opened: { _ in XCTFail("Failed trust save cannot open") }, write: { _, _, _ in throw TerminalError.invalid("test write failure") })
        failed.requestOpen(url, in: fixture.window)
        try XCTUnwrap(prompt.completions.last)(.alertSecondButtonReturn)
        XCTAssertTrue(fixture.preferences.trustedLinks.isEmpty)
    }
    // Implements: FR-SET-93
    func testAppLinkRechecksOwnerAfterTrustPersistenceAndBeforeOpener() throws {
        let fixture = Fixture()
        let prompt = Prompt()
        var opened: [URL] = []
        let handler = linkHandler(fixture, prompt: prompt, opened: { opened.append($0) }, write: { _, _, _ in fixture.owner = nil })
        handler.requestOpen(URL(string: "demo://host.example/")!, in: fixture.window)
        try XCTUnwrap(prompt.completions.last)(.alertSecondButtonReturn)
        XCTAssertTrue(opened.isEmpty)
    }
    // Implements: FR-SET-95
    func testRecentPathAccessoryPreservesExactBytesOrderHostAndNativeActionsAcrossRedraw() throws {
        let fixture = Fixture()
        var history = TerminalPathHistory()
        let nfc = "/한글 dir/quote';"
        let nfd = nfc.decomposedStringWithCanonicalMapping
        try history.record(nfc, at: Date(timeIntervalSince1970: 1))
        try history.record(nfd, at: Date(timeIntervalSince1970: 2))
        try history.record("/remote path", hostID: "host-A", at: Date(timeIntervalSince1970: 3))
        var chosen: [TerminalRecentPath] = []
        let accessory = TerminalRecentPathAccessory(owner: { fixture.owner }, onChoose: { chosen.append($0) })
        accessory.update(history: history, hostID: nil, enabled: true)
        let items = Array(try XCTUnwrap(accessory.popupButton.menu).items.dropFirst())
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(try XCTUnwrap(items.first).title.utf8.elementsEqual(nfd.utf8))
        XCTAssertTrue(try XCTUnwrap(items.last).title.utf8.elementsEqual(nfc.utf8))
        let frozen = try XCTUnwrap(items.first)
        try history.record("/new", at: Date(timeIntervalSince1970: 4))
        accessory.update(history: history, hostID: nil, enabled: true)
        accessory.updateCallbacks(owner: { fixture.owner }, onChoose: { chosen.append($0) })
        try choose(frozen)
        XCTAssertTrue(try XCTUnwrap(chosen.last).path.utf8.elementsEqual(nfd.utf8))
        accessory.update(history: history, hostID: "host-A", enabled: true)
        let remote = try XCTUnwrap(accessory.popupButton.menu?.items.last)
        XCTAssertEqual(remote.title, "/remote path")
        try choose(remote)
        XCTAssertEqual(chosen.last?.hostID, "host-A")
        fixture.rebind()
        try choose(remote)
        XCTAssertEqual(chosen.count, 2)
    }
    // Implements: FR-SET-95
    func testRecentPathToggleAddsAndRemovesNativePanelAccessoryWithoutShowingPanel() throws {
        let fixture = Fixture()
        var history = TerminalPathHistory()
        try history.record("/temporary-local", at: Date(timeIntervalSince1970: 1))
        let accessory = TerminalRecentPathAccessory(owner: { fixture.owner }, onChoose: { _ in XCTFail("Hidden accessory cannot choose") })
        let panel = NSOpenPanel()
        accessory.update(history: history, hostID: nil, enabled: true)
        accessory.attach(to: panel)
        XCTAssertTrue(panel.accessoryView === accessory)
        XCTAssertFalse(accessory.isHidden)
        XCTAssertTrue(accessory.bounds.contains(accessory.popupButton.frame))
        let stale = try XCTUnwrap(accessory.popupButton.menu?.items.last)
        accessory.update(history: history, hostID: nil, enabled: false)
        XCTAssertNil(panel.accessoryView)
        XCTAssertTrue(accessory.isHidden)
        try choose(stale)
        accessory.update(history: history, hostID: "other-host", enabled: true)
        XCTAssertNil(panel.accessoryView)
    }
}
