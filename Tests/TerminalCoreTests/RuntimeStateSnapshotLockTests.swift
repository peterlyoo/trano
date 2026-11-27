import Foundation
import XCTest
@testable import TerminalCore

final class RuntimeStateSnapshotLockTests: XCTestCase {
    // Implements: FR-QUEUE-5, FR-LOAD-1
    func testStateDecodeAllowsSameRuntimeMutation() throws {
        let fixture = try Fixture()
        let gate = DecodeGate()
        let group = DispatchGroup()
        defer {
            gate.release.signal()
            XCTAssertEqual(group.wait(timeout: .now() + 8), .success)
            fixture.cleanup()
        }
        let observation = LockedValue<Result<RuntimeState, Error>?>(nil)
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            observation.set(Result { try fixture.runtime.state(beforeDecode: gate.pause) })
        }
        guard gate.entered.wait(timeout: .now() + 3) == .success else {
            XCTFail("State decoding never reached its gate"); return
        }
        let finished = DispatchSemaphore(value: 0)
        let mutation = LockedValue<Result<Void, Error>?>(nil)
        group.enter()
        DispatchQueue.global().async {
            defer { finished.signal(); group.leave() }
            mutation.set(Result { try fixture.runtime.update { $0.settings.fontSize += 1 } })
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success,
                       "State decoding must not retain its own runtime mutex")
        gate.release.signal()
        guard group.wait(timeout: .now() + 5) == .success else {
            XCTFail("State read or mutation did not finish after releasing decoding"); return
        }
        try XCTUnwrap(mutation.get()).get()
        let snapshot = try XCTUnwrap(observation.get()).get()
        try fixture.assertVersion(1, snapshot)
        XCTAssertEqual(try fixture.runtime.state().settings.fontSize, snapshot.settings.fontSize + 1)
    }

    // Implements: FR-QUEUE-5, FR-QUEUE-3, FR-ORG-3
    func testStateDecodeAllowsCoherentOtherRuntimeCommit() throws {
        let fixture = try Fixture()
        let gate = DecodeGate()
        let group = DispatchGroup()
        defer {
            gate.release.signal()
            XCTAssertEqual(group.wait(timeout: .now() + 8), .success)
            fixture.cleanup()
        }
        let observation = LockedValue<Result<RuntimeState, Error>?>(nil)
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            observation.set(Result { try fixture.runtime.state(beforeDecode: gate.pause) })
        }
        guard gate.entered.wait(timeout: .now() + 3) == .success else {
            XCTFail("State decoding never reached its gate"); return
        }
        let finished = DispatchSemaphore(value: 0)
        let mutation = LockedValue<Result<Void, Error>?>(nil)
        group.enter()
        DispatchQueue.global().async {
            defer { finished.signal(); group.leave() }
            mutation.set(Result { try fixture.writeVersion(2, using: fixture.otherRuntime) })
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success,
                       "State decoding must not retain the cross-runtime state flock")
        gate.release.signal()
        guard group.wait(timeout: .now() + 5) == .success else {
            XCTFail("Snapshot read or coherent commit did not finish after releasing decoding"); return
        }
        try XCTUnwrap(mutation.get()).get()
        try fixture.assertVersion(1, XCTUnwrap(observation.get()).get())
        try fixture.assertVersion(2, fixture.runtime.state())
    }

    // Implements: FR-QUEUE-5, FR-LOAD-1
    func testStateDecodeRetainsExplicitCallerTransactionUntilCallerReturns() throws {
        let fixture = try Fixture()
        let gate = DecodeGate()
        let releaseCaller = DispatchSemaphore(value: 0)
        let observed = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        defer {
            gate.release.signal()
            releaseCaller.signal()
            XCTAssertEqual(group.wait(timeout: .now() + 8), .success)
            fixture.cleanup()
        }
        let observation = LockedValue<Result<RuntimeState, Error>?>(nil)
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            observation.set(Result {
                try fixture.runtime.transaction {
                    let state = try fixture.runtime.state(beforeDecode: gate.pause)
                    observed.signal()
                    guard releaseCaller.wait(timeout: .now() + 6) == .success else {
                        throw TerminalError.runtime("Explicit caller was never released")
                    }
                    return state
                }
            })
        }
        guard gate.entered.wait(timeout: .now() + 3) == .success else {
            XCTFail("State decoding never reached its gate"); return
        }
        let sameFinished = DispatchSemaphore(value: 0)
        let otherFinished = DispatchSemaphore(value: 0)
        let sameMutation = LockedValue<Result<Void, Error>?>(nil)
        let otherMutation = LockedValue<Result<Void, Error>?>(nil)
        for (runtime, finished, result) in [(fixture.runtime, sameFinished, sameMutation),
                                           (fixture.otherRuntime, otherFinished, otherMutation)] {
            group.enter()
            DispatchQueue.global().async {
                defer { finished.signal(); group.leave() }
                result.set(Result { try runtime.update { $0.settings.fontSize += 1 } })
            }
        }
        XCTAssertEqual(sameFinished.wait(timeout: .now() + 0.15), .timedOut)
        XCTAssertEqual(otherFinished.wait(timeout: .now() + 0.15), .timedOut)
        gate.release.signal()
        guard observed.wait(timeout: .now() + 3) == .success else {
            XCTFail("State read did not return after releasing decoding"); return
        }
        XCTAssertEqual(sameFinished.wait(timeout: .now() + 0.15), .timedOut,
                       "State must not release its caller's runtime mutex")
        XCTAssertEqual(otherFinished.wait(timeout: .now() + 0.15), .timedOut,
                       "State must not release its caller's cross-runtime state flock")
        releaseCaller.signal()
        guard group.wait(timeout: .now() + 5) == .success else {
            XCTFail("Explicit caller or mutations did not finish"); return
        }
        try XCTUnwrap(sameMutation.get()).get()
        try XCTUnwrap(otherMutation.get()).get()
        let snapshot = try XCTUnwrap(observation.get()).get()
        try fixture.assertVersion(1, snapshot)
        XCTAssertEqual(try fixture.runtime.state().settings.fontSize, snapshot.settings.fontSize + 2)
    }

    // Implements: FR-QUEUE-3, FR-ORG-3
    func testMissingPrimaryStillIgnoresInvalidSidecars() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("state.json"))
        for name in ["continuity.json", "account-organizations-v1.json"] {
            try TerminalRuntime.atomicWrite(Data("malformed".utf8), to: fixture.root.appendingPathComponent(name))
        }
        let state = try fixture.runtime.state()
        XCTAssertEqual(state.revision, 0)
        XCTAssertTrue(state.sessions.isEmpty)
        XCTAssertTrue(state.activityReadAt.isEmpty)
        XCTAssertTrue(state.accounts.isEmpty)
    }

    // Implements: FR-LOAD-1
    func testUnsupportedPrimarySchemaStillRefusesHydration() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var state = RuntimeState()
        state.schemaVersion = 2
        try TerminalRuntime.atomicWrite(JSONEncoder().encode(state), to: fixture.root.appendingPathComponent("state.json"))
        XCTAssertThrowsError(try fixture.runtime.state())
    }

    private final class DecodeGate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        func pause() throws {
            entered.signal()
            guard release.wait(timeout: .now() + 10) == .success else {
                throw TerminalError.runtime("State decoding was never released")
            }
        }
    }

    private final class LockedValue<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func set(_ value: Value) { lock.lock(); self.value = value; lock.unlock() }
        func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    }

    private struct OrganizationMetadata: Encodable {
        var schemaVersion = 1
        var profiles: [String: AccountOrganizationState]
    }

    private final class Fixture: @unchecked Sendable {
        let root = URL(fileURLWithPath: "/tmp/trano-snap-" + UUID().uuidString.prefix(8))
        let paneID = UUID().uuidString.lowercased()
        let account = AccountProfile(provider: .claude, label: "Snapshot fixture")
        let organizationID = UUID().uuidString.lowercased()
        let bindingID = UUID().uuidString.lowercased()
        let runtime: TerminalRuntime
        let otherRuntime: TerminalRuntime

        init() throws {
            runtime = try TerminalRuntime(root: root)
            otherRuntime = try TerminalRuntime(root: root)
            try writeVersion(1, using: runtime)
        }

        func writeVersion(_ version: Int, using target: TerminalRuntime) throws {
            try target.transaction {
                let enabled = version == 1
                let organization = AccountOrganizationState(
                    selection: try ClaudeOrganizationSelection(uuid: organizationID, name: "Organization \(version)"),
                    verification: .unverified, bindingID: bindingID,
                    profileEnabled: enabled, profilePinned: !enabled)
                let metadata = OrganizationMetadata(profiles: [account.id: organization])
                try TerminalRuntime.atomicWrite(JSONEncoder().encode(metadata),
                    to: root.appendingPathComponent("account-organizations-v1.json"))
                try target.update { state in
                    state.sessions = [TerminalSession(id: paneID, title: "Version \(version)", cwd: "/tmp", pid: 0, alive: false)]
                    state.settings.fontSize = Double(12 + version)
                    state.activityReadAt = [paneID: Date(timeIntervalSince1970: Double(version * 100))]
                    state.followUpInputs = [FollowUpInput(paneID: paneID, text: "Queue \(version)")]
                    var profile = account
                    profile.enabled = enabled
                    profile.pinned = !enabled
                    state.accounts = [profile]
                }
            }
        }

        func assertVersion(_ version: Int, _ state: RuntimeState, file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(state.revision, version, file: file, line: line)
            XCTAssertEqual(state.sessions.first?.title, "Version \(version)", file: file, line: line)
            XCTAssertEqual(state.settings.fontSize, Double(12 + version), file: file, line: line)
            XCTAssertEqual(state.activityReadAt[paneID], Date(timeIntervalSince1970: Double(version * 100)), file: file, line: line)
            XCTAssertEqual(state.followUpInputs.map(\.text), ["Queue \(version)"], file: file, line: line)
            let profile = try XCTUnwrap(state.accounts.first, file: file, line: line)
            XCTAssertEqual(profile.id, account.id, file: file, line: line)
            XCTAssertEqual(profile.organization?.selection?.name, "Organization \(version)", file: file, line: line)
            XCTAssertEqual(profile.enabled, version == 1, file: file, line: line)
            XCTAssertEqual(profile.pinned, version != 1, file: file, line: line)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
