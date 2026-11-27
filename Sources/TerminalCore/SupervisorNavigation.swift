import Foundation

public enum SupervisorNavigationError: Error, LocalizedError {
    case requiresPanel(String)
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .requiresPanel: return "This session belongs to the dedicated Supervisor panel."
        case .unavailable: return "Supervisor reservation is unavailable. Existing workspace panes remain accessible."
        }
    }
}

public enum SupervisorNavigationGuard {
    public static func requireOrdinaryPane(_ paneID: String, reservation: SupervisorPaneReservation,
                                           attachedPaneIDs: Set<String>) throws {
        switch reservation {
        case .bound(let reserved) where reserved == paneID: throw SupervisorNavigationError.requiresPanel(paneID)
        case .unavailable where !attachedPaneIDs.contains(paneID): throw SupervisorNavigationError.unavailable
        default: return
        }
    }
}
