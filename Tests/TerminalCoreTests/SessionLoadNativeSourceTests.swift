import Foundation
import XCTest
@testable import TerminalCore

final class SessionLoadNativeSourceTests: XCTestCase {
    private let moment = SessionLoadMoment(date: Date(timeIntervalSince1970: 1000), monotonicSeconds: 10)

    // Implements: FR-LOAD-2, FR-LOAD-3, FR-LOAD-4
    func testBoundedUIDBatchReadsEachPIDOnceAndRejectsTruncation() {
        var limit = 0
        var reads: [Int32] = []
        let source = SessionLoadNativeSource(userID: 501, listPIDs: { capacity in
            limit = capacity; return SessionLoadPIDList(pids: [10, 10, 20, 30])
        }, readProcess: { pid in
            reads.append(pid)
            return SessionLoadProcess(pid: pid, parentPID: 1, userID: pid == 30 ? 502 : 501,
                startedAtMicroseconds: 100, cpuNanoseconds: 12, residentBytes: 24)
        })
        let batch = source.processes(targets: [], at: moment)
        XCTAssertEqual(limit, 16_384)
        XCTAssertEqual(reads, [10, 20, 30])
        XCTAssertEqual(batch.processes.map(\.pid), [10, 20])
        XCTAssertEqual(batch.userID, 501)
        XCTAssertTrue(batch.complete)
        let truncated = SessionLoadNativeSource(userID: 501, listPIDs: { _ in
            SessionLoadPIDList(pids: Array(2...20_000).map(Int32.init))
        }, readProcess: { _ in nil }).processes(targets: [], at: moment)
        XCTAssertFalse(truncated.complete)
    }

    // Implements: FR-LOAD-1, FR-LOAD-3, FR-LOAD-4
    func testHookCollectionIsBoundedExactAndExcludesRemoteStoppedOrCodex() {
        var reads: [String] = []
        let source = SessionLoadNativeSource(userID: 501, listPIDs: { _ in SessionLoadPIDList(pids: []) }, readProcess: { _ in nil },
            readHook: { target, moment, limit in
                reads.append(target.paneID)
                XCTAssertEqual(limit, 262_144)
                return SessionHookTail(paneID: target.paneID, ownershipToken: target.ownershipToken,
                    providerSessionID: target.providerSessionID!, collectedAt: moment.date, bytes: Data())
            })
        let claude = (0..<20).map { SessionLoadTarget(paneID: "pane\($0)", backendPID: 10, ownershipToken: "launch",
            provider: .claude, providerSessionID: "session\($0)") }
        let ignored = [SessionLoadTarget(paneID: "codex", backendPID: 11, ownershipToken: "launch", provider: .codex, providerSessionID: "session"),
            SessionLoadTarget(paneID: "remote", backendPID: 12, ownershipToken: "launch", provider: .claude, providerSessionID: "session", local: false),
            SessionLoadTarget(paneID: "dead", backendPID: 13, ownershipToken: "launch", provider: .claude, providerSessionID: "session", alive: false)]
        let tails = source.hookTails(targets: ignored + claude, at: moment)
        XCTAssertEqual(reads.count, 16)
        XCTAssertEqual(tails?.count, 16)
        XCTAssertEqual(reads.first, "pane0")
        let unknown = SessionLoadNativeSource(userID: 501, listPIDs: { _ in SessionLoadPIDList(pids: []) }, readProcess: { _ in nil })
        XCTAssertNil(unknown.hookTails(targets: claude, at: moment))
    }

    // Implements: FR-LOAD-1, FR-LOAD-4
    func testOwnedFixtureHookFileIsBoundedAndRejectsSymlinksTraversalAndMismatchedOwner() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let providerID = UUID().uuidString
        let file = root.appendingPathComponent(providerID + ".jsonl")
        let bytes = Data(repeating: 65, count: 300_000)
        try bytes.write(to: file)
        let target = SessionLoadTarget(paneID: "pane", backendPID: 10, ownershipToken: "launch", provider: .claude, providerSessionID: providerID)
        func binding(_ relative: String, pane: String = "pane") -> SessionHookFileBinding {
            SessionHookFileBinding(paneID: pane, ownershipToken: "launch", providerSessionID: providerID,
                configurationRoot: root.path, relativePath: relative)
        }
        let tail = try XCTUnwrap(SessionHookFileReader.tail(binding: binding(file.lastPathComponent), target: target, at: moment))
        XCTAssertEqual(tail.bytes.count, 262_144)
        XCTAssertEqual(tail.fileOffset, UInt64(bytes.count - 262_144))
        var bindingReads = 0
        let mapped = SessionHookFileBinding(paneID: "pane", ownershipToken: "generation", providerSessionID: providerID,
            configurationRoot: root.path, relativePath: file.lastPathComponent)
        let native = SessionLoadNativeSource(bindings: { bindingReads += 1; return [mapped] })
        let current = SessionLoadTarget(paneID: "pane", backendPID: 10, ownershipToken: "verified-backend-generation",
            provider: .claude, providerSessionID: providerID, hookBindingToken: "generation")
        XCTAssertEqual(native.hookTails(targets: [current], at: moment)?.first?.ownershipToken, current.ownershipToken)
        XCTAssertEqual(bindingReads, 1)
        let replacement = SessionLoadTarget(paneID: "pane", backendPID: 10, ownershipToken: "verified-backend-generation",
            provider: .claude, providerSessionID: providerID, hookBindingToken: "different-generation")
        XCTAssertEqual(native.hookTails(targets: [replacement], at: moment)?.count, 0)
        XCTAssertNil(SessionHookFileReader.tail(binding: binding(file.lastPathComponent, pane: "other"), target: target, at: moment))
        XCTAssertNil(SessionHookFileReader.tail(binding: binding("../" + file.lastPathComponent), target: target, at: moment))
        XCTAssertNil(SessionHookFileReader.tail(binding: binding("alias.jsonl"), target: target, at: moment))
        let directory = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: root)
        XCTAssertNil(SessionHookFileReader.tail(binding: binding("linked/" + file.lastPathComponent), target: target, at: moment))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("missing"))
        XCTAssertNil(SessionHookFileReader.tail(binding: binding(file.lastPathComponent), target: target, at: moment))
    }
}
