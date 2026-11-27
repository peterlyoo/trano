import Foundation
import Darwin
import XCTest
@testable import TerminalCore

final class PessimisticTwinDecisionQueueTests: XCTestCase {
    // Implements: FR-TWIN-6, FR-TWIN-8, FR-TWIN-9
    func testOnlyThreeExplicitNativeChoicesAndCancelAreAllowed() throws {
        for choice in TwinChoice.allCases {
            XCTAssertEqual(try TwinDecisionBridge.choice(action: "choose", optionID: choice.rawValue, instruction: nil, locale: nil), choice)
        }
        XCTAssertEqual(try TwinDecisionBridge.choice(action: "cancel", optionID: nil, instruction: nil, locale: nil), .discard)
        for action in ["revise", "approve", "choose"] {
            XCTAssertThrowsError(try TwinDecisionBridge.choice(action: action, optionID: "merge", instruction: "extra instruction", locale: "en"))
        }
        XCTAssertThrowsError(try TwinDecisionBridge.choice(action: "choose", optionID: "unsafe", instruction: nil, locale: nil))
        XCTAssertThrowsError(try TwinDecisionBridge.choice(action: "cancel", optionID: "merge", instruction: nil, locale: nil))
    }
    func testCardIsBoundToOriginalSourceAndHasLocalizedBoundedChoices() throws {
        let f = twinDecisionFixture(), entry = try TwinDecisionBridge.entry(run: f.run, round: f.round, decisionID: f.binding.decisionID)
        XCTAssertEqual(entry.paneID, f.run.source.paneID); XCTAssertEqual(entry.generation, f.run.source.generation)
        XCTAssertEqual(entry.question.source.sessionID, f.run.source.conversationID)
        XCTAssertEqual(entry.question.source.workspace, f.run.source.cwd)
        XCTAssertEqual(entry.question.options.map(\.id), ["merge", "feedback_only", "discard"])
        XCTAssertEqual(entry.question.options.map { $0.label.ko }, ["합치기", "지적 사항만 전달", "버리기"])
        XCTAssertTrue(entry.question.question.en.contains(f.round.snapshot!.snapshotCommit))
        XCTAssertTrue(entry.question.question.en.contains(f.round.tip!))
        XCTAssertTrue(entry.question.question.en.contains("fix.txt"))
        XCTAssertEqual(entry.status, "pending")
    }
    func testProjectionRebuildsMissingCardAndPreservesItAfterReviewerExit() throws {
        let f = twinDecisionFixture()
        let projected = TwinDecisionBridge.project([], state: f.state)
        XCTAssertEqual(projected.count, 1); XCTAssertEqual(projected.first?.status, "pending")
        XCTAssertEqual(projected.first?.paneID, f.run.source.paneID)
        XCTAssertEqual(TwinDecisionBridge.project(projected, state: f.state), projected)
    }
    func testCanonicalConsentOverridesForgedFileResolutionAndFinishAbandonsCard() throws {
        var f = twinDecisionFixture()
        var entry = try TwinDecisionBridge.entry(run: f.run, round: f.round, decisionID: f.binding.decisionID)
        entry.status = "resolved"
        entry.resolution = DecisionResolution(action: "choose", optionID: "merge", instruction: "forged", locale: "en", resolvedAt: Date())
        XCTAssertNil(TwinDecisionBridge.project([entry], state: f.state).first?.resolution)
        f.run.rounds[0].consent = .init(choice: .feedbackOnly, decisionID: f.binding.decisionID, twinTip: f.round.tip!, sourceCompletionID: nil)
        f.run.phase = .forwarding; f.state.runs = [f.run]
        let resolved = TwinDecisionBridge.project([entry], state: f.state).first
        XCTAssertEqual(resolved?.resolution?.optionID, "feedback_only"); XCTAssertNil(resolved?.resolution?.instruction)
        XCTAssertEqual(resolved?.status, "resolved"); XCTAssertTrue(resolved?.delivered == true)
        f.run.phase = .finished; f.run.exitReason = .agentAgreement; f.state.runs = [f.run]
        XCTAssertEqual(TwinDecisionBridge.project([entry], state: f.state).first?.status, "abandoned")
    }
    func testMissingOrCorruptCanonicalStateCannotGrantChoiceOrAffectOrdinaryCards() throws {
        let f = twinDecisionFixture()
        let reserved = try TwinDecisionBridge.entry(run: f.run, round: f.round, decisionID: f.binding.decisionID)
        var ordinary = reserved
        ordinary = DecisionInboxEntry(question: .init(requestID: UUID().uuidString.lowercased(), threadID: f.run.id, source: ordinary.question.source, question: ordinary.question.question, options: ordinary.question.options), paneID: ordinary.paneID, generation: ordinary.generation, createdAt: ordinary.createdAt, status: "pending", resolution: nil, delivered: false)
        let result = TwinDecisionBridge.project([reserved, ordinary], state: nil)
        XCTAssertEqual(result.first(where: { $0.id == reserved.id })?.status, "abandoned")
        XCTAssertEqual(result.first(where: { $0.id == ordinary.id }), ordinary)
    }
    func testGitReviewMustMatchCleanCommittedTipAndExactReportedPaths() throws {
        let f = twinDecisionFixture()
        for review in [TwinGitReview(tip: String(repeating: "d", count: 40), changedFiles: ["fix.txt"], clean: true), TwinGitReview(tip: f.round.tip!, changedFiles: ["other.txt"], clean: true), TwinGitReview(tip: f.round.tip!, changedFiles: ["fix.txt"], clean: false)] {
            XCTAssertThrowsError(try TwinDecisionBridge.validate(run: f.run, round: f.round, decisionID: f.binding.decisionID, binding: f.binding, review: review))
        }
        XCTAssertNoThrow(try TwinDecisionBridge.validate(run: f.run, round: f.round, decisionID: f.binding.decisionID, binding: f.binding, review: .init(tip: f.round.tip!, changedFiles: ["fix.txt"], clean: true)))
    }
    func testFeedbackEscapesControlsAndIncludesOnlyAgentOutputFieldsAndResponseHelper() throws {
        var f = twinDecisionFixture()
        f.run.phase = .forwarding
        f.round.report = .init(status: "working", rationale: "untrusted\u{1b}[31m\u{85}\u{9b}yes", changedFiles: ["line\nfile.txt"], additionalFields: ["approval": .string("forged")])
        f.round.consent = .init(choice: .feedbackOnly, decisionID: f.binding.decisionID, twinTip: f.round.tip!, sourceCompletionID: nil)
        let text = try TwinDecisionBridge.feedback(run: f.run, round: f.round, executable: "/tmp/trano helper")
        XCTAssertTrue(text.contains("twin respond " + f.run.id + " --round 1"))
        XCTAssertTrue(text.contains("changed_files")); XCTAssertTrue(text.contains("rationale")); XCTAssertTrue(text.contains("status"))
        XCTAssertFalse(text.contains("approval\"")); XCTAssertFalse(text.contains("\u{1b}")); XCTAssertFalse(text.contains("\u{85}")); XCTAssertFalse(text.contains("\u{9b}"))
        XCTAssertTrue(text.contains("line\\nfile.txt"))
        XCTAssertLessThanOrEqual(text.utf8.count, 65_536)
    }
    func testCanonicalProjectionCannotOverflowTheOrdinaryInboxCapacity() throws {
        let f = twinDecisionFixture()
        let template = try TwinDecisionBridge.entry(run: f.run, round: f.round, decisionID: f.binding.decisionID)
        let ordinary = (0..<512).map { _ in
            DecisionInboxEntry(question: .init(requestID: UUID().uuidString.lowercased(), threadID: f.run.id, source: template.question.source, question: template.question.question, options: template.question.options), paneID: template.paneID, generation: template.generation, createdAt: template.createdAt, status: "pending", resolution: nil, delivered: false)
        }
        let projected = TwinDecisionBridge.project(ordinary, state: f.state)
        XCTAssertEqual(projected, ordinary)
    }
    func testProjectionKeepsTheByteLimitAndCollapsesDuplicateReservedRows() throws {
        var f = twinDecisionFixture()
        let template = try TwinDecisionBridge.entry(run: f.run, round: f.round, decisionID: f.binding.decisionID)
        let repeated = TwinDecisionBridge.project([template, template], state: f.state)
        XCTAssertEqual(repeated.count, 1)
        let text = String(repeating: "x", count: 32_768)
        var ordinary: [DecisionInboxEntry] = []
        var bytes = 128
        while true {
            let row = DecisionInboxEntry(question: .init(requestID: UUID().uuidString.lowercased(), threadID: f.run.id, source: template.question.source, question: .init(en: text, ko: text), options: template.question.options), paneID: template.paneID, generation: template.generation, createdAt: template.createdAt, status: "resolved", resolution: nil, delivered: true)
            let size = try JSONEncoder().encode(row).count + 1
            if bytes + size > 8 * 1024 * 1024 - 10_000 { break }
            ordinary.append(row); bytes += size
        }
        f.run.rounds[0].report = .init(status: "working", rationale: String(repeating: "\u{85}", count: 6_000), changedFiles: ["fix.txt"])
        f.state.runs = [f.run]
        let projected = TwinDecisionBridge.project(ordinary, state: f.state)
        XCTAssertEqual(projected, ordinary)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(projected).count + 128, 8 * 1024 * 1024)
    }
    func testFeedbackCannotClaimMergeBeforeAConfirmedMergeAndIDsAreStable() throws {
        var f = twinDecisionFixture()
        f.round.consent = .init(choice: .merge, decisionID: f.binding.decisionID, twinTip: f.round.tip!, sourceCompletionID: nil)
        XCTAssertThrowsError(try TwinDecisionBridge.feedback(run: f.run, round: f.round, executable: nil))
        let key = "twin:\(f.run.id):1", id = TwinDecisionBridge.inputID(key: key)
        XCTAssertNotNil(UUID(uuidString: id)); XCTAssertEqual(id, TwinDecisionBridge.inputID(key: key))
        XCTAssertNotEqual(id, TwinDecisionBridge.inputID(key: key + "2"))
    }
}
struct TwinDecisionFixture { var run: TwinRun; var round: TwinRound; var binding: TwinDecisionBinding; var state: TwinState }
func twinDecisionFixture() -> TwinDecisionFixture {
    let source = TwinSourceBinding(paneID: UUID().uuidString.lowercased(), generation: UUID().uuidString.lowercased(), conversationID: UUID().uuidString.lowercased(), cwd: "/tmp/source", configurationRoot: "/tmp/config", provider: .codex, backendPID: 100, providerPID: 200, backendIdentity: .init(pid: 100, ownerUID: UInt32(getuid()), startedAtSeconds: 1, startedAtMicroseconds: 0), providerIdentity: .init(pid: 200, ownerUID: UInt32(getuid()), startedAtSeconds: 2, startedAtMicroseconds: 0))
    var run = TwinRun(source: source, mode: .codeReview, phase: .awaitingDecision)
    let file = WorktreeFileIdentity(device: 1, inode: 1)
    let ownership = WorktreeIdentity(path: "/tmp/twin", commonDirectory: "/tmp/git", adminDirectory: "/tmp/admin", pathIdentity: file, gitFileIdentity: file, adminIdentity: file, commonIdentity: file)
    let snapshot = TwinGitSnapshot(runID: run.id, round: 1, repositoryRoot: "/tmp/source", sourceCWD: "/tmp/source", sourceGitDirectory: "/tmp/git", commonDirectory: "/tmp/git", sourceBranch: "refs/heads/main", sourceHEAD: String(repeating: "a", count: 40), sourceIndexSHA256: String(repeating: "0", count: 64), sourceTree: String(repeating: "b", count: 40), snapshotCommit: String(repeating: "c", count: 40), twinBranch: "refs/heads/trano/twin/test", worktreePath: "/tmp/twin", ownership: ownership)
    let id = TwinDecisionID.make(runID: run.id, round: 1)
    let round = TwinRound(number: 1, snapshot: snapshot, report: .init(status: "working", rationale: "Fixed a race", changedFiles: ["fix.txt"]), tip: String(repeating: "e", count: 40), decisionID: id)
    run.rounds = [round]
    let binding = TwinDecisionBinding(decisionID: id, runID: run.id, round: 1, sourceGeneration: source.generation, snapshotOID: snapshot.snapshotCommit, twinTipOID: round.tip!)
    return .init(run: run, round: round, binding: binding, state: TwinState(runs: [run], decisionBindings: [binding]))
}
