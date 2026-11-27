import Foundation

public struct NavigationRequest: Codable {
    public var id = UUID().uuidString
    public var workspaceID: String
    public var tabID: String?
    public var paneID: String?
    public init(workspaceID: String, tabID: String? = nil, paneID: String? = nil) {
        self.workspaceID = workspaceID; self.tabID = tabID; self.paneID = paneID
    }
}

public struct WindowSelection {
    public private(set) var workspaceID: String?
    private var lastRequestID: String?
    private var initialized = false
    public init() {}

    public mutating func resolve(_ snapshot: RuntimeState, ownAction: Bool, acceptsRequests: Bool) -> RuntimeState {
        var state = snapshot
        let request = state.navigationRequest
        let requested = initialized && request?.id != lastRequestID && acceptsRequests && request.map { request in
            state.layout.workspaces.contains { $0.id == request.workspaceID && !$0.closed }
        } == true
        lastRequestID = request?.id
        if !initialized || ownAction { workspaceID = state.layout.selectedWorkspaceID }
        else if requested, let request, let master = state.layout.masterView, workspaceID == master.workspaceID,
                let tabID = request.tabID ?? request.paneID.flatMap({ pane in state.layout.tabs.first { $0.panes.contains(pane) }?.id }),
                master.tabIDs.contains(tabID) {
            // A window showing the Master View keeps it while opening a session the view already presents.
            try? state.layout.selectWorkspace(master.workspaceID)
            try? state.layout.selectTab(tabID)
            if let paneID = request.paneID, state.layout.tabs.contains(where: { $0.id == tabID && $0.panes.contains(paneID) }) {
                try? state.layout.focusPane(paneID)
            }
        } else if requested, let request {
            try? state.layout.selectWorkspace(request.workspaceID)
            if let tabID = request.tabID, state.layout.tabs.contains(where: { $0.id == tabID && $0.workspaceID == request.workspaceID }) {
                try? state.layout.selectTab(tabID)
            }
            if let paneID = request.paneID, state.layout.tabs.contains(where: { $0.workspaceID == request.workspaceID && $0.panes.contains(paneID) }) {
                try? state.layout.focusPane(paneID)
            }
        } else if let workspaceID, state.layout.workspaces.contains(where: { $0.id == workspaceID && !$0.closed }) {
            try? state.layout.selectWorkspace(workspaceID)
        } else if let workspaceID, state.layout.workspaces.contains(where: { $0.id == workspaceID && $0.closed }),
                  let next = state.layout.nextOpenWorkspace(after: workspaceID) {
            try? state.layout.selectWorkspace(next.id)
        }
        if !state.layout.workspaces.contains(where: { $0.id == state.layout.selectedWorkspaceID && !$0.closed }) {
            if let next = state.layout.workspaces.first(where: { !$0.closed }) { try? state.layout.selectWorkspace(next.id) }
            else {
                state.layout.selectedWorkspaceID = nil
                state.layout.selectedTabID = nil
                state.layout.focusedPaneID = nil
            }
        }
        workspaceID = state.layout.selectedWorkspaceID
        initialized = true
        return state
    }
}
