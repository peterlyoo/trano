import AppKit
import XCTest
import TerminalCore
@testable import TranoApp

final class SettingsDismissalTests: XCTestCase {
    @MainActor func testCancelDiscardsPreferencesAndEmbeddedProfileChanges() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let draft = SettingsDraft(settings: fixture.settings, automaticallyChecksForUpdates: true, automaticallyDownloadsUpdates: false)
        draft.settings.fontSize = 22
        draft.automaticallyChecksForUpdates = false
        draft.automaticallyDownloadsUpdates = true
        SettingsDraft.removeProfile(fixture.profile.id, from: &draft.settings)

        draft.cancel()

        XCTAssertEqual(draft.settings, fixture.settings)
        XCTAssertTrue(draft.automaticallyChecksForUpdates)
        XCTAssertFalse(draft.automaticallyDownloadsUpdates)
        XCTAssertEqual(try fixture.runtime.state().settings, fixture.settings)
    }

    @MainActor func testSaveCommitsDraftAndPreservesUneditedConcurrentPreferences() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let draft = SettingsDraft(settings: fixture.settings, automaticallyChecksForUpdates: true, automaticallyDownloadsUpdates: false)
        var profile = fixture.profile
        profile.name = "Edited"
        SettingsDraft.setProfile(profile, in: &draft.settings)
        draft.settings.fontSize = 22
        draft.automaticallyDownloadsUpdates = true
        try fixture.runtime.update { $0.settings.notifications = false }
        XCTAssertEqual(try fixture.runtime.state().settings.appearanceProfiles.first?.name, "Reading")
        var downloads = false

        try draft.save(persist: { settings, baseline in
            try fixture.runtime.update { $0.settings.merge(settings, from: baseline) }
        }, updateChecks: { _ in XCTFail("Unedited update preference was rewritten") }, updateDownloads: { downloads = $0 })

        let saved = try fixture.runtime.state().settings
        XCTAssertEqual(saved.appearanceProfiles.first?.name, "Edited")
        XCTAssertEqual(saved.fontSize, 22)
        XCTAssertFalse(saved.notifications)
        XCTAssertTrue(downloads)
    }

    @MainActor func testInvalidProfileCannotCommitAnyPreferences() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let draft = SettingsDraft(settings: fixture.settings, automaticallyChecksForUpdates: true, automaticallyDownloadsUpdates: false)
        draft.settings.appearanceProfiles[0].name = " "
        draft.automaticallyChecksForUpdates = false

        XCTAssertThrowsError(try draft.save(persist: { _, _ in XCTFail("Invalid profile was persisted") },
                                            updateChecks: { _ in XCTFail("Update preference was persisted") },
                                            updateDownloads: { _ in XCTFail("Update preference was persisted") })) { error in
            XCTAssertEqual(error.localizedDescription, "Invalid appearance profile.")
        }
        XCTAssertEqual(try fixture.runtime.state().settings, fixture.settings)
    }

    @MainActor func testDraftDeletionRemovesOnlyItsPaneProfileReferences() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let draft = SettingsDraft(settings: fixture.settings, automaticallyChecksForUpdates: true, automaticallyDownloadsUpdates: false)
        let second = AppearanceProfile(name: "Second", settings: fixture.settings)
        SettingsDraft.setProfile(second, in: &draft.settings)
        let otherPane = UUID().uuidString.lowercased()
        draft.settings.paneAppearanceProfiles[otherPane] = second.id

        SettingsDraft.removeProfile(fixture.profile.id, from: &draft.settings)

        XCTAssertEqual(draft.settings.appearanceProfiles.map(\.id), [second.id])
        XCTAssertEqual(draft.settings.paneAppearanceProfiles, [otherPane: second.id])
        XCTAssertEqual(try fixture.runtime.state().settings, fixture.settings)
    }

    @MainActor private func makeFixture() throws -> (root: URL, runtime: TerminalRuntime, settings: TerminalSettings, profile: AppearanceProfile) {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-settings-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        var settings = TerminalSettings()
        settings.automaticRestore = false
        let profile = AppearanceProfile(name: "Reading", settings: settings)
        settings.appearanceProfiles = [profile]
        settings.paneAppearanceProfiles[UUID().uuidString.lowercased()] = profile.id
        try runtime.update { $0.settings = settings }
        return (root, runtime, settings, profile)
    }
}
