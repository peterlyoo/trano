import AppKit
import TerminalCore

extension AppStore {
    func makeTerminalPathPanel(directoryOnly: Bool, directory: String, recentPaths: [TerminalRecentPath],
                               preferences: TerminalPreferences, owner: TerminalInteractionOwner) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = directoryOnly ? "Go to Directory" : "Insert Path"
        panel.prompt = directoryOnly ? "Open in New Tab" : "Insert Path"
        panel.canChooseFiles = !directoryOnly
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = !directoryOnly
        panel.directoryURL = URL(fileURLWithPath: directory)
        let accessory = TerminalRecentPathAccessory(owner: { [weak self] in self?.terminalViews[owner.paneID]?.interactionOwner() },
            onChoose: { [weak self, weak panel] entry in
                guard self?.terminalViews[owner.paneID]?.interactionOwner() == owner else { return }
                panel?.directoryURL = URL(fileURLWithPath: entry.path)
            })
        accessory.update(entries: recentPaths, hostID: nil, enabled: preferences.showRecentPaths)
        accessory.attach(to: panel)
        return panel
    }

    func reconcileTerminalInteractionOwners() {
        for view in terminalViews.values { _ = view.interactionOwner() }
        if let request = remotePathRequest, terminalViews[request.paneID]?.interactionOwner() != request.owner {
            remotePathRequest = nil
        }
    }

    func saveTerminalTrustedRule(_ rule: TerminalTrustedLink, enabled: Bool,
                                owner: TerminalInteractionOwner,
                                completion: @escaping TerminalTrustedRuleSaveCompletion) {
        guard let lease = terminalViews[owner.paneID]?.interactionLease(for: owner) else {
            completion(.failure(TerminalError.invalid("Terminal owner changed"))); return
        }
        let runtime = runtime
        queue.async { [weak self] in
            let result = Result<TerminalPreferences, Error> {
                guard lease.isValid else { throw TerminalError.invalid("Terminal owner changed") }
                return try runtime.transaction {
                    let state = try runtime.state()
                    guard lease.isValid, state.sessions.contains(where: { $0.id == owner.paneID && $0.pid == lease.sessionPID && $0.remote?.hostID == lease.hostID }) else { throw TerminalError.invalid("Terminal session changed") }
                    let current = try runtime.terminalPreferences()
                    guard !enabled || current.applicationLinks != .never else { throw TerminalError.invalid("Application links are disabled") }
                    var next = current
                    next.trustedLinks.removeAll { existing in
                        existing.scheme.lowercased() == rule.scheme.lowercased()
                            && existing.host?.lowercased() == rule.host?.lowercased() && existing.port == rule.port
                    }
                    if enabled { next.trustedLinks.append(rule) }
                    try next.validate()
                    guard lease.isValid else { throw TerminalError.invalid("Terminal owner changed") }
                    return try runtime.saveTerminalPreferences(next, from: current)
                }
            }
            DispatchQueue.main.async {
                if case .success = result, let self {
                    self.terminalPreferences.trustedLinks.removeAll { existing in
                        existing.scheme.lowercased() == rule.scheme.lowercased()
                            && existing.host?.lowercased() == rule.host?.lowercased() && existing.port == rule.port
                    }
                    if enabled { self.terminalPreferences.trustedLinks.append(rule) }
                }
                guard let self, self.terminalViews[owner.paneID]?.interactionOwner() == owner else {
                    completion(.failure(TerminalError.invalid("Terminal owner changed"))); return
                }
                completion(result.map { _ in () })
            }
        }
    }

    func loadTerminalRecentPaths(hostID: String?, owner: TerminalInteractionOwner,
                                 completion: @escaping (Result<[TerminalRecentPath], Error>) -> Void) {
        guard let lease = terminalViews[owner.paneID]?.interactionLease(for: owner), lease.hostID == hostID else {
            completion(.failure(TerminalError.invalid("Terminal owner changed"))); return
        }
        let runtime = runtime
        queue.async { [weak self] in
            let result = Result<(TerminalPreferences, [TerminalRecentPath]), Error> {
                guard lease.isValid else { throw TerminalError.invalid("Terminal owner changed") }
                return try runtime.transaction {
                    guard lease.isValid, try runtime.state().sessions.contains(where: { $0.id == owner.paneID && $0.pid == lease.sessionPID && $0.remote?.hostID == hostID }) else { throw TerminalError.invalid("Terminal session changed") }
                    return (try runtime.terminalPreferences(), try runtime.recentTerminalPaths(hostID: hostID))
                }
            }
            DispatchQueue.main.async {
                guard let self, self.terminalViews[owner.paneID]?.interactionOwner() == owner else {
                    completion(.failure(TerminalError.invalid("Terminal owner changed"))); return
                }
                switch result {
                case .success(let (_, entries)): completion(.success(entries))
                case .failure(let error): completion(.failure(error))
                }
            }
        }
    }

    func recordTerminalPaths(_ paths: [String], hostID: String?, owner: TerminalInteractionOwner,
                             completion: @escaping (Result<Void, Error>) -> Void = { _ in }) {
        guard let lease = terminalViews[owner.paneID]?.interactionLease(for: owner), lease.hostID == hostID else {
            completion(.failure(TerminalError.invalid("Terminal owner changed"))); return
        }
        let runtime = runtime
        queue.async {
            let result = Result<Void, Error> {
                guard lease.isValid else { throw TerminalError.invalid("Terminal owner changed") }
                try runtime.transaction {
                    guard lease.isValid, try runtime.state().sessions.contains(where: { $0.id == owner.paneID && $0.pid == lease.sessionPID && $0.remote?.hostID == hostID }) else { throw TerminalError.invalid("Terminal session changed") }
                    for path in paths {
                        guard lease.isValid else { throw TerminalError.invalid("Terminal owner changed") }
                        try runtime.recordTerminalPath(path, hostID: hostID)
                    }
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
