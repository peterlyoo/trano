import Foundation
import Darwin
import XCTest
@testable import TerminalCore

final class PessimisticTwinSourceExpectationTests: XCTestCase {
    // Implements: FR-TWIN-1, FR-TWIN-3.
    func testExactCapturedIdentityMatchesCurrentSource() {
        let source = source()
        let expected = expectation(source)
        XCTAssertTrue(expected.matches(source))
        func acceptsSendable<T: Sendable>(_ value: T) {}
        acceptsSendable(expected)
    }

    func testNewGenerationDoesNotReuseAnOldActivationRequest() {
        XCTAssertFalse(expectation(source()).matches(source(generation: "replacement-generation")))
    }

    func testNewConversationInSameGenerationIsRejected() {
        XCTAssertFalse(expectation(source()).matches(source(conversation: "replacement-conversation")))
    }

    func testChangedWorkingDirectoryIsRejected() {
        XCTAssertFalse(expectation(source()).matches(source(cwd: "/different-project")))
    }

    private func expectation(_ source: TwinSourceBinding) -> TwinSourceExpectation {
        TwinSourceExpectation(generation: source.generation, conversationID: source.conversationID, cwd: source.cwd)
    }
    private func source(generation: String = "captured-generation", conversation: String = "captured-conversation", cwd: String = "/captured-project") -> TwinSourceBinding {
        TwinSourceBinding(paneID: "pane", generation: generation, conversationID: conversation, cwd: cwd, configurationRoot: "/account-profile", provider: .codex,
            accountID: "same-account", backendPID: 100, providerPID: 101,
            backendIdentity: .init(pid: 100, ownerUID: getuid(), startedAtSeconds: 1, startedAtMicroseconds: 1),
            providerIdentity: .init(pid: 101, ownerUID: getuid(), startedAtSeconds: 2, startedAtMicroseconds: 1))
    }
}
