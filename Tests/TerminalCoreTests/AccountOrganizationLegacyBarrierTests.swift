import XCTest
@testable import TerminalCore

final class AccountOrganizationLegacyBarrierTests: XCTestCase {
    private let org = "12345678-1234-4234-8234-123456789abc"
    private func runtime() throws -> TerminalRuntime {
        try organizationFixtureRuntime(root: URL(fileURLWithPath: "/tmp/trano-ol-" + UUID().uuidString.prefix(8)))
    }
    private func rawProfile(_ runtime: TerminalRuntime, _ id: String) throws -> [String: Any] {
        let root = try AccountUsageAdapter.object(Data(contentsOf: runtime.root.appendingPathComponent("state.json")))
        return try XCTUnwrap((root["accounts"] as? [[String: Any]])?.first { $0["id"] as? String == id })
    }
    private func marker(_ runtime: TerminalRuntime, _ id: String) throws -> String {
        try String(contentsOf: runtime.root.appendingPathComponent("accounts/" + id + "/.trano-account"), encoding: .utf8)
    }
    private func assertSafe(_ runtime: TerminalRuntime, id: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let profile = try XCTUnwrap(runtime.state().accounts.first { $0.id == id })
        if profile.organization?.selection != nil {
            XCTAssertEqual(try marker(runtime, id), "trano-account-org-v1\n", file: file, line: line)
            XCTAssertEqual(try rawProfile(runtime, id)["enabled"] as? Bool, false, file: file, line: line)
            XCTAssertEqual(try rawProfile(runtime, id)["pinned"] as? Bool, true, file: file, line: line)
        } else {
            XCTAssertEqual(try marker(runtime, id), "trano-account-v1\n", file: file, line: line)
        }
    }

    // Implements: FR-ORG-1, FR-ORG-3, FR-ORG-4
    func testBoundFlagsHydrateButLegacyRawSchemaIsDisabledPinnedAndVersioned() throws {
        let runtime = try runtime(); defer { try? FileManager.default.removeItem(at: runtime.root) }
        let a = try runtime.addAccount(provider: .claude, label: "Work", organization: ClaudeOrganizationSelection(uuid: org, name: nil))
        XCTAssertTrue(a.enabled); XCTAssertFalse(a.pinned)
        try assertSafe(runtime, id: a.id)
        XCTAssertNil(try rawProfile(runtime, a.id)["organization"])
        try runtime.updateAccount(a.id, enabled: false, pinned: true)
        XCTAssertFalse(try runtime.state().accounts[0].enabled); XCTAssertTrue(try runtime.state().accounts[0].pinned)
        try runtime.updateAccount(a.id, enabled: true, pinned: false)
        XCTAssertTrue(try runtime.state().accounts[0].enabled); XCTAssertFalse(try runtime.state().accounts[0].pinned)
        try assertSafe(runtime, id: a.id)
        try runtime.setAccountOrganization(a.id, selection: nil)
        XCTAssertTrue(try runtime.state().accounts[0].enabled); XCTAssertFalse(try runtime.state().accounts[0].pinned)
        XCTAssertEqual(try rawProfile(runtime, a.id)["enabled"] as? Bool, true)
        XCTAssertEqual(try rawProfile(runtime, a.id)["pinned"] as? Bool, false)
        try assertSafe(runtime, id: a.id)
    }

    // Implements: FR-ORG-1, FR-ORG-3
    func testStalePrimaryRewriteCannotDowngradeMarkerOrLoseActualUserFlags() throws {
        let runtime = try runtime(); defer { try? FileManager.default.removeItem(at: runtime.root) }
        let a = try runtime.addAccount(provider: .claude, label: "Work")
        let oldPrimary = try Data(contentsOf: runtime.root.appendingPathComponent("state.json"))
        try runtime.setAccountOrganization(a.id, selection: ClaudeOrganizationSelection(uuid: org, name: nil))
        try runtime.updateAccount(a.id, enabled: false, pinned: true)
        try TerminalRuntime.atomicWrite(oldPrimary, to: runtime.root.appendingPathComponent("state.json"))
        let reopened = try organizationFixtureRuntime(root: runtime.root)
        XCTAssertFalse(try reopened.state().accounts[0].enabled)
        XCTAssertTrue(try reopened.state().accounts[0].pinned)
        XCTAssertEqual(try reopened.state().accounts[0].organization?.selection?.uuid, org)
        XCTAssertNotEqual(try marker(runtime, a.id), "trano-account-v1\n")
        XCTAssertNoThrow(try reopened.accountRoot(a.id))
    }

    // Implements: FR-ORG-2, FR-ORG-3
    func testBindingFailuresRollbackWithoutPublishingUnsafeLegacyTargetOrChangingCredentials() throws {
        for phase in [AccountOrganizationWritePhase.legacyBarrier, .marker, .settings, .metadata, .publishPrimary] {
            let runtime = try runtime(); defer { try? FileManager.default.removeItem(at: runtime.root) }
            let a = try runtime.addAccount(provider: .claude, label: "Work")
            let credentials = try runtime.accountRoot(a.id).appendingPathComponent(".credentials.json")
            try TerminalRuntime.atomicWrite(Data("private sentinel".utf8), to: credentials)
            XCTAssertThrowsError(try runtime.setAccountOrganization(a.id, selection: ClaudeOrganizationSelection(uuid: org, name: nil), expectedBindingID: nil,
                beforeWrite: { if $0 == phase { throw TerminalError.invalid("Injected write failure") } }))
            XCTAssertNil(try runtime.state().accounts[0].organization?.selection)
            XCTAssertTrue(try runtime.state().accounts[0].enabled); XCTAssertFalse(try runtime.state().accounts[0].pinned)
            try assertSafe(runtime, id: a.id)
            XCTAssertEqual(try Data(contentsOf: credentials), Data("private sentinel".utf8))
        }
    }

    // Implements: FR-ORG-2, FR-ORG-3
    func testClearFailuresKeepSelectedIdentityBehindMarkerUntilMetadataIsRemoved() throws {
        for phase in [AccountOrganizationWritePhase.settings, .metadata, .restoreLegacy, .publishPrimary] {
            let runtime = try runtime(); defer { try? FileManager.default.removeItem(at: runtime.root) }
            let a = try runtime.addAccount(provider: .claude, label: "Work", organization: ClaudeOrganizationSelection(uuid: org, name: nil))
            XCTAssertThrowsError(try runtime.setAccountOrganization(a.id, selection: nil, expectedBindingID: nil,
                beforeWrite: { if $0 == phase { throw TerminalError.invalid("Injected clear failure") } }))
            XCTAssertEqual(try runtime.state().accounts[0].organization?.selection?.uuid, org)
            XCTAssertTrue(try runtime.state().accounts[0].enabled); XCTAssertFalse(try runtime.state().accounts[0].pinned)
            try assertSafe(runtime, id: a.id)
        }
    }

    // Implements: FR-ORG-1, FR-ORG-3
    func testMissingMetadataAndCorruptOrDowngradedMarkersRefuseBeforeProviderProbe() throws {
        let runtime = try runtime(); defer { try? FileManager.default.removeItem(at: runtime.root) }
        let a = try runtime.addAccount(provider: .claude, label: "Work", organization: ClaudeOrganizationSelection(uuid: org, name: nil))
        let marker = runtime.root.appendingPathComponent("accounts/" + a.id + "/.trano-account")
        for value in ["corrupt\n", "trano-account-v1\n"] {
            try TerminalRuntime.atomicWrite(Data(value.utf8), to: marker)
            XCTAssertThrowsError(try runtime.accountRoot(a.id))
        }
        try TerminalRuntime.atomicWrite(Data("trano-account-org-v1\n".utf8), to: marker)
        try FileManager.default.removeItem(at: runtime.root.appendingPathComponent("account-organizations-v1.json"))
        XCTAssertThrowsError(try runtime.accountRoot(a.id))
        var calls = 0
        XCTAssertThrowsError(try runtime.preflightAccountOrganization(accountID: a.id, cwd: "/tmp", authenticate: { _, _ in
            calls += 1; throw TerminalError.invalid("Never invoke")
        }))
        XCTAssertEqual(calls, 0)
    }

    // Implements: FR-ORG-1, FR-ORG-2
    func testUnboundAndCodexLegacyMarkersFlagsAndRootsAreUnchanged() throws {
        let runtime = try runtime(); defer { try? FileManager.default.removeItem(at: runtime.root) }
        for provider in [AgentKind.claude, .codex] {
            let account = try runtime.addAccount(provider: provider, label: "Legacy")
            XCTAssertEqual(try marker(runtime, account.id), "trano-account-v1\n")
            XCTAssertEqual(try rawProfile(runtime, account.id)["enabled"] as? Bool, true)
            XCTAssertEqual(try rawProfile(runtime, account.id)["pinned"] as? Bool, false)
            XCTAssertEqual(try runtime.accountRoot(account.id).lastPathComponent, account.id)
        }
    }

    // Implements: FR-ORG-2, FR-ORG-3
    func testPublicationOrdersMarkerBeforeBindingAndRemovesBindingBeforeDowngrade() throws {
        let runtime = try runtime(); defer { try? FileManager.default.removeItem(at: runtime.root) }
        let a = try runtime.addAccount(provider: .claude, label: "Work")
        var phases: [AccountOrganizationWritePhase] = []
        try runtime.setAccountOrganization(a.id, selection: ClaudeOrganizationSelection(uuid: org, name: nil), expectedBindingID: nil,
            beforeWrite: { phase in
                phases.append(phase)
                if phase == .marker {
                    XCTAssertEqual(try self.rawProfile(runtime, a.id)["enabled"] as? Bool, false)
                    XCTAssertEqual(try self.rawProfile(runtime, a.id)["pinned"] as? Bool, true)
                }
                if phase == .metadata { XCTAssertEqual(try self.marker(runtime, a.id), "trano-account-org-v1\n") }
            })
        XCTAssertEqual(phases, [.legacyBarrier, .marker, .settings, .metadata, .publishPrimary])
        phases = []
        try runtime.setAccountOrganization(a.id, selection: nil, expectedBindingID: nil,
            beforeWrite: { phase in
                phases.append(phase)
                if phase == .restoreLegacy {
                    XCTAssertNil(try runtime.state().accounts[0].organization?.selection)
                    XCTAssertEqual(try self.marker(runtime, a.id), "trano-account-org-v1\n")
                }
            })
        XCTAssertEqual(phases, [.settings, .metadata, .restoreLegacy, .publishPrimary])
    }
}
