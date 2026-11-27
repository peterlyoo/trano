import Foundation

extension TerminalRuntime {
    func performClosedTerminalAction(_ action: ActionID, workspaceID: String?, tabID: String?, paneID: String?, requestNavigation: Bool) throws -> Bool {
        guard [.closePane, .closeTab, .closeOtherPanes, .closeOtherTabs, .closeTabsToLeft, .closeTabsToRight, .restoreTab].contains(action) else { return false }
        var selected = try state().layout
        if let workspaceID { try selected.selectWorkspace(workspaceID) }
        if let tabID {
            guard workspaceID == nil || selected.currentTabs.contains(where: { $0.id == tabID }) else { throw TerminalError.invalid("Tab does not belong to workspace") }
            try selected.selectTab(tabID)
        }
        if let paneID {
            guard workspaceID == nil || selected.currentTabs.contains(where: { $0.panes.contains(paneID) }),
                  tabID == nil || selected.tabs.first(where: { $0.id == tabID })?.panes.contains(paneID) == true else { throw TerminalError.invalid("Pane does not belong to target") }
            try selected.focusPane(paneID)
        }
        switch action {
        case .closePane: if let id = selected.focusedPaneID { try closeTerminalPane(id) }
        case .closeTab: if let id = selected.selectedTabID { try closeTerminalTab(id) }
        case .closeOtherPanes: if let id = selected.focusedPaneID { try closeOtherTerminalPanes(keeping: id) }
        case .closeOtherTabs: if let id = selected.selectedTabID { try closeOtherTerminalTabs(keeping: id) }
        case .closeTabsToLeft: if let id = selected.selectedTabID { try closeTerminalTabs(beside: id, side: .left) }
        case .closeTabsToRight: if let id = selected.selectedTabID { try closeTerminalTabs(beside: id, side: .right) }
        case .restoreTab: try restoreClosedTerminal()
        default: break
        }
        if requestNavigation {
            try update { state in
                if let workspace = state.layout.selectedWorkspaceID {
                    state.navigationRequest = NavigationRequest(workspaceID: workspace, tabID: state.layout.selectedTabID, paneID: state.layout.focusedPaneID)
                }
            }
        }
        return true
    }
}
