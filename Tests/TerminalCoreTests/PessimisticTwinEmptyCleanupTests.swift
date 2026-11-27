import Foundation
import Darwin
import XCTest
@testable import TerminalCore

final class PessimisticTwinEmptyCleanupTests: XCTestCase {
    // Implements: FR-TWIN-9, FR-TWIN-10
    func testUntouchedStopRequiresEmptyRoundBackendAdmissionBeforeFinishing() throws {
        let f = try TwinFixture(); defer { f.remove() }
        let store = TwinStore(root: f.root), backend = EmptyCleanupBackend(f)
        let coordinator = TwinCoordinator(store: store, backend: backend)
        let run = try coordinator.enable(source: f.source, mode: .codeReview, now: f.date)
        try coordinator.stop(id: run.id, now: f.date)
        _ = try coordinator.processPending(now: f.date)
        let admitted = try XCTUnwrap(store.load().runs.first)
        XCTAssertEqual(backend.visited, [1]); XCTAssertEqual(admitted.phase, .cleaning)
        XCTAssertTrue(admitted.latestRound?.cleaned == true)
        _ = try coordinator.processPending(now: f.date)
        XCTAssertEqual(try store.load().runs.first?.phase, .finished)
        XCTAssertEqual(backend.visited, [1])
    }
    func testPrivatePartialArtifactsCannotBeForgottenWhenCoreSnapshotIsNil() throws {
        let f = try TwinFixture(); defer { f.remove() }
        let store = TwinStore(root: f.root), backend = EmptyCleanupBackend(f)
        let coordinator = TwinCoordinator(store: store, backend: backend)
        let run = try coordinator.enable(source: f.source, mode: .securityReview, now: f.date)
        let artifact = f.root.appendingPathComponent("private-snapshot-plan.json")
        try Data("partial owned receipt".utf8).write(to: artifact)
        backend.admission = { _, _ in
            if FileManager.default.fileExists(atPath: artifact.path) { throw TerminalError.invalid("Partial owned snapshot requires review") }
        }
        try coordinator.stop(id: run.id, now: f.date)
        _ = try coordinator.processPending(now: f.date)
        let held = try XCTUnwrap(store.load().runs.first)
        XCTAssertEqual(backend.visited, [1]); XCTAssertEqual(held.phase, .needsReview)
        XCTAssertFalse(held.latestRound?.cleaned ?? true)
        XCTAssertEqual(try Data(contentsOf: artifact), Data("partial owned receipt".utf8))
        XCTAssertEqual(held.operation?.kind, .cleanup)
    }
    func testPendingEmptyRoundCleanupRetainsRootRetryContract() throws {
        let f = try TwinFixture(); defer { f.remove() }
        let store = TwinStore(root: f.root), backend = EmptyCleanupBackend(f)
        let coordinator = TwinCoordinator(store: store, backend: backend)
        let run = try coordinator.enable(source: f.source, mode: .generalReview, now: f.date)
        backend.admission = { run, _ in
            throw TwinCleanupPending(operationID: try XCTUnwrap(run.operation?.id), message: "Owned process is retiring")
        }
        try coordinator.stop(id: run.id, now: f.date)
        _ = try coordinator.processPending(now: f.date)
        var held = try XCTUnwrap(store.load().runs.first)
        XCTAssertEqual(held.phase, .cleaning); XCTAssertNil(held.operation)
        XCTAssertFalse(held.latestRound?.cleaned ?? true)
        backend.admission = nil
        _ = try coordinator.processPending(now: f.date)
        held = try XCTUnwrap(store.load().runs.first)
        XCTAssertTrue(held.latestRound?.cleaned == true)
        _ = try coordinator.processPending(now: f.date)
        XCTAssertEqual(try store.load().runs.first?.phase, .finished)
        XCTAssertEqual(backend.visited, [1, 1])
    }
    func testPopulatedAndEmptyRoundsAreEachAdmittedOnceOutsideMetadataLock() throws {
        let f = try TwinFixture(); defer { f.remove() }
        let store = TwinStore(root: f.root), backend = EmptyCleanupBackend(f)
        let coordinator = TwinCoordinator(store: store, backend: backend)
        let run = try coordinator.enable(source: f.source, mode: .codeReview, now: f.date)
        try store.transaction { state in
            state.runs[0].rounds = [TwinRound(number: 1, snapshot: f.snapshot(run: run, round: 1), createdAt: f.date), TwinRound(number: 2, createdAt: f.date)]
        }
        var metadataLockFree = true
        backend.admission = { _, _ in
            let descriptor = open(f.root.appendingPathComponent("pessimistic-twins.lock").path, O_RDWR)
            defer { close(descriptor) }
            let free = descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0
            metadataLockFree = metadataLockFree && free
            if free { _ = flock(descriptor, LOCK_UN) }
        }
        try coordinator.stop(id: run.id, now: f.date)
        for _ in 0..<3 { _ = try coordinator.processPending(now: f.date) }
        let finished = try XCTUnwrap(store.load().runs.first)
        XCTAssertEqual(backend.visited, [1, 2]); XCTAssertTrue(metadataLockFree)
        XCTAssertTrue(finished.rounds.allSatisfy(\.cleaned)); XCTAssertEqual(finished.phase, .finished)
    }
}
private final class EmptyCleanupBackend: TwinBackend {
    let fixture: TwinFixture
    var visited: [Int] = []
    var admission: ((TwinRun, TwinRound) throws -> Void)?
    init(_ fixture: TwinFixture) { self.fixture = fixture }
    func sourceContext(run: TwinRun) throws -> TwinRuntimeContext { .init(source: fixture.source) }
    func cleanup(run: TwinRun, round: TwinRound) throws { visited.append(round.number); try admission?(run, round) }
    func snapshot(run: TwinRun, round: TwinRound) throws -> TwinGitSnapshot { throw TerminalError.invalid("Unexpected snapshot") }
    func launch(run: TwinRun, round: TwinRound) throws -> TwinPaneBinding { throw TerminalError.invalid("Unexpected launch") }
    func completedReview(run: TwinRun, round: TwinRound) throws -> TwinReviewOutcome? { throw TerminalError.invalid("Unexpected review") }
    func publishDecision(run: TwinRun, round: TwinRound, decisionID: String) throws { throw TerminalError.invalid("Unexpected publication") }
    func merge(run: TwinRun, round: TwinRound, sourceContext: TwinRuntimeContext) throws -> TwinMergeOutcome { throw TerminalError.invalid("Unexpected merge") }
    func enqueueFeedback(run: TwinRun, round: TwinRound, idempotencyKey: String) throws -> String { throw TerminalError.invalid("Unexpected queue") }
}
