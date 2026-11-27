import Combine
import Foundation
import TerminalCore

@MainActor final class ExtendedSettingsDraft: ObservableObject {
    @Published var terminal: TerminalPreferences
    @Published var server: ServerPreferences
    @Published var integrations: IntegrationsPreferences
    @Published var developer: DeveloperPreferences
    private(set) var terminalBaseline: TerminalPreferences
    private(set) var serverBaseline: ServerPreferences
    private(set) var integrationsBaseline: IntegrationsPreferences
    private(set) var developerBaseline: DeveloperPreferences

    init(terminal: TerminalPreferences = .init(), server: ServerPreferences = .init(), integrations: IntegrationsPreferences = .init(), developer: DeveloperPreferences = .init()) {
        self.terminal = terminal; terminalBaseline = terminal
        self.server = server; serverBaseline = server
        self.integrations = integrations; integrationsBaseline = integrations
        self.developer = developer; developerBaseline = developer
    }
    func reload(terminal: TerminalPreferences, server: ServerPreferences, integrations: IntegrationsPreferences, developer: DeveloperPreferences) {
        terminalBaseline = terminal; serverBaseline = server
        integrationsBaseline = integrations; developerBaseline = developer
        cancel()
    }
    func cancel() {
        terminal = terminalBaseline; server = serverBaseline
        integrations = integrationsBaseline; developer = developerBaseline
    }
    func validate() throws {
        try terminal.validate(); try server.validate()
        try integrations.validate(); try developer.validate()
    }
    func automaticDownloads(inherited: Bool) -> Bool {
        developer.installUpdatesAutomatically || (developer.downloadUpdatesAutomatically ?? inherited)
    }
    func setAutomaticDownloads(_ enabled: Bool) {
        developer.downloadUpdatesAutomatically = enabled
        if !enabled { developer.installUpdatesAutomatically = false }
    }
    func acceptLocal(_ snapshot: ExtendedSettingsSnapshot) {
        terminalBaseline = snapshot.terminal; developerBaseline = snapshot.developer
    }
    func acceptServer(_ value: ServerPreferences) { serverBaseline = value }
    func acceptIntegrations(_ value: IntegrationsPreferences) { integrationsBaseline = value }
}

struct ExtendedSettingsSnapshot {
    let terminal: TerminalPreferences
    let terminalBaseline: TerminalPreferences
    let server: ServerPreferences
    let serverBaseline: ServerPreferences
    let integrations: IntegrationsPreferences
    let integrationsBaseline: IntegrationsPreferences
    let developer: DeveloperPreferences
    let developerBaseline: DeveloperPreferences
    @MainActor init(_ draft: ExtendedSettingsDraft) {
        terminal = draft.terminal; terminalBaseline = draft.terminalBaseline
        server = draft.server; serverBaseline = draft.serverBaseline
        integrations = draft.integrations; integrationsBaseline = draft.integrationsBaseline
        developer = draft.developer; developerBaseline = draft.developerBaseline
    }
}

enum SettingsSaveOutcome: Equatable {
    case saved
    case validationFailed(String)
    case localFailed(String)
    case externalFailed(group: String, reason: String)
    var succeeded: Bool { self == .saved }
    var message: String? {
        switch self {
        case .saved: return nil
        case .validationFailed(let reason): return reason
        case .localFailed(let reason): return "Settings could not be fully saved. " + reason
        case .externalFailed(let group, let reason):
            return "Local settings were saved. \(group) changes could not be fully applied or verified: \(reason) Already saved changes remain applied."
        }
    }
}

@MainActor final class SettingsSaveCoordinator: ObservableObject {
    typealias Completion = (Error?) -> Void
    @Published private(set) var isSaving = false
    @discardableResult func save(_ draft: ExtendedSettingsDraft, validateLocal: () throws -> Void,
        local: @escaping (ExtendedSettingsSnapshot, @escaping Completion) -> Void,
        didSaveLocal: @escaping (ExtendedSettingsSnapshot) -> Void = { _ in },
        server: @escaping (ServerPreferences, ServerPreferences, @escaping Completion) -> Void,
        integrations: @escaping (IntegrationsPreferences, IntegrationsPreferences, @escaping Completion) -> Void,
        completion: @escaping (SettingsSaveOutcome) -> Void) -> Bool {
        guard !isSaving else { return false }
        do { try draft.validate(); try validateLocal() }
        catch { completion(.validationFailed(error.localizedDescription)); return false }
        let snapshot = ExtendedSettingsSnapshot(draft)
        isSaving = true
        func finish(_ outcome: SettingsSaveOutcome) {
            isSaving = false
            completion(outcome)
        }
        func applyIntegrations() {
            guard snapshot.integrations != snapshot.integrationsBaseline else { finish(.saved); return }
            integrations(snapshot.integrationsBaseline, snapshot.integrations) { error in
                if let error { finish(.externalFailed(group: "Integrations", reason: error.localizedDescription)); return }
                draft.acceptIntegrations(snapshot.integrations)
                finish(.saved)
            }
        }
        func applyServer() {
            guard snapshot.server != snapshot.serverBaseline else { applyIntegrations(); return }
            server(snapshot.serverBaseline, snapshot.server) { error in
                if let error { finish(.externalFailed(group: "Server", reason: error.localizedDescription)); return }
                draft.acceptServer(snapshot.server)
                applyIntegrations()
            }
        }
        local(snapshot) { error in
            if let error { finish(.localFailed(error.localizedDescription)); return }
            draft.acceptLocal(snapshot)
            didSaveLocal(snapshot)
            applyServer()
        }
        return true
    }
}
