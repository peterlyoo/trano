import Darwin
import Foundation
import XCTest
@testable import TerminalCore
@testable import TranoCLI

final class ProviderSupervisorBoundaryCacheTests: XCTestCase {
    func testUnchangedBoundaryPollDoesNotWaitForUnrelatedRuntimeTransaction() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.supervisor.observeBoundary(with: fixture.relay)
        try assertPollBypassesSharedLock(fixture)
    }

    func testMissingGenerationIsAlsoCachedWithoutWaitingForSharedLock() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.runtime.update { $0.supervision = [] }
        try fixture.supervisor.observeBoundary(with: fixture.relay)
        try assertPollBypassesSharedLock(fixture)
    }

    func testAtomicPrimaryReplacementWithSameSizeAndModificationDateInvalidatesBoundary() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.supervisor.observeBoundary(with: fixture.relay)
        let primary = fixture.root.appendingPathComponent("state.json")
        let original = try Data(contentsOf: primary)
        let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: primary.path)[.modificationDate] as? Date)
        let text = String(decoding: original, as: UTF8.self)
        let replacement = Data(text.replacingOccurrences(of: "\"boundaryRevision\" : 4", with: "\"boundaryRevision\" : 5").utf8)
        XCTAssertNotEqual(replacement, original)
        XCTAssertEqual(replacement.count, original.count)
        try TerminalRuntime.atomicWrite(replacement, to: primary)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: primary.path)
        try fixture.supervisor.observeBoundary(with: fixture.relay)
        XCTAssertEqual(boundaryRevision(fixture.relay), 5)
    }

    func testRemovedGenerationDoesNotReplayItsPreviousBoundary() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.supervisor.observeBoundary(with: fixture.relay)
        try fixture.runtime.update { $0.supervision = [] }
        let replacement = ProviderSignalRelay()
        try fixture.supervisor.observeBoundary(with: replacement)
        XCTAssertEqual(boundaryRevision(replacement), 0)
    }

    func testUnsafeAndNewerSafeBoundariesRemainObservable() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.supervisor.observeBoundary(with: fixture.relay)
        XCTAssertEqual(boundaryRevision(fixture.relay), 4)
        try fixture.runtime.update { state in
            state.supervision[0].boundaryRevision = 5
            state.supervision[0].atTurnBoundary = false
        }
        try fixture.supervisor.observeBoundary(with: fixture.relay)
        XCTAssertEqual(boundaryRevision(fixture.relay), 5)
        try fixture.runtime.update { state in
            state.supervision[0].boundaryRevision = 6
            state.supervision[0].atTurnBoundary = true
        }
        try fixture.supervisor.observeBoundary(with: fixture.relay)
        XCTAssertEqual(boundaryRevision(fixture.relay), 6)
    }

    func testContinuitySidecarCreationReplacementAndRemovalInvalidateRead() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.supervisor.observeBoundary(with: fixture.relay)
        let continuity = fixture.root.appendingPathComponent("continuity.json")
        try TerminalRuntime.atomicWrite(Data("{}".utf8), to: continuity)
        XCTAssertThrowsError(try fixture.supervisor.observeBoundary(with: fixture.relay))
        try TerminalRuntime.atomicWrite(Data("{\"activityReadAt\":{},\"followUpInputs\":[],\"followUpTurns\":[],\"followUpPasteStates\":[]}".utf8), to: continuity)
        XCTAssertNoThrow(try fixture.supervisor.observeBoundary(with: fixture.relay))
        try TerminalRuntime.atomicWrite(Data("{}".utf8), to: continuity)
        XCTAssertThrowsError(try fixture.supervisor.observeBoundary(with: fixture.relay))
        try FileManager.default.removeItem(at: continuity)
        XCTAssertNoThrow(try fixture.supervisor.observeBoundary(with: fixture.relay))
    }

    func testOrganizationSidecarChangesRetainAuthoritativeValidation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.supervisor.observeBoundary(with: fixture.relay)
        let organizations = fixture.root.appendingPathComponent("account-organizations-v1.json")
        try TerminalRuntime.atomicWrite(Data("{\"schemaVersion\":2,\"profiles\":{}}".utf8), to: organizations)
        XCTAssertThrowsError(try fixture.supervisor.observeBoundary(with: fixture.relay))
        try TerminalRuntime.atomicWrite(Data("{\"schemaVersion\":1,\"profiles\":{}}".utf8), to: organizations)
        XCTAssertNoThrow(try fixture.supervisor.observeBoundary(with: fixture.relay))
        try FileManager.default.removeItem(at: organizations)
        XCTAssertNoThrow(try fixture.supervisor.observeBoundary(with: fixture.relay))
    }

    func testCorruptPrimaryReadDoesNotPoisonRetryCache() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.supervisor.observeBoundary(with: fixture.relay)
        let primary = fixture.root.appendingPathComponent("state.json")
        let valid = try Data(contentsOf: primary)
        try TerminalRuntime.atomicWrite(Data("{}".utf8), to: primary)
        XCTAssertThrowsError(try fixture.supervisor.observeBoundary(with: fixture.relay))
        XCTAssertThrowsError(try fixture.supervisor.observeBoundary(with: fixture.relay))
        try TerminalRuntime.atomicWrite(valid, to: primary)
        XCTAssertNoThrow(try fixture.supervisor.observeBoundary(with: fixture.relay))
        try assertPollBypassesSharedLock(fixture)
    }

    func testCachedBoundaryIsReplayedToAnotherRelay() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.supervisor.observeBoundary(with: fixture.relay)
        let replacement = ProviderSignalRelay()
        try fixture.supervisor.observeBoundary(with: replacement)
        XCTAssertEqual(boundaryRevision(replacement), 4)
    }

    private func boundaryRevision(_ relay: ProviderSignalRelay) -> Int? {
        Mirror(reflecting: relay).children.first { $0.label == "boundaryRevision" }?.value as? Int
    }

    private func assertPollBypassesSharedLock(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        let holderEntered = DispatchSemaphore(value: 0)
        let releaseHolder = DispatchSemaphore(value: 0)
        let polled = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let holder = LockedResult<Void>()
        let result = LockedResult<Void>()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            holder.set(Result {
                try fixture.otherRuntime.transaction {
                    holderEntered.signal()
                    guard releaseHolder.wait(timeout: .now() + 5) == .success else {
                        throw TerminalError.runtime("Fixture transaction was not released")
                    }
                }
            })
        }
        defer {
            releaseHolder.signal()
            XCTAssertEqual(group.wait(timeout: .now() + 6), .success, file: file, line: line)
        }
        guard holderEntered.wait(timeout: .now() + 2) == .success else {
            XCTFail("Fixture did not acquire its isolated state.lock", file: file, line: line)
            return
        }
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave(); polled.signal() }
            result.set(Result { try fixture.supervisor.observeBoundary(with: fixture.relay) })
        }
        XCTAssertEqual(polled.wait(timeout: .now() + 0.5), .success,
                       "An unchanged boundary must not join an unrelated shared runtime transaction", file: file, line: line)
        releaseHolder.signal()
        guard group.wait(timeout: .now() + 3) == .success else {
            XCTFail("Fixture observation did not finish after release", file: file, line: line)
            return
        }
        try XCTUnwrap(holder.get(), file: file, line: line).get()
        try XCTUnwrap(result.get(), file: file, line: line).get()
    }

    private final class LockedResult<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<Value, Error>?
        func set(_ value: Result<Value, Error>) { lock.lock(); self.value = value; lock.unlock() }
        func get() -> Result<Value, Error>? { lock.lock(); defer { lock.unlock() }; return value }
    }

    private final class Fixture: @unchecked Sendable {
        let root: URL
        let runtime: TerminalRuntime
        let otherRuntime: TerminalRuntime
        let relay = ProviderSignalRelay()
        let supervisor: ProviderSupervisor

        init() throws {
            root = URL(fileURLWithPath: "/tmp/trano-boundary-" + UUID().uuidString.prefix(8))
            runtime = try TerminalRuntime(root: root)
            otherRuntime = try TerminalRuntime(root: root)
            let launch = AgentLaunch(paneID: UUID().uuidString.lowercased(), provider: .claude, cwd: "/tmp", accountID: nil,
                                     configurationRoot: root.path, bootID: "unit", processID: nil)
            supervisor = ProviderSupervisor(runtime: runtime, launch: launch)
            try runtime.update { state in
                var monitor = AgentSupervision(generation: launch.id)
                monitor.atTurnBoundary = true
                monitor.boundaryRevision = 4
                state.supervision = [monitor]
            }
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
