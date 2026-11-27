import Foundation

extension WorkspaceLayout {
    @discardableResult mutating func selectProjectWorkspace(projectPaneIDs: Set<String>) throws -> String {
        let openWorkspaces = Set(workspaces.filter { !$0.closed }.map(\.id))
        if let existing = tabs.first(where: { tab in
            guard let workspaceID = tab.workspaceID, openWorkspaces.contains(workspaceID) else { return false }
            return tab.panes.contains(where: projectPaneIDs.contains)
        })?.workspaceID {
            try selectWorkspace(existing)
            return existing
        }
        return addWorkspace(title: randomWorkspaceTitle())
    }
}
