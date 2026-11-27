import Foundation

extension WorkspaceLayout {
    public func randomWorkspaceTitle() -> String {
        let adjectives = ["amber", "bright", "calm", "clear", "quiet", "silver", "soft", "warm"]
        let nouns = ["cedar", "comet", "harbor", "maple", "meadow", "orbit", "pine", "river"]
        let names = Set(workspaces.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let candidates = adjectives.flatMap { adjective in nouns.map { adjective + "-" + $0 } }
        if let available = candidates.filter({ !names.contains($0) }).randomElement() { return available }
        let base = candidates.randomElement()!
        for suffix in 0..<names.count {
            let candidate = base + workspaceNameDisambiguator(suffix)
            if !names.contains(candidate) { return candidate }
        }
        // A set of n occupied names cannot cover n+1 distinct suffixes.
        return base + workspaceNameDisambiguator(names.count)
    }
}

private func workspaceNameDisambiguator(_ index: Int) -> String {
    var value = index
    var bytes: [UInt8] = []
    repeat {
        bytes.append(97 + UInt8(value % 26))
        value = value / 26 - 1
    } while value >= 0
    return String(decoding: bytes.reversed(), as: UTF8.self)
}

extension TerminalRuntime {
    @discardableResult public func ensureInitialWorkspace(cwd: String? = nil) throws -> String? {
        try transaction {
            let snapshot = try state()
            var closedPanes: Set<String> = []
            for pane in snapshot.sessions {
                if try isTerminalIntentionallyClosed(pane.id) { closedPanes.insert(pane.id) }
            }
            let knownPanes = Set(snapshot.sessions.map(\.id)).subtracting(closedPanes)
            let openWorkspaces = Set(snapshot.layout.workspaces.filter { !$0.closed }.map(\.id))
            let usable: (TerminalTab) -> Bool = {
                guard let workspaceID = $0.workspaceID, openWorkspaces.contains(workspaceID) else { return false }
                return $0.panes.contains(where: knownPanes.contains)
            }
            if let selected = snapshot.layout.currentTabs.first(where: { $0.id == snapshot.layout.selectedTabID && usable($0) }) {
                if selected.panes.contains(snapshot.layout.focusedPaneID ?? "") { return nil }
                try update { try $0.layout.selectTab(selected.id) }
                return selected.focusedPaneID ?? selected.panes.first
            }
            if let existing = snapshot.layout.currentTabs.first(where: usable) ?? snapshot.layout.tabs.first(where: usable) {
                try update { try $0.layout.selectTab(existing.id) }
                return existing.focusedPaneID ?? existing.panes.first
            }

            let attached = Set((snapshot.layout.tabs + snapshot.layout.closedTabs).flatMap(\.panes))
            let reservation = detachedPaneReservations()
            let retained = try list().first {
                $0.alive && !closedPanes.contains($0.id) && !attached.contains($0.id) && reservation.permitsDetachedStartupReuse($0.id)
            }
            let directory = cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
            let pane = try retained ?? create(title: URL(fileURLWithPath: directory).lastPathComponent, cwd: directory)
            do {
                try update { state in
                    let name = state.layout.randomWorkspaceTitle()
                    state.layout.addWorkspace(title: name)
                    state.layout.addTab(paneID: pane.id)
                }
            } catch {
                if retained == nil { try? terminate(pane.id) }
                throw error
            }
            return pane.id
        }
    }
}
