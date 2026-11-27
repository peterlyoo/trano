import AppKit
import XCTest
import TerminalCore
@testable import TranoApp

@MainActor final class AsyncTerminalLinksTests: XCTestCase {
    @MainActor private final class Prompt: TerminalApplicationLinkPromptPresenting {
        var reply: ((NSApplication.ModalResponse) -> Void)?
        var cancelCount = 0
        func present(_ alert: NSAlert, in window: NSWindow, completion: @escaping (NSApplication.ModalResponse) -> Void) -> () -> Void { reply = completion; return { self.cancelCount += 1 } }
    }
    // Implements: FR-SET-93, FR-SET-94
    func testAlwaysWaitsForAsynchronousSuccessfulSaveBeforeOpening() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 200), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let owner = TerminalInteractionOwner(paneID: "pane", windowID: ObjectIdentifier(window), generation: UUID())
        var preferences = TerminalPreferences()
        var savedRule: TerminalTrustedLink?
        var savedReply: TerminalTrustedRuleSaveCompletion?
        var opened: [URL] = []
        let prompt = Prompt()
        let handler = TerminalApplicationLinkHandler(preferences: { preferences }, owner: { owner }, opener: { opened.append($0) }, presentPrompt: prompt, saveTrustedRule: { rule, enabled, captured, reply in
            XCTAssertTrue(enabled); XCTAssertEqual(captured, owner); savedRule = rule; savedReply = reply
        })
        let url = URL(string: "demo://host.example:9443/path")!
        handler.requestOpen(url, in: window)
        try XCTUnwrap(prompt.reply)(.alertSecondButtonReturn)
        XCTAssertTrue(opened.isEmpty, "A queued trust save cannot open an application yet")
        let rule = try XCTUnwrap(savedRule)
        XCTAssertEqual(rule, TerminalTrustedLink(scheme: "demo", host: "host.example", port: 9443))
        preferences.trustedLinks.append(rule)
        try XCTUnwrap(savedReply)(.success(()))
        XCTAssertEqual(opened, [url])
        try XCTUnwrap(savedReply)(.success(()))
        XCTAssertEqual(opened.count, 1)
    }
    // Implements: FR-SET-93, FR-SET-94
    func testDelayedTrustFailureCancellationOwnerAndPolicyChangesNeverOpen() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 200), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        for mutation in 0..<4 {
            var owner: TerminalInteractionOwner? = .init(paneID: "pane", windowID: ObjectIdentifier(window), generation: UUID())
            var preferences = TerminalPreferences()
            var savedReply: TerminalTrustedRuleSaveCompletion?
            let prompt = Prompt()
            let handler = TerminalApplicationLinkHandler(preferences: { preferences }, owner: { owner }, opener: { _ in XCTFail("Canceled/failed save must not open") }, presentPrompt: prompt, saveTrustedRule: { _, _, _, reply in savedReply = reply })
            handler.requestOpen(URL(string: "demo://host.example/")!, in: window)
            try XCTUnwrap(prompt.reply)(.alertSecondButtonReturn)
            switch mutation {
            case 0: try XCTUnwrap(savedReply)(.failure(TerminalError.invalid("save failed")))
            case 1: owner = nil; try XCTUnwrap(savedReply)(.success(()))
            case 2: preferences.applicationLinks = .never; try XCTUnwrap(savedReply)(.success(()))
            default: handler.cancelPending(); try XCTUnwrap(savedReply)(.success(()))
            }
        }
    }
}
