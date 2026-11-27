import Foundation
import Darwin
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class SupervisorRendererIdentityTests: XCTestCase {
    // Implements: FR-SUP-1, FR-SUP-5
    func testMatchingLiveLocalIdentityReadsTheInjectedBirthIdentityOnce() {
        let binding = fixtureBinding()
        var checked: [Int32] = []
        XCTAssertNoThrow(try SupervisorRendererIdentity.validate(binding: binding, currentBinding: binding,
            sessions: [fixtureSession()]) { checked.append($0); return binding.processIdentity })
        XCTAssertEqual(checked, [binding.backendPID])
    }

    // Implements: FR-SUP-1, FR-SUP-5
    func testTheCompleteDurableBindingMustMatchBeforeReadingProcessIdentity() {
        let binding = fixtureBinding()
        let changedConfiguration = SupervisorBinding(paneID: binding.paneID, backendPID: binding.backendPID,
            configuration: SupervisorConfiguration(provider: .codex, cwd: "/tmp"), createdAt: binding.createdAt,
            processIdentity: binding.processIdentity)
        let changedCreation = SupervisorBinding(paneID: binding.paneID, backendPID: binding.backendPID,
            configuration: binding.configuration, createdAt: binding.createdAt.addingTimeInterval(1),
            processIdentity: binding.processIdentity)
        let changedBirth = SupervisorBinding(paneID: binding.paneID, backendPID: binding.backendPID,
            configuration: binding.configuration, createdAt: binding.createdAt,
            processIdentity: fixtureIdentity(pid: binding.backendPID, seconds: 2))
        for current in [nil, changedConfiguration, changedCreation, changedBirth] as [SupervisorBinding?] {
            var calls = 0
            assertInvalid {
                try SupervisorRendererIdentity.validate(binding: binding, currentBinding: current,
                    sessions: [self.fixtureSession()]) { _ in calls += 1; return binding.processIdentity }
            }
            XCTAssertEqual(calls, 0)
        }
    }

    // Implements: FR-SUP-1, FR-SUP-5
    func testMissingChangedRemoteOrDeadMetadataNeverChecksAProcess() {
        let binding = fixtureBinding()
        let own = fixtureSession()
        var wrongPID = own
        wrongPID.pid += 1
        var wrongID = own
        wrongID.id = "00000000-0000-4000-8000-000000000020"
        var remote = own
        remote.remote = RemoteReference(hostID: "remote-fixture", sessionID: own.id)
        var nonlocalHost = own
        nonlocalHost.host = "remote-fixture"
        var dead = own
        dead.alive = false
        for sessions in [[], [wrongPID], [wrongID], [remote], [nonlocalHost], [dead]] {
            var calls = 0
            assertInvalid {
                try SupervisorRendererIdentity.validate(binding: binding, currentBinding: binding,
                    sessions: sessions) { _ in calls += 1; return binding.processIdentity }
            }
            XCTAssertEqual(calls, 0)
        }
    }

    // Implements: FR-SUP-1, FR-SUP-5
    func testAnExplicitlyStoppedBindingNeverChecksAProcess() {
        var binding = fixtureBinding()
        binding.stoppedAt = Date(timeIntervalSince1970: 2)
        var calls = 0
        assertInvalid {
            try SupervisorRendererIdentity.validate(binding: binding, currentBinding: binding,
                sessions: [self.fixtureSession()]) { _ in calls += 1; return binding.processIdentity }
        }
        XCTAssertEqual(calls, 0)
    }

    // Implements: FR-SUP-1, FR-SUP-5
    func testAnUnavailableBackendIdentityRejectsOtherwiseMatchingMetadata() {
        let binding = fixtureBinding()
        var checked: [Int32] = []
        assertInvalid {
            try SupervisorRendererIdentity.validate(binding: binding, currentBinding: binding,
                sessions: [self.fixtureSession()]) { checked.append($0); return nil }
        }
        XCTAssertEqual(checked, [binding.backendPID])
    }

    // Implements: FR-SUP-1, FR-SUP-5
    func testUnrelatedSessionsDoNotChangeTheBoundIdentity() {
        let binding = fixtureBinding()
        var other = fixtureSession()
        other.id = "00000000-0000-4000-8000-000000000020"
        other.pid = 7001
        var checked: [Int32] = []
        XCTAssertNoThrow(try SupervisorRendererIdentity.validate(binding: binding, currentBinding: binding,
            sessions: [other, fixtureSession()]) { checked.append($0); return binding.processIdentity })
        XCTAssertEqual(checked, [binding.backendPID])
    }

    // Implements: FR-SUP-1, FR-SUP-5
    func testReusingTheSamePIDWithDifferentBirthMetadataIsRejected() {
        let binding = fixtureBinding()
        let mismatches = [
            fixtureIdentity(pid: binding.backendPID, seconds: 2),
            fixtureIdentity(pid: binding.backendPID, microseconds: 2),
            SupervisorProcessIdentity(pid: binding.backendPID, ownerUID: getuid() + 1,
                startedAtSeconds: 1, startedAtMicroseconds: 1)
        ]
        for fresh in mismatches {
            var checked: [Int32] = []
            assertInvalid {
                try SupervisorRendererIdentity.validate(binding: binding, currentBinding: binding,
                    sessions: [self.fixtureSession()]) { checked.append($0); return fresh }
            }
            XCTAssertEqual(checked, [binding.backendPID])
        }
    }

    // Implements: FR-SUP-1, FR-SUP-5
    func testALegacyBindingWithoutBirthIdentityIsRejectedBeforeReadingAProcess() {
        let binding = fixtureBinding(processIdentity: nil)
        var calls = 0
        assertInvalid {
            try SupervisorRendererIdentity.validate(binding: binding, currentBinding: binding,
                sessions: [self.fixtureSession()]) { _ in calls += 1; return self.fixtureIdentity(pid: binding.backendPID) }
        }
        XCTAssertEqual(calls, 0)
    }

    // Implements: FR-SUP-1, FR-SUP-5
    func testRecordedBirthIdentityMustNameTheBoundBackendPIDBeforeReadingAProcess() {
        let binding = fixtureBinding(processIdentity: fixtureIdentity(pid: 8822))
        var calls = 0
        assertInvalid {
            try SupervisorRendererIdentity.validate(binding: binding, currentBinding: binding,
                sessions: [self.fixtureSession()]) { _ in calls += 1; return binding.processIdentity }
        }
        XCTAssertEqual(calls, 0)
    }

    private func fixtureBinding(processIdentity: SupervisorProcessIdentity? = SupervisorProcessIdentity(
        pid: 4711, ownerUID: getuid(), startedAtSeconds: 1, startedAtMicroseconds: 1)) -> SupervisorBinding {
        SupervisorBinding(paneID: "00000000-0000-4000-8000-000000000010", backendPID: 4711,
            configuration: SupervisorConfiguration(provider: .claude, cwd: "/tmp"),
            createdAt: Date(timeIntervalSince1970: 1), processIdentity: processIdentity)
    }

    private func fixtureIdentity(pid: Int32, seconds: UInt64 = 1, microseconds: UInt64 = 1) -> SupervisorProcessIdentity {
        SupervisorProcessIdentity(pid: pid, ownerUID: getuid(), startedAtSeconds: seconds, startedAtMicroseconds: microseconds)
    }

    private func fixtureSession() -> TerminalSession {
        let binding = fixtureBinding()
        return TerminalSession(id: binding.paneID, title: "Supervisor", cwd: "/tmp", pid: binding.backendPID)
    }

    private func assertInvalid(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case TerminalError.invalid = error else {
                return XCTFail("Expected an invalid identity error", file: file, line: line)
            }
        }
    }
}
