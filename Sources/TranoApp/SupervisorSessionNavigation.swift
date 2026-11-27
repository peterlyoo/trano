import AppKit
import Combine
import TerminalCore

struct SupervisorNavigationSelection: Equatable, Sendable {
    let workspaceID: String?
    let tabID: String?
    let paneID: String?
    init(workspaceID: String?, tabID: String?, paneID: String?) {
        self.workspaceID = workspaceID; self.tabID = tabID; self.paneID = paneID
    }
    init(_ layout: WorkspaceLayout) {
        self.init(workspaceID: layout.selectedWorkspaceID, tabID: layout.selectedTabID, paneID: layout.focusedPaneID)
    }
}

struct SupervisorNavigationRequest: @unchecked Sendable {
    let authority: SupervisorContinuationAuthority
    let target: SupervisorContinuationIdentity
}

enum SupervisorSessionNavigation {
    static func open(_ target: SupervisorContinuationIdentity, workspaceID: String?, state: RuntimeState,
                     sessions: [TerminalSession]) throws -> RuntimeState {
        let panes = sessions.filter { $0.id == target.paneID }
        let launches = state.agentLaunches.filter { $0.paneID == target.paneID && $0.lifecycle == .active }
        guard panes.count == 1, let pane = panes.first, pane.alive, pane.remote == nil, pane.pid == target.backendPID,
              launches.count == 1, let launch = launches.first, launch.id == target.generation,
              launch.provider == target.provider, launch.providerPID == target.providerPID,
              launch.providerSessionID == target.providerSessionID, launch.configurationRoot == target.configurationRoot,
              launch.cwd == target.cwd, launch.accountID == target.accountID else {
            throw TerminalError.invalid("The session identity changed before navigation.")
        }
        var next = state
        if !next.layout.tabs.contains(where: { $0.panes.contains(target.paneID) }) {
            if let index = next.layout.closedTabs.lastIndex(where: { snapshot in
                snapshot.panes.contains(target.paneID) &&
                    (!next.layout.tabs.contains { $0.id == snapshot.id } || snapshot.focusedPaneID == target.paneID)
            }) {
                let tab = next.layout.closedTabs.remove(at: index)
                next.layout.closedTabs.append(tab)
                next.layout.restoreTab()
            }
            if !next.layout.tabs.contains(where: { $0.panes.contains(target.paneID) }) {
                if let workspaceID, next.layout.workspaces.contains(where: { $0.id == workspaceID && !$0.closed }) {
                    try next.layout.selectWorkspace(workspaceID)
                } else if let open = next.layout.workspaces.first(where: { !$0.closed }) {
                    try next.layout.selectWorkspace(open.id)
                } else { next.layout.addWorkspace(title: next.layout.randomWorkspaceTitle()) }
                next.layout.addTab(paneID: target.paneID)
            }
        }
        let attached = next.layout.tabs.filter { $0.panes.contains(target.paneID) }
        guard attached.count == 1, let tab = attached.first,
              next.layout.workspaces.contains(where: { $0.id == tab.workspaceID }) else {
            throw TerminalError.invalid("The session's retained view is unavailable.")
        }
        try next.layout.selectTab(tab.id)
        try next.layout.focusPane(target.paneID)
        return next
    }
}

@MainActor final class SupervisorNavigationInput {
    private weak var window: NSWindow?
    private weak var responder: NSResponder?
    init(_ window: NSWindow) { self.window = window; responder = window.firstResponder }
    var isCurrent: Bool {
        guard let window, window.isVisible, !window.isMiniaturized, window.attachedSheet == nil, NSApp.modalWindow == nil,
              window.firstResponder === responder,
              (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return false }
        return true
    }
}

final class SupervisorNavigationLease: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    private var observers: [NSObjectProtocol] = []
    private var subscriptions: [AnyCancellable] = []
    var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
    func invalidate() { lock.lock(); valid = false; lock.unlock() }
    @MainActor func retain(_ subscription: AnyCancellable) { subscriptions.append(subscription) }
    @MainActor func watch(_ windows: [NSWindow], isCurrent: @escaping @MainActor () -> Bool) {
        let center = NotificationCenter.default
        for window in windows {
            for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification, NSWindow.didResignKeyNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.invalidate() })
            }
            observers.append(center.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if !isCurrent() { self?.invalidate() } }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.invalidate() })
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
}
