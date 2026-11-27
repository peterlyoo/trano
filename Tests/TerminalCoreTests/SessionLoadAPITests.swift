import Foundation
import XCTest
@testable import TerminalCore

final class SessionLoadAPITests: XCTestCase {
    // Implements: FR-LOAD-1, FR-LOAD-3, FR-LOAD-4
    func testAPIReturnsOnlyCachedMetricsWithoutSamplingOnRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try TerminalRuntime(root: root)
        let source = Source()
        var work: [() -> Void] = []
        let moment = SessionLoadMoment(date: Date(timeIntervalSince1970: 1000), monotonicSeconds: 1)
        let sampler = SessionLoadSampler(source: source, schedule: { work.append($0) }, clock: { moment })
        let service = APIService(runtime: runtime, sessionLoadSampler: sampler)
        XCTAssertEqual(service.route(APIRequest(method: "sessions.load")).result, .array([]))
        XCTAssertEqual(source.calls, 0)
        sampler.requestRefresh(targets: [SessionLoadTarget(paneID: "pane", backendPID: 10, ownershipToken: "launch")])
        for action in work { action() }
        let before = source.calls
        for _ in 0..<10 {
            let response = service.route(APIRequest(method: "sessions.load", params: ["paneID": .string("pane")]))
            XCTAssertNil(response.error)
            let data = try JSONEncoder().encode(XCTUnwrap(response.result))
            let snapshots = try JSONDecoder().decode([SessionLoadSnapshot].self, from: data)
            XCTAssertEqual(snapshots.first?.residentBytes, 24)
        }
        XCTAssertEqual(source.calls, before)
        XCTAssertEqual(service.route(APIRequest(method: "sessions.load", params: ["paneID": .string("other")])).result, .array([]))
        XCTAssertEqual(service.route(APIRequest(method: "sessions.load", params: ["offset": .number(1)])).result, .array([]))
        XCTAssertNotNil(service.route(APIRequest(method: "sessions.load", params: ["limit": .number(65)])).error)
        XCTAssertNotNil(service.route(APIRequest(method: "sessions.load", params: ["paneID": .number(1)])).error)
    }

    private final class Source: SessionLoadSource {
        var calls = 0
        func processes(targets: [SessionLoadTarget], at moment: SessionLoadMoment) -> SessionLoadBatch {
            calls += 1
            return SessionLoadBatch(processes: [SessionLoadProcess(pid: 10, parentPID: 1, userID: 501,
                startedAtMicroseconds: 900_000_000, cpuNanoseconds: 1, residentBytes: 24)],
                userID: 501, observedAt: moment.date, monotonicSeconds: moment.monotonicSeconds)
        }
        func hookTails(targets: [SessionLoadTarget], at moment: SessionLoadMoment) -> [SessionHookTail]? { nil }
    }
}
