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
        let requested = initialized && request?.id != lastRequestID && request != nil && acceptsRequests
        lastRequestID = request?.id
        if !initialized || ownAction { workspaceID = state.layout.selectedWorkspaceID }
        else if requested, let request {
            try? state.layout.selectWorkspace(request.workspaceID)
            if let tabID = request.tabID { try? state.layout.selectTab(tabID) }
            if let paneID = request.paneID { try? state.layout.focusPane(paneID) }
            workspaceID = state.layout.selectedWorkspaceID
        } else if let workspaceID { try? state.layout.selectWorkspace(workspaceID) }
        initialized = true
        return state
    }
}
