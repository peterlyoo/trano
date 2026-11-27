import Foundation

extension WorkspaceLayout {
    public mutating func transferTab(_ tabID: String, from sourceWorkspaceID: String, to destinationWorkspaceID: String, before targetTabID: String? = nil) throws {
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == tabID && $0.workspaceID == sourceWorkspaceID }),
              workspaces.contains(where: { $0.id == sourceWorkspaceID && !$0.closed }),
              workspaces.contains(where: { $0.id == destinationWorkspaceID && !$0.closed }) else {
            throw TerminalError.invalid("The dragged tab or destination workspace is no longer available")
        }
        if let targetTabID {
            guard tabs.contains(where: { $0.id == targetTabID && $0.workspaceID == destinationWorkspaceID }) else {
                throw TerminalError.invalid("The destination tab is no longer available")
            }
        }
        if tabID == targetTabID { try selectTab(tabID); return }
        var next = self
        var tab = next.tabs.remove(at: sourceIndex)
        tab.workspaceID = destinationWorkspaceID
        let insertion: Int
        if let targetTabID, let index = next.tabs.firstIndex(where: { $0.id == targetTabID }) {
            insertion = index
        } else if let last = next.tabs.lastIndex(where: { $0.workspaceID == destinationWorkspaceID }) {
            insertion = last + 1
        } else { insertion = next.tabs.endIndex }
        next.tabs.insert(tab, at: insertion)
        next.repairTransferSelection(in: sourceWorkspaceID)
        try next.selectTab(tabID)
        self = next
    }

    @discardableResult public mutating func transferPane(_ paneID: String, from sourceTabID: String, sourceWorkspaceID: String, to destinationWorkspaceID: String, tabID targetTabID: String?) throws -> String {
        guard tabs.contains(where: { $0.id == sourceTabID && $0.workspaceID == sourceWorkspaceID && $0.panes.contains(paneID) }),
              workspaces.contains(where: { $0.id == sourceWorkspaceID && !$0.closed }),
              workspaces.contains(where: { $0.id == destinationWorkspaceID && !$0.closed }) else {
            throw TerminalError.invalid("The dragged pane or destination workspace is no longer available")
        }
        if let targetTabID {
            guard tabs.contains(where: { $0.id == targetTabID && $0.workspaceID == destinationWorkspaceID }) else {
                throw TerminalError.invalid("The destination tab is no longer available")
            }
        }
        if sourceTabID == targetTabID { try focusPane(paneID); return sourceTabID }
        var next = self
        let result: String
        if let targetTabID {
            try next.move(paneID: paneID, to: targetTabID)
            result = targetTabID
        } else {
            next.detach(paneID)
            next.repairTransferSelection(in: sourceWorkspaceID)
            try next.selectWorkspace(destinationWorkspaceID)
            result = next.addTab(paneID: paneID)
        }
        next.repairTransferSelection(in: sourceWorkspaceID)
        self = next
        return result
    }

    private mutating func repairTransferSelection(in workspaceID: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        let available = tabs.filter { $0.workspaceID == workspaceID }
        let selected = available.first { $0.id == workspaces[index].selectedTabID } ?? available.first
        let focused = selected?.panes.contains(workspaces[index].focusedPaneID ?? "") == true
            ? workspaces[index].focusedPaneID : selected?.focusedPaneID ?? selected?.panes.first
        workspaces[index].selectedTabID = selected?.id
        workspaces[index].focusedPaneID = focused
        if selectedWorkspaceID == workspaceID {
            selectedTabID = selected?.id
            focusedPaneID = focused
        }
    }
}
