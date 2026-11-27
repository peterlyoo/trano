import Foundation
import Darwin
import XCTest
@testable import TerminalCore

final class PessimisticTwinRestrictedStartupTests: XCTestCase {
    // Implements: FR-TWIN-3, FR-TWIN-4, FR-TWIN-5, FR-TWIN-7, FR-QUEUE-5.
    func testExactRestrictedNoticeSendsOneEnterOnlyAfterDurableReservation() throws {
        let f = try Fixture()
        XCTAssertTrue(TwinRestrictedStartup.matches(f.screen))
        XCTAssertTrue(try TwinRestrictedStartup.acknowledge(f.actions))
        XCTAssertEqual(f.events, ["capture", "reserve", "save", "enter", "save"])
        XCTAssertEqual(f.enters, 1)
        XCTAssertTrue(f.observation.acknowledged)
        XCTAssertFalse(try TwinRestrictedStartup.acknowledge(f.actions))
        XCTAssertEqual(f.enters, 1)
    }

    func testPaneGenerationBackendProfileExecutableAndAccountMismatchNeverWrites() throws {
        let changes: [(inout TwinRestrictedStartupTarget) -> Void] = [
            { $0.paneID = "other-pane" }, { $0.generation = "other-generation" }, { $0.backendPID += 1 },
            { $0.configurationRoot = "/unit/source-profile" }, { $0.executable = "/unit/other-codex" },
            { $0.accountID = "other-account" }, { $0.round = 2 }, { $0.runID = UUID().uuidString.lowercased() }
        ]
        for change in changes {
            let f = try Fixture(); change(&f.observation.target)
            XCTAssertFalse(try TwinRestrictedStartup.acknowledge(f.actions))
            XCTAssertEqual(f.enters, 0); XCTAssertFalse(f.observation.acknowledged)
        }
    }

    func testManualInputSubmittedTurnOrExistingConversationNeverWrites() throws {
        let manual = try Fixture()
        let receipt = try manual.ledger.beginManualWrite(binding: manual.observation.binding)
        XCTAssertTrue(manual.ledger.finishWrite(receipt, succeeded: true))
        XCTAssertFalse(try TwinRestrictedStartup.acknowledge(manual.actions)); XCTAssertEqual(manual.enters, 0)
        for submitted in [false, true] {
            let f = try Fixture()
            if submitted { f.observation.hasSubmittedInput = true } else { f.observation.conversationID = UUID().uuidString }
            XCTAssertFalse(try TwinRestrictedStartup.acknowledge(f.actions)); XCTAssertEqual(f.enters, 0)
        }
    }

    func testTrustExistingTaskPermissionMergeAndTrailingDialogsAreRejected() throws {
        let f = try Fixture()
        let screens = [
            f.screen.replacingOccurrences(of: "Open restricted", with: "Trust and continue"),
            f.screen.replacingOccurrences(of: "Open restricted", with: "Open existing task"),
            "Folder access\nTrust this folder?\n1. Trust and continue\n2. Quit\nenter continue · esc quit",
            f.screen + "\nPermission request: allow once?",
            f.screen + "\nMerge the production branch?\nenter continue · esc cancel",
            f.screen + "\nUnrelated question\nenter continue · esc cancel",
            "\u{1b}[2J" + f.screen
        ]
        for screen in screens {
            f.screen = screen
            XCTAssertFalse(try TwinRestrictedStartup.acknowledge(f.actions)); XCTAssertEqual(f.enters, 0)
        }
    }

    func testPartialRenderAndChangedProcessAfterCaptureDoNotReserveOrWrite() throws {
        let partial = try Fixture(); let full = partial.screen
        partial.screen = "Folder access\nConfig, hooks, and exec policies"
        XCTAssertFalse(try TwinRestrictedStartup.acknowledge(partial.actions))
        XCTAssertFalse(partial.observation.acknowledged)
        partial.screen = full
        XCTAssertTrue(try TwinRestrictedStartup.acknowledge(partial.actions))
        let changed = try Fixture()
        changed.afterCapture = {
            changed.observation.providerIdentity = SupervisorProcessIdentity(pid: 303, ownerUID: getuid(), startedAtSeconds: 999, startedAtMicroseconds: 1)
        }
        XCTAssertFalse(try TwinRestrictedStartup.acknowledge(changed.actions))
        XCTAssertEqual(changed.events, ["capture"]); XCTAssertEqual(changed.enters, 0)
    }

    func testProtocolAcknowledgementPreservesOwnedArgvAndLaterTrustedSubmitReadiness() throws {
        let f = try Fixture(), initial = try f.ledger.ownedInvocationFingerprint(paneID: "twin-pane")
        XCTAssertNil(f.ledger.readiness(binding: f.observation.binding).lease)
        XCTAssertTrue(try TwinRestrictedStartup.acknowledge(f.actions))
        XCTAssertEqual(try f.ledger.ownedInvocationFingerprint(paneID: "twin-pane"), initial)
        XCTAssertNil(f.ledger.readiness(binding: f.observation.binding).lease)
        XCTAssertTrue(f.ledger.observeTrustedSubmit(binding: f.observation.binding, originStartedAt: Date(timeIntervalSince1970: 2)))
        XCTAssertEqual(f.ledger.readiness(binding: f.observation.binding).lease?.revision, 1)
    }

    func testCancellationAfterReservationNeverReplaysAndPreservesInput() throws {
        let f = try Fixture(), initial = try f.ledger.ownedInvocationFingerprint(paneID: "twin-pane")
        f.afterReserve = { f.active = false }
        XCTAssertFalse(try TwinRestrictedStartup.acknowledge(f.actions))
        XCTAssertEqual(f.events, ["capture", "reserve"]); XCTAssertEqual(f.enters, 0)
        XCTAssertEqual(try f.ledger.ownedInvocationFingerprint(paneID: "twin-pane"), initial)
        XCTAssertTrue(f.observation.acknowledged)
        f.active = true
        XCTAssertFalse(try TwinRestrictedStartup.acknowledge(f.actions)); XCTAssertEqual(f.enters, 0)
    }

    func testFailedDispatchInvalidatesReceiptAndCannotRepeat() throws {
        let f = try Fixture(); f.failSend = true
        XCTAssertThrowsError(try TwinRestrictedStartup.acknowledge(f.actions))
        XCTAssertTrue(f.observation.acknowledged); XCTAssertEqual(f.enters, 1)
        XCTAssertFalse(f.ledger.observeTrustedSubmit(binding: f.observation.binding, originStartedAt: Date(timeIntervalSince1970: 2)))
        XCTAssertNil(f.ledger.readiness(binding: f.observation.binding).lease)
        XCTAssertFalse(try TwinRestrictedStartup.acknowledge(f.actions)); XCTAssertEqual(f.enters, 1)
    }

    func testChangedProviderImmediatelyBeforeDispatchNeverWritesOrLosesOwnedPrompt() throws {
        let f = try Fixture(), initial = try f.ledger.ownedInvocationFingerprint(paneID: "twin-pane")
        f.afterSave = {
            f.observation.providerIdentity = SupervisorProcessIdentity(pid: 303, ownerUID: getuid(), startedAtSeconds: 999, startedAtMicroseconds: 1)
        }
        XCTAssertFalse(try TwinRestrictedStartup.acknowledge(f.actions))
        XCTAssertTrue(f.observation.acknowledged); XCTAssertEqual(f.enters, 0)
        XCTAssertEqual(try f.ledger.ownedInvocationFingerprint(paneID: "twin-pane"), initial)
    }

    private final class Fixture {
        let target: TwinRestrictedStartupTarget
        var observation: TwinRestrictedStartupObservation
        var ledger = TerminalInputLedger()
        let expectedFingerprint: String
        var active = true, enters = 0, failSend = false
        var events: [String] = []
        var afterCapture: () -> Void = {}
        var afterReserve: () -> Void = {}
        var afterSave: () -> Void = {}
        var screen = """
        Folder access
        /unit/worktree

        Config, hooks, and exec policies from untrusted folders stay disabled.
        Trusted project folders can still contribute settings. Skills still load,
        and tools follow your permission settings. Opening will not change saved trust.

        › 1. Open restricted
          2. Back to Agent Command Center

        enter continue · esc back
        """
        init() throws {
            func identity(_ pid: Int32) -> SupervisorProcessIdentity {
                SupervisorProcessIdentity(pid: pid, ownerUID: getuid(), startedAtSeconds: UInt64(pid), startedAtMicroseconds: 1)
            }
            target = TwinRestrictedStartupTarget(runID: "ca996ffe-c53a-488c-890a-3d126422131d", round: 1, paneID: "twin-pane", generation: "owned-generation",
                backendPID: 101, backendIdentity: identity(101), configurationRoot: "/unit/profile", cwd: "/unit/worktree", executable: "/unit/codex", accountID: "same-account")
            observation = TwinRestrictedStartupObservation(target: target, wrapperPID: 202, wrapperIdentity: identity(202), providerPID: 303, providerIdentity: identity(303),
                conversationID: nil, fingerprint: "", acknowledged: false, hasSubmittedInput: false)
            let prior = try ledger.ownedInvocationFingerprint(paneID: target.paneID)
            try ledger.registerOwnedInvocationPrompt(binding: observation.binding, expectedPriorFingerprint: prior, capturedAt: Date(timeIntervalSince1970: 1))
            expectedFingerprint = try ledger.ownedInvocationFingerprint(paneID: target.paneID)
        }
        var actions: TwinRestrictedStartupActions {
            TwinRestrictedStartupActions(target: target, expectedFingerprint: expectedFingerprint, active: { self.active }, observe: {
                var value = self.observation
                value.fingerprint = try self.ledger.ownedInvocationFingerprint(paneID: self.target.paneID)
                return value
            }, capture: { _ in self.events.append("capture"); self.afterCapture(); return self.screen }, reserve: {
                self.events.append("reserve"); self.observation.acknowledged = true; self.afterReserve()
            }, loadLedger: { self.ledger }, saveLedger: { self.events.append("save"); self.ledger = $0; self.afterSave() }, sendEnter: { _ in
                XCTAssertTrue(self.observation.acknowledged); self.events.append("enter"); self.enters += 1
                if self.failSend { throw CocoaError(.fileWriteUnknown) }
            })
        }
    }
}
