import XCTest
import TerminalCore
@testable import TranoApp

// Implements: U05, U21
@MainActor final class ExtendedSettingsDraftTests: XCTestCase {
    enum Failure: LocalizedError { case invalid, local, server, integrations
        var errorDescription: String? { String(describing: self) + " fixture failure" }
    }
    func testCancelRestoresAllFourGroupsWithoutWrites() {
        let draft = ExtendedSettingsDraft()
        draft.terminal.copyOnSelection = true
        draft.server.clientLabel = "Edited"
        draft.integrations.letAgentsNameSessions = true
        draft.developer.enabled = true
        draft.cancel()
        XCTAssertEqual(draft.terminal, TerminalPreferences())
        XCTAssertEqual(draft.server, ServerPreferences())
        XCTAssertEqual(draft.integrations, IntegrationsPreferences())
        XCTAssertEqual(draft.developer, DeveloperPreferences())
    }

    func testSharedDownloadOverrideMatchesDeveloperInstallPolicy() {
        let draft = ExtendedSettingsDraft()
        XCTAssertFalse(draft.automaticDownloads(inherited: false))
        XCTAssertTrue(draft.automaticDownloads(inherited: true))
        draft.setAutomaticDownloads(true)
        XCTAssertEqual(draft.developer.downloadUpdatesAutomatically, true)
        XCTAssertTrue(draft.automaticDownloads(inherited: false))
        draft.developer.installUpdatesAutomatically = true
        draft.setAutomaticDownloads(false)
        XCTAssertEqual(draft.developer.downloadUpdatesAutomatically, false)
        XCTAssertFalse(draft.developer.installUpdatesAutomatically)
        XCTAssertFalse(draft.automaticDownloads(inherited: true))
    }

    func testEveryDraftValidationPrecedesAnyWrite() {
        let mutations: [(ExtendedSettingsDraft) -> Void] = [
            { $0.terminal.fontSize = .nan }, { $0.server.clientLabel = "" },
            { $0.developer.sourceDirectory = "relative" },
        ]
        for mutate in mutations {
            let draft = ExtendedSettingsDraft(); mutate(draft)
            let coordinator = SettingsSaveCoordinator(); var effects = 0; var outcome: SettingsSaveOutcome?
            XCTAssertFalse(coordinator.save(draft, validateLocal: {}, local: { _, _ in effects += 1 },
                server: { _, _, _ in effects += 1 }, integrations: { _, _, _ in effects += 1 }, completion: { outcome = $0 }))
            XCTAssertEqual(effects, 0)
            XCTAssertFalse(outcome?.succeeded ?? true)
            XCTAssertFalse(coordinator.isSaving)
        }
    }

    func testLegacyValidationFailurePreventsEveryEffect() {
        let coordinator = SettingsSaveCoordinator(); var effects = 0; var outcome: SettingsSaveOutcome?
        XCTAssertFalse(coordinator.save(ExtendedSettingsDraft(), validateLocal: { throw Failure.invalid },
            local: { _, _ in effects += 1 }, didSaveLocal: { _ in effects += 1 },
            server: { _, _, _ in effects += 1 }, integrations: { _, _, _ in effects += 1 }, completion: { outcome = $0 }))
        XCTAssertEqual(effects, 0)
        XCTAssertEqual(outcome, .validationFailed(Failure.invalid.localizedDescription))
    }

    func testLocalCompletionMustSucceedBeforeExternalDriversRunInOrder() {
        let draft = changedDraft(); let coordinator = SettingsSaveCoordinator()
        var events: [String] = []; var finishLocal: SettingsSaveCoordinator.Completion?
        var finishServer: SettingsSaveCoordinator.Completion?; var finishIntegrations: SettingsSaveCoordinator.Completion?
        XCTAssertTrue(coordinator.save(draft, validateLocal: { events.append("validate") }, local: { snapshot, done in
            events.append("local"); XCTAssertTrue(snapshot.terminal.copyOnSelection); finishLocal = done
        }, didSaveLocal: { _ in events.append("updates") }, server: { baseline, edited, done in
            events.append("server"); XCTAssertFalse(baseline.remoteControl); XCTAssertTrue(edited.remoteControl); finishServer = done
        }, integrations: { baseline, edited, done in
            events.append("integrations"); XCTAssertFalse(baseline.letAgentsNameSessions); XCTAssertTrue(edited.letAgentsNameSessions); finishIntegrations = done
        }, completion: { events.append($0.succeeded ? "complete" : "failed") }))
        XCTAssertEqual(events, ["validate", "local"]); XCTAssertTrue(coordinator.isSaving)
        finishLocal?(nil); XCTAssertEqual(events, ["validate", "local", "updates", "server"])
        finishServer?(nil); XCTAssertEqual(events.last, "integrations")
        finishIntegrations?(nil)
        XCTAssertEqual(events, ["validate", "local", "updates", "server", "integrations", "complete"])
        XCTAssertFalse(coordinator.isSaving)
    }

    func testUnchangedExternalGroupsDoNotCallDrivers() {
        var events: [String] = []
        SettingsSaveCoordinator().save(ExtendedSettingsDraft(), validateLocal: {}, local: { _, done in events.append("local"); done(nil) },
            server: { _, _, _ in XCTFail("Unchanged Server called") }, integrations: { _, _, _ in XCTFail("Unchanged Integrations called") },
            completion: { XCTAssertTrue($0.succeeded); events.append("complete") })
        XCTAssertEqual(events, ["local", "complete"])
    }

    func testLocalFailureDoesNotApplyExternalGroupsOrUpdatePolicies() {
        let draft = changedDraft(); var effects = 0; var outcome: SettingsSaveOutcome?
        SettingsSaveCoordinator().save(draft, validateLocal: {}, local: { _, done in done(Failure.local) },
            didSaveLocal: { _ in effects += 1 }, server: { _, _, _ in effects += 1 }, integrations: { _, _, _ in effects += 1 }, completion: { outcome = $0 })
        XCTAssertEqual(effects, 0); XCTAssertEqual(outcome, .localFailed(Failure.local.localizedDescription))
        XCTAssertEqual(draft.terminalBaseline, TerminalPreferences())
    }

    func testServerFailureReportsPartialSuccessAndCancelKeepsSavedLocalValues() {
        let draft = changedDraft(); var outcome: SettingsSaveOutcome?
        SettingsSaveCoordinator().save(draft, validateLocal: {}, local: { _, done in done(nil) }, server: { _, _, done in done(Failure.server) },
            integrations: { _, _, _ in XCTFail("Later external group ran after failure") }, completion: { outcome = $0 })
        XCTAssertEqual(outcome, .externalFailed(group: "Server", reason: Failure.server.localizedDescription))
        XCTAssertTrue(outcome?.message?.contains("Local settings were saved") ?? false)
        draft.cancel()
        XCTAssertTrue(draft.terminal.copyOnSelection); XCTAssertTrue(draft.developer.enabled)
        XCTAssertEqual(draft.server, ServerPreferences()); XCTAssertEqual(draft.integrations, IntegrationsPreferences())
    }

    func testIntegrationsFailureKeepsSuccessfulServerBaselineOnCancelAndRetry() {
        let draft = changedDraft(); var outcome: SettingsSaveOutcome?
        SettingsSaveCoordinator().save(draft, validateLocal: {}, local: { _, done in done(nil) }, server: { _, _, done in done(nil) },
            integrations: { _, _, done in done(Failure.integrations) }, completion: { outcome = $0 })
        XCTAssertEqual(outcome, .externalFailed(group: "Integrations", reason: Failure.integrations.localizedDescription))
        XCTAssertTrue(draft.serverBaseline.remoteControl)
        draft.cancel(); XCTAssertTrue(draft.server.remoteControl)
        XCTAssertFalse(draft.integrations.letAgentsNameSessions)
        SettingsSaveCoordinator().save(draft, validateLocal: {}, local: { _, done in done(nil) },
            server: { _, _, _ in XCTFail("Already applied Server re-applied") }, integrations: { _, _, _ in XCTFail("Cancelled Integrations re-applied") }, completion: { XCTAssertTrue($0.succeeded) })
    }

    func testInFlightSaveFreezesValuesAndRejectsReentry() {
        let draft = changedDraft(); let coordinator = SettingsSaveCoordinator(); var finishLocal: SettingsSaveCoordinator.Completion?
        coordinator.save(draft, validateLocal: {}, local: { _, done in finishLocal = done }, server: { _, edited, done in
            XCTAssertTrue(edited.remoteControl); done(nil)
        }, integrations: { _, _, done in done(nil) }, completion: { XCTAssertTrue($0.succeeded) })
        XCTAssertFalse(coordinator.save(draft, validateLocal: { XCTFail("Reentry validated") }, local: { _, _ in XCTFail("Reentry persisted") },
            server: { _, _, _ in XCTFail() }, integrations: { _, _, _ in XCTFail() }, completion: { _ in XCTFail("Reentry completed") }))
        draft.server.remoteControl = false
        finishLocal?(nil)
        XCTAssertFalse(draft.server.remoteControl)
        XCTAssertTrue(draft.serverBaseline.remoteControl)
        XCTAssertFalse(coordinator.isSaving)
    }

    private func changedDraft() -> ExtendedSettingsDraft {
        let draft = ExtendedSettingsDraft(); draft.terminal.copyOnSelection = true
        draft.server.remoteControl = true; draft.integrations.letAgentsNameSessions = true; draft.developer.enabled = true
        return draft
    }
}
