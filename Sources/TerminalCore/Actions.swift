import Foundation

public enum ActionID: String, Codable, CaseIterable {
    case newWindow = "client.window.new", fullscreen = "client.window.fullscreen.toggle"
    case palette = "client.palette.toggle", settings = "client.settings"
    case newSession = "session.new", switchSession = "session.switch", nextSession = "session.next", previousSession = "session.previous", renameSession = "session.rename", closeSession = "session.close", refresh = "session.refresh"
    case restoreSessions = "session.restore"
    case newTab = "client.tab.new", closeTab = "client.tab.close", closeOtherTabs = "client.tab.close_others", restoreTab = "client.tab.restore", renameTab = "client.tab.rename", nextTab = "client.tab.next", previousTab = "client.tab.previous", moveTabBackward = "client.tab.move.backward", moveTabForward = "client.tab.move.forward"
    case splitRight = "pane.split.right", splitDown = "pane.split.down", splitLeft = "pane.split.left", splitUp = "pane.split.up"
    case focusLeft = "pane.focus.left", focusRight = "pane.focus.right", focusUp = "pane.focus.up", focusDown = "pane.focus.down", nextPane = "pane.focus_next", previousPane = "pane.focus_previous"
    case zoom = "pane.zoom", closePane = "pane.close", closeOtherPanes = "pane.close_others", balance = "pane.balance"
    case resizeLeft = "pane.resize.left", resizeRight = "pane.resize.right", resizeUp = "pane.resize.up", resizeDown = "pane.resize.down"
    case movePaneNewTab = "pane.move_to_new_tab", movePaneTab = "pane.move_to_tab", renamePane = "pane.rename", copyPaneID = "pane.copy_id"
    case insertPath = "pane.insert_path", goToDirectory = "pane.go_to_directory", goToAnything = "pane.go_to", activity = "pane.view_activity"
    case copy = "pane.copy", paste = "pane.paste", selectAll = "pane.select_all", clear = "terminal.clear", find = "terminal.find", findNext = "terminal.find.next", findPrevious = "terminal.find.previous"
    case increaseFont = "font.increase", decreaseFont = "font.decrease", resetFont = "font.reset", voice = "input.voice"
}

public struct TerminalAction: Encodable, Identifiable {
    public let action: ActionID
    public var id: String { action.rawValue }
    public let title: String
    public let category: String
    public let keywords: String
    public let bindings: [String]
    public let requiresUI: Bool
    public var shortcut: String {
        guard let binding = bindings.first else { return "" }
        return binding.replacingOccurrences(of: "cmd+", with: "⌘").replacingOccurrences(of: "shift+", with: "⇧")
            .replacingOccurrences(of: "ctrl+", with: "⌃").replacingOccurrences(of: "alt+", with: "⌥").uppercased()
    }
    init(_ action: ActionID, _ title: String, _ category: String, _ keys: [String] = [], ui: Bool = false, keywords: String = "") {
        self.action = action; self.title = title; self.category = category; bindings = keys; requiresUI = ui; self.keywords = keywords
    }
    private enum CodingKeys: String, CodingKey { case id, title, category, keywords, bindings, requiresUI }
    public func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(id, forKey: .id); try box.encode(title, forKey: .title)
        try box.encode(category, forKey: .category); try box.encode(keywords, forKey: .keywords)
        try box.encode(bindings, forKey: .bindings); try box.encode(requiresUI, forKey: .requiresUI)
    }
}

public enum ActionCatalog {
    public static let all: [TerminalAction] = [
        .init(.newWindow, "New Window", "Window", ["cmd+n"], ui: true),
        .init(.fullscreen, "Toggle Full Screen", "Window", ["cmd+enter", "cmd+ctrl+f"], ui: true),
        .init(.newSession, "New Session", "Session", ["cmd+shift+n"]),
        .init(.switchSession, "Change Session…", "Session", ["cmd+k"], ui: true, keywords: "workspace search switch"),
        .init(.nextSession, "Next Session", "Session", ["cmd+alt+]"]),
        .init(.previousSession, "Previous Session", "Session", ["cmd+alt+["]),
        .init(.renameSession, "Rename Session…", "Session", ui: true),
        .init(.closeSession, "Close Session View", "Session"),
        .init(.refresh, "Refresh Sessions", "Session"),
        .init(.restoreSessions, "Restore Sessions", "Session"),
        .init(.newTab, "New Tab", "Tab", ["cmd+t"]),
        .init(.closeTab, "Close Tab · keep running", "Tab", ["cmd+shift+w"]),
        .init(.closeOtherTabs, "Close Other Tabs · keep running", "Tab"),
        .init(.restoreTab, "Reopen Closed Tab", "Tab", ["cmd+shift+t"]),
        .init(.renameTab, "Rename Tab…", "Tab", ui: true),
        .init(.nextTab, "Show Next Tab", "Tab", ["cmd+shift+]", "ctrl+tab"]),
        .init(.previousTab, "Show Previous Tab", "Tab", ["cmd+shift+[", "ctrl+shift+tab"]),
        .init(.moveTabBackward, "Move Tab Backward", "Tab"),
        .init(.moveTabForward, "Move Tab Forward", "Tab"),
        .init(.splitRight, "Split Pane Right", "Pane", ["cmd+d"]),
        .init(.splitDown, "Split Pane Down", "Pane", ["cmd+shift+d"]),
        .init(.splitLeft, "Split Pane Left", "Pane"),
        .init(.splitUp, "Split Pane Up", "Pane"),
        .init(.focusLeft, "Focus Pane Left", "Pane", ["cmd+alt+left"], ui: true),
        .init(.focusRight, "Focus Pane Right", "Pane", ["cmd+alt+right"], ui: true),
        .init(.focusUp, "Focus Pane Up", "Pane", ["cmd+alt+up"], ui: true),
        .init(.focusDown, "Focus Pane Down", "Pane", ["cmd+alt+down"], ui: true),
        .init(.nextPane, "Focus Next Pane", "Pane", ["cmd+]"]),
        .init(.previousPane, "Focus Previous Pane", "Pane", ["cmd+["]),
        .init(.zoom, "Zoom Pane", "Pane", ["cmd+shift+enter"], ui: true),
        .init(.closePane, "Close Pane · keep running", "Pane", ["cmd+w"]),
        .init(.closeOtherPanes, "Close Other Panes · keep running", "Pane"),
        .init(.balance, "Balance Splits", "Pane"),
        .init(.resizeLeft, "Resize Pane Left", "Pane", ["cmd+ctrl+left"], ui: true),
        .init(.resizeRight, "Resize Pane Right", "Pane", ["cmd+ctrl+right"], ui: true),
        .init(.resizeUp, "Resize Pane Up", "Pane", ["cmd+ctrl+up"], ui: true),
        .init(.resizeDown, "Resize Pane Down", "Pane", ["cmd+ctrl+down"], ui: true),
        .init(.movePaneNewTab, "Move Pane to New Tab", "Pane"),
        .init(.movePaneTab, "Move Pane to Tab…", "Pane", ui: true),
        .init(.renamePane, "Rename Pane…", "Pane", ui: true),
        .init(.copyPaneID, "Copy Pane ID", "Pane", ui: true),
        .init(.insertPath, "Insert Path…", "Input", ui: true, keywords: "file folder directory path cursor insert paste"),
        .init(.goToDirectory, "Go to Directory…", "Input", ui: true, keywords: "folder new tab cwd"),
        .init(.goToAnything, "Go to Anything…", "Navigation", ["cmd+p"], ui: true, keywords: "pane tab session workspace search"),
        .init(.activity, "Show Activity", "Navigation", ui: true),
        .init(.copy, "Copy", "Edit", ["cmd+c"], ui: true),
        .init(.paste, "Paste", "Edit", ["cmd+v"], ui: true),
        .init(.selectAll, "Select All", "Edit", ["cmd+a"], ui: true),
        .init(.clear, "Clear Local Scrollback", "Edit", ui: true),
        .init(.find, "Find in Terminal…", "Edit", ["cmd+f"], ui: true),
        .init(.findNext, "Find Next", "Edit", ["cmd+g"], ui: true),
        .init(.findPrevious, "Find Previous", "Edit", ["cmd+shift+g"], ui: true),
        .init(.increaseFont, "Increase Font Size", "Appearance", ["cmd+=", "cmd+shift+="]),
        .init(.decreaseFont, "Decrease Font Size", "Appearance", ["cmd+-"]),
        .init(.resetFont, "Reset Font Size", "Appearance", ["cmd+0"]),
        .init(.voice, "Voice Input…", "Input", ui: true),
        .init(.palette, "Command Palette…", "App", ["cmd+shift+p"], ui: true),
        .init(.settings, "Settings…", "App", ["cmd+,"], ui: true)
    ]
    public static func action(for binding: String) -> TerminalAction? { all.first { $0.bindings.contains(binding) } }
    public static func resolved(overrides: [String: [String]]) throws -> [TerminalAction] {
        let map = try KeyBindingMap(overrides: overrides)
        return all.map { action in
            TerminalAction(action.action, action.title, action.category, map.bindings[action.id] ?? [], ui: action.requiresUI, keywords: action.keywords)
        }
    }
}

extension TerminalRuntime {
    public func performAction(_ action: ActionID, cwd: String? = nil, title: String? = nil, workspaceID: String? = nil, tabID: String? = nil, paneID: String? = nil, requestNavigation: Bool = false) throws {
        guard let definition = ActionCatalog.all.first(where: { $0.action == action }), !definition.requiresUI else { throw TerminalError.invalid("requiresUI: This action needs an active Trano window") }
        let sessionTitle = action == .newSession ? try WorkspaceLayout.normalizedSessionTitle(title) : nil
        var restoreNavigation: NavigationRequest?
        try transaction {
            if workspaceID != nil || tabID != nil || paneID != nil {
                try update { state in
                    if let workspaceID { try state.layout.selectWorkspace(workspaceID) }
                    if let tabID {
                        guard workspaceID == nil || state.layout.currentTabs.contains(where: { $0.id == tabID }) else { throw TerminalError.invalid("Tab does not belong to workspace") }
                        try state.layout.selectTab(tabID)
                    }
                    if let paneID {
                        guard (workspaceID == nil || state.layout.currentTabs.contains(where: { $0.panes.contains(paneID) })),
                              (tabID == nil || state.layout.tabs.first(where: { $0.id == tabID })?.panes.contains(paneID) == true) else { throw TerminalError.invalid("Pane does not belong to target") }
                        try state.layout.focusPane(paneID)
                    }
                }
            }
            if action != .restoreSessions { try performSelectedAction(action, cwd: cwd, title: sessionTitle) }
            if requestNavigation && definition.category != "Appearance" {
                try update { state in
                    if let workspace = state.layout.selectedWorkspaceID {
                        let request = NavigationRequest(workspaceID: workspace, tabID: state.layout.selectedTabID, paneID: state.layout.focusedPaneID)
                        if action == .restoreSessions { restoreNavigation = request }
                        else { state.navigationRequest = request }
                    }
                }
            }
        }
        if action == .restoreSessions {
            _ = try recoverSessions()
            if let restoreNavigation {
                try update { state in
                    if state.layout.workspaces.contains(where: { $0.id == restoreNavigation.workspaceID }) {
                        state.navigationRequest = restoreNavigation
                    }
                }
            }
        }
    }

    private func openSession(title: String?, cwd: String?) throws {
        let before = try state()
        let name = title ?? before.layout.nextSessionTitle()
        let existing = before.layout.workspace(named: name)
        if let existing, before.layout.tabs.contains(where: { $0.workspaceID == existing.id }) {
            try update { try $0.layout.selectWorkspace(existing.id) }
            return
        }
        let focused = before.sessions.first { $0.id == before.layout.focusedPaneID }
        let directory: String
        if focused?.remote != nil { directory = FileManager.default.homeDirectoryForCurrentUser.path }
        else if let cwd { directory = cwd }
        else if let focused { directory = try workingDirectory(focused.id) }
        else { directory = FileManager.default.homeDirectoryForCurrentUser.path }
        let pane = try create(title: URL(fileURLWithPath: directory).lastPathComponent, cwd: directory)
        do {
            try update { state in
                if let existing { try state.layout.selectWorkspace(existing.id) }
                else { state.layout.addWorkspace(title: name) }
                state.layout.addTab(paneID: pane.id)
            }
        } catch { try? terminate(pane.id); throw error }
    }

    private func performSelectedAction(_ action: ActionID, cwd: String?, title: String?) throws {
        if action == .newSession { try openSession(title: title, cwd: cwd); return }
        if [.newTab, .splitRight, .splitDown, .splitLeft, .splitUp].contains(action) {
            let before = try state()
            let focused = before.sessions.first { $0.id == before.layout.focusedPaneID }
            let remote = focused?.remote
            let liveDirectory = try before.layout.focusedPaneID.map { try workingDirectory($0) }
            let directory = cwd ?? liveDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
            let pane: TerminalSession
            if let remote { pane = try createRemoteSession(hostID: remote.hostID, cwd: directory, attachToLayout: false) }
            else { pane = try create(title: URL(fileURLWithPath: directory).lastPathComponent, cwd: directory) }
            do {
                try update { store in
                    if [.splitRight, .splitDown, .splitLeft, .splitUp].contains(action), let tab = store.layout.selectedTabID {
                        try store.layout.split(tabID: tab, paneID: pane.id, axis: [.splitDown, .splitUp].contains(action) ? .vertical : .horizontal, before: [.splitLeft, .splitUp].contains(action))
                    } else { store.layout.addTab(paneID: pane.id) }
                }
            } catch { try? terminate(pane.id); throw error }
            return
        }
        if action == .refresh { return }
        try update { state in
            switch action {
            case .nextSession: state.layout.cycleWorkspace(1)
            case .previousSession: state.layout.cycleWorkspace(-1)
            case .nextTab: state.layout.cycleTab(1)
            case .previousTab: state.layout.cycleTab(-1)
            case .closeTab: if let id = state.layout.selectedTabID { state.layout.closeTab(id) }
            case .closeSession: if let id = state.layout.selectedWorkspaceID { state.layout.closeWorkspace(id) }
            case .closeOtherTabs:
                for tab in state.layout.currentTabs where tab.id != state.layout.selectedTabID { state.layout.closeTab(tab.id) }
            case .restoreTab: state.layout.restoreTab()
            case .moveTabBackward, .moveTabForward:
                if let id = state.layout.selectedTabID { state.layout.reorderTab(id, delta: action == .moveTabBackward ? -1 : 1) }
            case .closePane: if let id = state.layout.focusedPaneID { state.layout.detach(id) }
            case .closeOtherPanes:
                let panes = state.layout.tabs.first { $0.id == state.layout.selectedTabID }?.panes ?? []
                for id in panes where id != state.layout.focusedPaneID { state.layout.detach(id) }
            case .movePaneNewTab:
                if let id = state.layout.focusedPaneID { state.layout.detach(id); state.layout.addTab(paneID: id) }
            case .nextPane, .previousPane:
                let panes = state.layout.tabs.first { $0.id == state.layout.selectedTabID }?.panes ?? []
                if let index = panes.firstIndex(of: state.layout.focusedPaneID ?? ""), !panes.isEmpty { try state.layout.focusPane(panes[(index + (action == .nextPane ? 1 : -1) + panes.count) % panes.count]) }
            case .balance:
                if let index = state.layout.tabs.firstIndex(where: { $0.id == state.layout.selectedTabID }) { state.layout.tabs[index].tree = state.layout.tabs[index].tree.balanced }
            case .increaseFont, .decreaseFont, .resetFont:
                let change: (Double) -> Double = { size in
                    action == .resetFont ? 14 : min(40, max(9, size + (action == .increaseFont ? 1 : -1)))
                }
                if let paneID = state.layout.focusedPaneID, let profileID = state.settings.paneAppearanceProfiles[paneID],
                   let index = state.settings.appearanceProfiles.firstIndex(where: { $0.id == profileID }) {
                    state.settings.appearanceProfiles[index].fontSize = change(state.settings.appearanceProfiles[index].fontSize)
                } else { state.settings.fontSize = change(state.settings.fontSize) }
            default: throw TerminalError.invalid("Unsupported action")
            }
        }
    }
}
