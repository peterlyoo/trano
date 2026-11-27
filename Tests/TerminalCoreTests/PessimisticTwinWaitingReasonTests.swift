import Foundation
import XCTest
@testable import TerminalCore

final class PessimisticTwinWaitingReasonTests: XCTestCase {
    // Implements: FR-TWIN-1, FR-TWIN-7
    func testCompletedSourceWithoutInputProofShowsWhyReviewHasNotStartedWithoutRepeatedWrites() throws {
        let f = try TwinFixture(); defer { f.remove() }
        let store = TwinStore(root: f.root), backend = FakeTwinBackend(f)
        let c = TwinCoordinator(store: store, backend: backend)
        let run = try c.enable(source: f.source, mode: .codeReview, now: f.date)
        backend.context = TwinRuntimeContext(source: f.source, completion: f.completion(), inputClear: false)
        _ = try c.processPending(now: Date(timeIntervalSince1970: 102))
        let waiting = try XCTUnwrap(store.load().runs.first { $0.id == run.id })
        XCTAssertEqual(waiting.phase, .waitingForSource)
        XCTAssertTrue(waiting.message?.contains("input verification") == true)
        XCTAssertTrue(waiting.message?.contains("not started") == true)
        XCTAssertEqual(backend.snapshots, 0); XCTAssertEqual(backend.launches, 0); XCTAssertEqual(backend.cards, 0)
        _ = try c.processPending(now: Date(timeIntervalSince1970: 103))
        XCTAssertEqual(try store.load().runs.first { $0.id == run.id }, waiting)
    }

    // Implements: FR-TWIN-1, FR-TWIN-2
    func testVerifiedInputClearsOnlyItsWaitingReasonBeforeSnapshotting() throws {
        let f = try TwinFixture(); defer { f.remove() }
        let store = TwinStore(root: f.root), backend = FakeTwinBackend(f)
        let c = TwinCoordinator(store: store, backend: backend)
        let run = try c.enable(source: f.source, mode: .codeReview, now: f.date)
        backend.context = TwinRuntimeContext(source: f.source, completion: f.completion(), inputClear: false)
        _ = try c.processPending(now: Date(timeIntervalSince1970: 102))
        XCTAssertNotNil(try store.load().runs.first { $0.id == run.id }?.message)
        backend.context = TwinRuntimeContext(source: f.source, completion: f.completion(), inputClear: true)
        _ = try c.processPending(now: Date(timeIntervalSince1970: 103))
        let advanced = try XCTUnwrap(store.load().runs.first { $0.id == run.id })
        XCTAssertEqual(advanced.phase, .launching); XCTAssertNil(advanced.message)
        XCTAssertEqual(backend.snapshots, 1); XCTAssertEqual(backend.launches, 0)
    }

    // Implements: FR-TWIN-7
    func testInputWaitDoesNotOverwriteAnExistingWorkflowDiagnostic() throws {
        let f = try TwinFixture(); defer { f.remove() }
        let store = TwinStore(root: f.root), backend = FakeTwinBackend(f)
        let c = TwinCoordinator(store: store, backend: backend)
        let run = try c.enable(source: f.source, mode: .codeReview, now: f.date)
        try store.transaction { value in value.runs[0].message = "Retained workflow diagnostic" }
        backend.context = TwinRuntimeContext(source: f.source, completion: f.completion(), inputClear: false)
        _ = try c.processPending(now: Date(timeIntervalSince1970: 102))
        XCTAssertEqual(try store.load().runs.first { $0.id == run.id }?.message, "Retained workflow diagnostic")
        XCTAssertEqual(backend.snapshots, 0)
    }
}
