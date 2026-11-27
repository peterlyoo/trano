import AppKit
import XCTest
import TerminalCore
@testable import TranoApp

final class PessimisticTwinNativeButtonTests: XCTestCase {
    // Implements: FR-TWIN-1, FR-TWIN-6, FR-TWIN-8
    func testNativeMenuOffersExactlyThreeModesAndRetainsActions() async {
        await MainActor.run {
            let fixture = PessimisticTwinButtonFixture(); var selected: [TwinReviewMode] = []
            fixture.button.enable = { selected.append($0) }
            fixture.button.performClick(nil)
            XCTAssertEqual(fixture.menu?.items.map(\.title), ["Code Review", "Security Review", "General Review"])
            fixture.menu?.performActionForItem(at: 1)
            XCTAssertEqual(selected, [.securityReview])
        }
    }
    func testStopTargetsTheCapturedRunAndActiveModeCannotBeReplaced() async {
        await MainActor.run {
            let fixture = PessimisticTwinButtonFixture(); let run = pessimisticTwinControlRun(phase: .needsReview)
            fixture.button.run = run
            fixture.target = .init(paneID: "pane", identity: ["g1"], canStart: true, activeRunID: run.id)
            fixture.button.menuTarget = fixture.target
            var stopped: [String] = []; fixture.button.stop = { stopped.append($0) }
            fixture.button.performClick(nil)
            XCTAssertEqual(fixture.menu?.items.last?.title, "Stop Twin")
            XCTAssertEqual(fixture.menu?.items.first?.state, .on)
            XCTAssertFalse(fixture.menu?.items.first?.isEnabled ?? true)
            if let menu = fixture.menu { menu.performActionForItem(at: menu.items.count - 1) }
            XCTAssertEqual(stopped, [run.id])
        }
    }
    func testChangedSessionWhileMenuIsOpenRejectsAction() async {
        await MainActor.run {
            let fixture = PessimisticTwinButtonFixture(); var chosen = false
            fixture.button.enable = { _ in chosen = true }
            fixture.button.performClick(nil)
            fixture.target = .init(paneID: "pane", identity: ["g2"], canStart: true, activeRunID: nil)
            fixture.menu?.performActionForItem(at: 0)
            XCTAssertFalse(chosen)
            XCTAssertNotNil(fixture.menu)
        }
    }
    func testCallbackSurvivesButtonRedrawAndUsesUpdatedAction() async {
        await MainActor.run {
            let fixture = PessimisticTwinButtonFixture(); var chosen: [String] = []
            fixture.button.enable = { _ in chosen.append("old") }
            fixture.button.performClick(nil)
            fixture.button.enable = { _ in chosen.append("new") }
            fixture.button.needsDisplay = true
            fixture.menu?.performActionForItem(at: 0)
            XCTAssertEqual(chosen, ["new"])
        }
    }
    func testCommandPaletteRequestOpensTheSameNativeMenuOnceAndConsumesIt() async {
        await MainActor.run {
            let fixture = PessimisticTwinButtonFixture(); var deferred: [() -> Void] = [], pending = true, consumed = 0
            fixture.button.schedule = { deferred.append($0) }
            fixture.button.requestPresentation(isCurrent: { pending }, consume: { pending = false; consumed += 1 })
            fixture.button.requestPresentation(isCurrent: { pending }, consume: { pending = false; consumed += 1 })
            XCTAssertEqual(deferred.count, 1)
            deferred.forEach { $0() }
            XCTAssertEqual(consumed, 1)
            XCTAssertEqual(fixture.presentationCount, 1)
            XCTAssertEqual(fixture.menu?.items.map(\.title), ["Code Review", "Security Review", "General Review"])
        }
    }
    func testDirectClickConsumesPendingPaletteRequestWithoutOpeningAgain() async {
        await MainActor.run {
            let fixture = PessimisticTwinButtonFixture(); var deferred: [() -> Void] = [], pending = true, consumed = 0
            fixture.button.schedule = { deferred.append($0) }
            fixture.button.requestPresentation(isCurrent: { pending }, consume: { pending = false; consumed += 1 })
            fixture.button.performClick(nil)
            XCTAssertEqual(consumed, 1)
            XCTAssertFalse(pending)
            XCTAssertEqual(fixture.presentationCount, 1)
            deferred.forEach { $0() }
            XCTAssertEqual(fixture.presentationCount, 1)
        }
    }
    func testDeferredRequestDoesNotFollowANewPaneOrCancelledPaletteRequest() async {
        await MainActor.run {
            let fixture = PessimisticTwinButtonFixture(); var deferred: [() -> Void] = [], pending = true, consumed = 0
            fixture.button.schedule = { deferred.append($0) }
            fixture.button.requestPresentation(isCurrent: { pending }, consume: { consumed += 1 })
            fixture.target = .init(paneID: "pane", identity: ["g2"], canStart: true, activeRunID: nil)
            deferred.forEach { $0() }
            XCTAssertEqual(fixture.presentationCount, 0)
            XCTAssertEqual(consumed, 1)
            deferred = []; fixture.button.menuTarget = fixture.target
            fixture.button.requestPresentation(isCurrent: { pending }, consume: { consumed += 1 })
            pending = false
            deferred.forEach { $0() }
            XCTAssertEqual(fixture.presentationCount, 0)
            XCTAssertEqual(consumed, 1)
        }
    }
    func testIMECompositionBlocksClickDeferredPresentationAndMenuCommit() async {
        await MainActor.run {
            let fixture = PessimisticTwinButtonFixture(); var chosen = false
            fixture.button.enable = { _ in chosen = true }
            fixture.button.performClick(nil)
            let menu = fixture.menu
            let editor = NSTextView(frame: .init(x: 0, y: 0, width: 30, height: 30))
            fixture.window.contentView?.addSubview(editor); fixture.window.makeFirstResponder(editor)
            editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(editor.hasMarkedText())
            menu?.performActionForItem(at: 0); XCTAssertFalse(chosen)
            fixture.button.performClick(nil); XCTAssertEqual(fixture.presentationCount, 1)
            fixture.button.schedule = { $0() }
            fixture.button.requestPresentation(isCurrent: { true }, consume: {})
            XCTAssertEqual(fixture.presentationCount, 1)
        }
    }
    func testDetachedOrIneligibleWindowNeverPresents() async {
        await MainActor.run {
            let fixture = PessimisticTwinButtonFixture()
            fixture.button.windowReady = { _ in false }
            fixture.button.performClick(nil); XCTAssertEqual(fixture.presentationCount, 0)
            fixture.button.windowReady = { _ in true }; fixture.button.removeFromSuperview()
            fixture.button.performClick(nil); XCTAssertEqual(fixture.presentationCount, 0)
        }
    }
}
@MainActor final class PessimisticTwinButtonFixture {
    let window: NSWindow
    let button: PessimisticTwinNativeButton
    var target = PessimisticTwinMenuTarget(paneID: "pane", identity: ["g1"], canStart: true, activeRunID: nil)
    var menu: NSMenu?
    var presentationCount = 0
    init() {
        _ = NSApplication.shared
        window = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        button = PessimisticTwinNativeButton(frame: .init(x: 0, y: 0, width: 22, height: 22))
        window.contentView?.addSubview(button)
        button.menuTarget = target
        button.currentTarget = { [weak self] in self?.target }
        button.menuPresenter = { [weak self] menu, _ in self?.menu = menu; self?.presentationCount += 1 }
        button.windowReady = { _ in true }
    }
}
