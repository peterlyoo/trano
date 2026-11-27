import AppKit
import SwiftUI
import TerminalCore

struct HeaderMenuContext {
    let workspaceID: String?
    let tabID: String?
    let paneID: String?

    func matches(_ layout: WorkspaceLayout) -> Bool {
        if let workspaceID {
            guard layout.workspaces.contains(where: { $0.id == workspaceID && !$0.closed }) else { return false }
        } else if layout.selectedWorkspaceID != nil { return false }
        if let tabID {
            guard let tab = layout.tabs.first(where: { $0.id == tabID && $0.workspaceID == workspaceID }),
                  paneID == nil || tab.panes.contains(paneID!) else { return false }
        }
        return true
    }
}

extension AppStore {
    var headerMenuAllowsActions: Bool {
        !loading && conversationResume == nil && decisionPaneID == nil && followUpPaneID == nil && picker == nil && !showSettings &&
        !showVoice && !showRemoteHosts && !showAccounts && !showExtensions && remotePathRequest == nil && message == nil
    }

    func headerContextMenu(tabID: String? = nil, customizeViewOnly: Bool = false, showProfiles: @escaping () -> Void = {}, sourceWindow: NSWindow? = nil) -> NSMenu {
        // A tab the Master View presents belongs to another session; session-level actions target the Master View itself.
        let tab = tabID.flatMap { id in state.layout.tabs.first { $0.id == id } }
            ?? (tabID == nil ? selectedTab.flatMap { state.layout.isPresentedInMasterView($0.id) ? nil : $0 } : nil)
        let context = HeaderMenuContext(workspaceID: tab?.workspaceID ?? state.layout.selectedWorkspaceID,
                                        tabID: tabID ?? tab?.id, paneID: tab?.focusedPaneID ?? tab?.panes.first)
        // Session-level actions on a tab the Master View presents target the Master View, never the hidden source session.
        let presented = tab.map { state.layout.isPresentedInMasterView($0.id) } == true
        let session = presented ? HeaderMenuContext(workspaceID: state.layout.selectedWorkspaceID, tabID: nil, paneID: nil) : context
        let allowed = headerMenuAllowsActions && context.matches(state.layout) && session.matches(state.layout)
        let ownsWindow = sourceWindow != nil
        weak var owner = sourceWindow
        let map = try? TerminalKeySequenceMap(overrides: state.settings.keyBindings)
        func menu(_ title: String = "") -> NSMenu {
            let value = NSMenu(title: title)
            value.autoenablesItems = false
            return value
        }
        func item(_ id: String, _ title: String, action: ActionID? = nil, image: String? = nil,
                  enabled: Bool = true, scope: HeaderMenuContext? = nil, run: @escaping (AppStore) -> Void) -> NSMenuItem {
            let target = scope ?? context
            let value = HeaderMenuItem(title: title, action: #selector(HeaderMenuItem.invoke(_:)), keyEquivalent: "")
            value.identifier = NSUserInterfaceItemIdentifier(id)
            value.target = value
            value.isEnabled = allowed && enabled
            if let image { value.image = NSImage(systemSymbolName: image, accessibilityDescription: nil) }
            if let action {
                let key = NativeKeyBinding.menuEquivalent(map?.singles.bindings[action.rawValue]?.first ?? "")
                value.keyEquivalent = key.0; value.keyEquivalentModifierMask = key.1
            }
            value.onInvoke = { [weak self] in
                guard let self, self.headerMenuAllowsActions, target.matches(self.state.layout),
                      !ownsWindow || (owner?.isVisible == true && owner?.attachedSheet == nil),
                      (owner?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return }
                run(self)
            }
            return value
        }
        func change(_ store: AppStore, takeSelection: Bool = false, requiresUnmarkedInput: Bool = false, scope: HeaderMenuContext? = nil,
                    _ work: @escaping (TerminalRuntime) throws -> Void) {
            store.performHeaderAction(context: scope ?? context, takeSelection: takeSelection, requiresUnmarkedInput: requiresUnmarkedInput, work)
        }
        let result = menu()
        result.addItem(item("header-new-tab", "New Tab", action: .newTab, image: "plus", scope: session) { store in
            change(store, takeSelection: true, scope: session) { try $0.performAction(.newTab, workspaceID: session.workspaceID, tabID: session.tabID) }
        })
        result.addItem(.separator())
        result.addItem(item("header-rename-session", "Rename Session…", enabled: session.workspaceID != nil, scope: session) { $0.rename(.renameSession, target: session.workspaceID, headerContext: session) })
        result.addItem(item("header-close-session", "Close Session", enabled: session.workspaceID != nil, scope: session) { store in
            guard let id = session.workspaceID else { return }
            store.commandKeyHints.cancel()
            store.zoomed = false
            change(store, requiresUnmarkedInput: true, scope: session) { try $0.update { $0.layout.closeWorkspace(id) } }
        })
        let isMaster = session.workspaceID != nil && state.layout.masterView?.workspaceID == session.workspaceID
        let master = item("header-master-view", "Use as Master View", image: "tray.full", enabled: session.workspaceID != nil, scope: session) { store in
            guard let id = session.workspaceID else { return }
            change(store, scope: session) { try $0.setMasterWorkspace(isMaster ? nil : id) }
        }
        master.state = isMaster ? .on : .off
        master.toolTip = "Show every session that finished or needs a decision in this session"
        result.addItem(master)
        result.addItem(.separator())
        result.addItem(item("header-new-session", "New Session", action: .newSession, image: "square.stack.3d.up") { store in
            change(store, takeSelection: true) { try $0.performAction(.newSession, workspaceID: context.workspaceID) }
        })
        result.addItem(item("header-add-remote-host", "Add Remote Host…", image: "network") { $0.openRemoteHosts() })
        result.addItem(.separator())
        let customize = menu("Customize View")
        for toolbarItem in InterfaceToolbarItem.allCases {
            let visible = interfacePreferences.showsToolbarItem(toolbarItem)
            let entry = item("header-toolbar-" + toolbarItem.rawValue, toolbarItem.title) { store in
                store.setToolbarItem(toolbarItem, visible: !visible)
            }
            entry.state = visible ? .on : .off
            customize.addItem(entry)
        }
        if customizeViewOnly { return customize }
        customize.addItem(.separator())
        customize.addItem(item("header-appearance", "Appearance…", action: .settings, image: "paintpalette") { store in
            store.showActivity = false
            store.showSettings = true
        })
        let profiles = menu("Appearance Profile")
        let selected = context.paneID.flatMap { state.settings.paneAppearanceProfiles[$0] }
        func profileItem(_ id: String?, name: String) -> NSMenuItem {
            let value = item("header-profile-" + (id ?? "default"), name, enabled: context.paneID != nil) { store in
                guard let pane = context.paneID else { return }
                change(store) { try $0.setAppearanceProfile(id, paneID: pane) }
            }
            value.state = selected == id ? .on : .off
            return value
        }
        profiles.addItem(profileItem(nil, name: "Default"))
        for profile in state.settings.appearanceProfiles { profiles.addItem(profileItem(profile.id, name: profile.name)) }
        profiles.addItem(.separator())
        profiles.addItem(item("header-manage-profiles", "Manage Profiles…") { store in store.showActivity = false; showProfiles() })
        let profileParent = NSMenuItem(title: "Appearance Profile", action: nil, keyEquivalent: "")
        profileParent.identifier = NSUserInterfaceItemIdentifier("header-profiles")
        profileParent.isEnabled = allowed; profileParent.submenu = profiles
        customize.addItem(profileParent)
        customize.addItem(.separator())
        let sidebar = item("header-sidebar", "Sessions Sidebar", image: "sidebar.left") { $0.showSessionsSidebar.toggle() }
        sidebar.state = showSessionsSidebar ? .on : .off
        customize.addItem(sidebar)
        let customizeParent = NSMenuItem(title: "Customize View", action: nil, keyEquivalent: "")
        customizeParent.identifier = NSUserInterfaceItemIdentifier("header-customize-view")
        customizeParent.isEnabled = allowed; customizeParent.submenu = customize
        result.addItem(customizeParent)
        if let tabID {
            result.addItem(.separator())
            result.addItem(item("header-rename-tab", "Rename Tab…", enabled: tab != nil) { $0.rename(.renameTab, target: tabID, headerContext: context) })
            result.addItem(item("header-move-tab-backward", "Move Tab Backward", enabled: tab != nil && !presented) { store in
                change(store) { try $0.update { try $0.layout.reorderTab(tabID, delta: -1) } }
            })
            result.addItem(item("header-move-tab-forward", "Move Tab Forward", enabled: tab != nil && !presented) { store in
                change(store) { try $0.update { try $0.layout.reorderTab(tabID, delta: 1) } }
            })
            let siblings = tab.map { current in state.layout.tabs.filter { $0.workspaceID == current.workspaceID && $0.id != current.id }.count } ?? 0
            let closes: [(String, String, ActionID, Bool)] = [
                ("header-close-tab", "Close Tab", .closeTab, tab != nil),
                ("header-close-other-tabs", "Close Other Tabs", .closeOtherTabs, !presented && siblings > 0),
                ("header-close-tabs-right", "Close Tabs to the Right", .closeTabsToRight, !presented && !state.layout.tabIDs(beside: tabID, side: .right).isEmpty),
                ("header-close-tabs-left", "Close Tabs to the Left", .closeTabsToLeft, !presented && !state.layout.tabIDs(beside: tabID, side: .left).isEmpty)
            ]
            for (id, title, action, enabled) in closes {
                result.addItem(item(id, title, enabled: enabled) { store in
                    store.performCapturedClose(action, context: context, validateInput: { [weak owner, weak responder = owner?.firstResponder] in
                        !ownsWindow || (owner?.isVisible == true && owner?.isMiniaturized == false && owner?.attachedSheet == nil &&
                            owner?.firstResponder === responder && (owner?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true)
                    })
                })
            }
        }
        return result
    }
}

private final class HeaderMenuItem: NSMenuItem {
    var onInvoke: (() -> Void)?
    @objc func invoke(_ sender: Any?) { if isEnabled { onInvoke?() } }
}

enum HeaderContextInteraction {
    static func accepts(_ event: NSEvent?) -> Bool {
        event?.type == .rightMouseDown || (event?.type == .leftMouseDown && event?.modifierFlags.contains(.control) == true)
    }
}

struct HeaderContextMenuRegion: NSViewRepresentable {
    let id: String
    let makeMenu: (NSWindow?) -> NSMenu
    func makeNSView(context: Context) -> HeaderContextMenuView { HeaderContextMenuView() }
    func updateNSView(_ view: HeaderContextMenuView, context: Context) {
        view.identifier = NSUserInterfaceItemIdentifier(id)
        view.makeMenu = makeMenu
    }
}

final class HeaderContextMenuView: NSView {
    var makeMenu: ((NSWindow?) -> NSMenu)?
    override func hitTest(_ point: NSPoint) -> NSView? { HeaderContextInteraction.accepts(NSApp.currentEvent) ? super.hitTest(point) : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard HeaderContextInteraction.accepts(event), window?.attachedSheet == nil else { return nil }
        return makeMenu?(window)
    }
    override func rightMouseDown(with event: NSEvent) { popUp(event) }
    override func mouseDown(with event: NSEvent) { if HeaderContextInteraction.accepts(event) { popUp(event) } }
    private func popUp(_ event: NSEvent) {
        if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
}

extension InterfaceToolbarItem {
    var title: String {
        switch self {
        case .resume: return "Resume Conversation"
        case .workspaceActions: return "Workspace Actions"
        case .remoteHosts: return "Remote Hosts"
        case .decisions: return "Decisions"
        case .supervisor: return "Unisession"
        case .activity: return "Activity"
        case .resetTickets: return "Reset Tickets"
        case .commandPalette: return "Command Palette"
        }
    }
}

struct ToolbarItemVisibility: ViewModifier {
    @ObservedObject var store: AppStore
    let item: InterfaceToolbarItem

    @ViewBuilder func body(content: Content) -> some View {
        if store.interfacePreferences.showsToolbarItem(item) {
            content.overlay {
                HeaderContextMenuRegion(id: "toolbar-customize-" + item.rawValue) { window in
                    store.headerContextMenu(customizeViewOnly: true, sourceWindow: window)
                }
            }
        }
    }
}
