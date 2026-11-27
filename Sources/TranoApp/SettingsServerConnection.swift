import AppKit
import Combine
import TerminalCore

@MainActor final class SettingsServerConnection: ObservableObject {
    @Published private(set) var controller: ServerSettingsController?
    @Published private(set) var availableAgents: [AgentKind] = []
    @Published private(set) var error: String?
    @Published private(set) var tailscaleAvailable = false
    private let makeBackend: @Sendable () throws -> ServerSettingsBackend
    private let discoverAgents: @Sendable () -> [AgentKind]
    private let discoverTailscale: @Sendable () -> Bool
    private let queue = DispatchQueue(label: "trano.settings.connection", qos: .userInitiated)
    private var loading = false
    private var waiters: [(Result<ServerSettingsController, Error>) -> Void] = []
    private var observation: AnyCancellable?
    private var capabilitiesLoaded = false
    private var capabilitiesLoading = false
    private var capabilityWaiters: [() -> Void] = []

    init(makeBackend: @escaping @Sendable () throws -> ServerSettingsBackend,
         discoverAgents: @escaping @Sendable () -> [AgentKind] = { SettingsServerConnection.installedAgents() },
         discoverTailscale: @escaping @Sendable () -> Bool = { BoundedTailscaleExecutor.installedExecutable() != nil }) {
        self.makeBackend = makeBackend; self.discoverAgents = discoverAgents; self.discoverTailscale = discoverTailscale
    }

    func refreshCapabilities(completion: @escaping () -> Void = {}) {
        if capabilitiesLoaded { completion(); return }
        capabilityWaiters.append(completion)
        guard !capabilitiesLoading else { return }
        capabilitiesLoading = true
        let probe = discoverTailscale
        queue.async { [self] in
            let available = probe()
            DispatchQueue.main.async { [self] in
                tailscaleAvailable = available; capabilitiesLoaded = true; capabilitiesLoading = false
                let callbacks = capabilityWaiters; capabilityWaiters.removeAll()
                for callback in callbacks { callback() }
            }
        }
    }

    func prepare(completion: @escaping (Result<ServerSettingsController, Error>) -> Void = { _ in }) {
        refreshCapabilities()
        if let controller { completion(.success(controller)); return }
        waiters.append(completion)
        guard !loading else { return }
        loading = true; error = nil
        let makeBackend = makeBackend, discoverAgents = discoverAgents
        queue.async { [self] in
            let result = Result { (try makeBackend(), discoverAgents()) }
            DispatchQueue.main.async { [self] in
                let resolved: Result<ServerSettingsController, Error>
                switch result {
                case .success(let (backend, available)):
                    let controller = ServerSettingsController(backend: backend)
                    self.observation = controller.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
                    self.availableAgents = available; self.controller = controller
                    resolved = .success(controller)
                case .failure(let error): self.error = error.localizedDescription; resolved = .failure(error)
                }
                self.loading = false
                let callbacks = self.waiters; self.waiters.removeAll()
                for callback in callbacks { callback(resolved) }
            }
        }
    }

    func saveServer(baseline: ServerPreferences, edited: ServerPreferences, completion: @escaping (Error?) -> Void) {
        prepare { result in
            switch result {
            case .failure(let error): completion(error)
            case .success(let controller):
                let accepted = controller.saveServer(baseline: baseline, edited: edited) { success in
                    completion(success ? nil : TerminalError.runtime(controller.error ?? "Server changes could not be verified."))
                }
                if !accepted { completion(TerminalError.runtime(controller.error ?? "Server is busy. Try saving again.")) }
            }
        }
    }

    func saveIntegrations(baseline: IntegrationsPreferences, edited: IntegrationsPreferences, completion: @escaping (Error?) -> Void) {
        prepare { result in
            switch result {
            case .failure(let error): completion(error)
            case .success(let controller):
                let accepted = controller.saveIntegrations(baseline: baseline, edited: edited) { success in
                    completion(success ? nil : TerminalError.runtime(controller.error ?? "Integrations changes could not be verified."))
                }
                if !accepted { completion(TerminalError.runtime(controller.error ?? "Server is busy. Try saving again.")) }
            }
        }
    }

    nonisolated static func installedAgents() -> [AgentKind] {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").prefix(64).map(String.init)
        return [AgentKind.claude, .codex].filter { provider in
            let name = provider.rawValue
            let candidates = paths.map { $0 + "/" + name } + ["/opt/homebrew/bin/" + name, "/usr/local/bin/" + name,
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/" + name).path]
            return candidates.contains { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
        }
    }
}
