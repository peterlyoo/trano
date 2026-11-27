import AppKit
import SwiftUI
import TerminalCore
import UniformTypeIdentifiers

private let surface = Color(red: 20/255, green: 20/255, blue: 22/255)
private let separatorColor = Color.white.opacity(0.08)
private let accent = Color(red: 133/255, green: 215/255, blue: 193/255)
private let tabBarHeight = WorkspaceWindow.headerHeight

private struct WorkspaceSwitcherAnchor: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

func activityColor(_ activity: ActivityState) -> Color {
    switch activity {
    case .running: return accent
    case .blocked: return .orange
    case .done: return .green
    case .error: return .red
    case .idle, .unknown: return .secondary
    }
}

struct WorkspaceView: View {
    @ObservedObject var store: AppStore
    @State private var showAppearanceProfiles = false
    @StateObject private var interfaceWindow = InterfaceWindowContext()
    @State private var hoveredPanes: Set<String> = []
    @State private var hoveredTabID: String?
    @ObservedObject private var restart = AppRestartController.shared
    @Namespace private var interfaceHighlight
    private var interfaceContext: InterfaceContext {
        var context = InterfaceContext()
        context.systemIsDark = interfaceWindow.systemIsDark
        context.reduceMotion = interfaceWindow.reduceMotion
        context.isActiveWindow = interfaceWindow.isKey
        context.backgroundOpacity = store.effectiveWindowOpacity
        context.toolbarHovered = store.interfaceToolbarHovered
        context.toolbarRevealed = store.interfaceToolbarRevealed
        context.sidebarVisible = store.showSessionsSidebar
        context.tabCount = store.state.layout.currentTabs.count
        context.systemSidebarTextSize = interfaceWindow.systemSidebarFontSize
        let settings = store.interfaceResolvedSettings(for: store.focusedID ?? "")
        context.themeBackground = settings.background
        context.themeForeground = settings.appearance.foreground
        context.themeAccent = settings.appearance.ansiColors.count > 6 ? settings.appearance.ansiColors[6] : "#85D7C1"
        context.themePaletteHighlight = settings.appearance.ansiColors.count > 4 ? settings.appearance.ansiColors[4] : context.themeAccent
        return context
    }
    private var interfacePlan: InterfacePresentation { store.interfacePreferences.resolve(interfaceContext) }
    private var surface: Color { Color(nsColor: NSColor(hex: interfacePlan.chromeBackground)).opacity(interfacePlan.chromeOpacity) }
    private var accent: Color { Color(nsColor: NSColor(hex: interfacePlan.accent)) }
    private func panePlan(_ id: String) -> InterfacePresentation {
        var context = interfaceContext
        let settings = store.interfaceResolvedSettings(for: id)
        context.themeBackground = settings.background
        context.themeForeground = settings.appearance.foreground
        context.isActivePane = store.focusedID == id
        context.paneHovered = hoveredPanes.contains(id)
        context.backgroundOpacity = settings.appearance.opacity
        context.programBackground = store.interfaceProgramBackgrounds[id]
        context.alternateScreen = store.interfaceAlternateScreens.contains(id)
        return store.interfacePreferences.resolve(context)
    }
    private func programIcons(_ display: TabPresentation, tab: TerminalTab, vertical: Bool = false) -> some View {
        var context = interfaceContext
        context.isActiveTab = store.state.layout.selectedTabID == tab.id
        context.isActivePane = display.focusedPaneID == store.focusedID
        let plan = store.interfacePreferences.resolve(context)
        var icons = TabAgentIcons(programs: display.programs)
        icons.limit = vertical ? store.interfacePreferences.verticalIconCount : store.interfacePreferences.horizontalIconCount
        icons.colored = plan.colorTabIcons
        if store.interfacePreferences.iconColor == .activePanes {
            icons.coloredPrograms = Set(store.sessions.filter { $0.id == store.focusedID && tab.panes.contains($0.id) }.map(\.displayProgram))
        }
        icons.shellTheme = plan.shellIconTheme
        icons.themeForeground = Color(nsColor: NSColor(hex: context.themeForeground))
        icons.themeAccent = Color(nsColor: NSColor(hex: context.themeAccent))
        return icons.overlay(alignment: .bottomTrailing) {
            if !vertical, let status = NotificationActivityProjection.indicatorState(tab: tab, sessions: store.sessions,
                                                                                   readAt: store.state.activityReadAt, preferences: store.notificationPreferences) {
                NotificationTabStatus(state: status).offset(x: 3, y: 2)
            }
        }
    }
    /// The originating session of a tab the Master View presents from another session.
    private func presentedSourceTitle(_ tab: TerminalTab) -> String? {
        guard store.state.layout.isPresentedInMasterView(tab.id) else { return nil }
        return store.state.layout.workspaces.first { $0.id == tab.workspaceID }?.title
    }

    private var isMasterView: Bool {
        store.state.layout.masterView.map { $0.workspaceID == store.state.layout.selectedWorkspaceID } == true
    }

    private var workspaceTitle: String {
        store.state.layout.workspaces.first { $0.id == store.state.layout.selectedWorkspaceID }?.title ?? "Workspace"
    }

    var body: some View {
        VStack(spacing: 0) {
            InterfaceWorkspaceLayout(plan: interfacePlan, sidebarVisible: store.showSessionsSidebar,
                                     header: { tabs }, verticalHeader: { verticalToolbar },
                                     sidebar: { sidebar.modifier(InterfaceSidebarResize(store: store, window: store.focusedID.flatMap { store.terminalViews[$0]?.window })) }, content: {
                VStack(spacing: 0) {
                    if let tab = store.selectedTab {
                        panes(tab)
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: "terminal").font(.system(size: 32, weight: .ultraLight)).foregroundStyle(accent)
                            Text("Your workspace, uninterrupted.").font(.system(size: 18, weight: .medium))
                            Text(store.sessions.isEmpty ? "Start a shell to begin." : "Your sessions are still running. Reopen one from the sidebar.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Button("New Terminal", action: store.newTab).keyboardShortcut("t", modifiers: .command)
                                .buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(NSColor(hex: store.interfaceResolvedSettings(for: "").background)).opacity(interfacePlan.paneOpacity))
                    }
                }
                .background(WorkspaceRegion("terminal-workspace"))
                .background(UnisessionWorkspaceAnchor { store.onUnisessionAnchor?($0) })
                .overlay {
                    if let model = store.conversationResume {
                        ConversationResumeOverlay(model: model, onDismiss: { store.dismissConversationResume() })
                    }
                }
                .overlay {
                    if store.decisionPaneID != nil {
                        DecisionInboxOverlay(entries: store.visibleDecisions, saving: store.decisionSaving, error: store.decisionError,
                                             onResolve: store.resolveDecision, onDismiss: store.dismissDecisions,
                                             draftStore: $store.decisionDrafts, preferredQuestionID: store.preferredDecisionID,
                                             canNavigate: store.canNavigateToDecisionSession,
                                             onGoToSession: { entry, window in store.goToDecisionSession(entry, from: window) })
                    }
                }
                .overlay {
                    if store.followUpPaneID != nil {
                        GeometryReader { geometry in
                            ZStack(alignment: .topTrailing) {
                                Color.black.opacity(0.12).contentShape(Rectangle())
                                    .onTapGesture { store.dismissFollowUps() }
                                FollowUpQueueView(store: store)
                                    .frame(width: min(380, max(0, geometry.size.width - 24)), height: min(540, max(0, geometry.size.height - 24)))
                                    .dismissOnOutsideClick("queued-input", perform: store.dismissFollowUps)
                                    .padding(12)
                            }.frame(width: geometry.size.width, height: geometry.size.height)
                        }.clipped()
                    }
                }
                .overlay {
                    if store.showActivity {
                        GeometryReader { geometry in
                            ZStack(alignment: .topTrailing) {
                                Color.black.opacity(0.12).contentShape(Rectangle())
                                    .onTapGesture { store.showActivity = false }
                                activity
                                    .frame(width: min(320, max(0, geometry.size.width - 24)), height: min(420, max(0, geometry.size.height - 24)))
                                    .dismissOnOutsideClick("activity", canDismiss: { store.showActivity }, perform: { store.showActivity = false })
                                    .background(WorkspaceRegion("activity-panel"))
                                    .padding(12)
                            }.frame(width: geometry.size.width, height: geometry.size.height)
                        }.clipped()
                    }
                }
            })
            .overlay(alignment: .top) {
                if store.interfacePreferences.toolbarBehavior == .onHover {
                    InterfaceToolbarRevealRegion { store.interfaceToolbarHovered = true }.frame(height: 7)
                }
            }
        }
        .background { InterfaceMaterialBackground(enabled: interfacePlan.glassChrome, dark: interfacePlan.isDark, opacity: store.effectiveWindowOpacity) }
        .foregroundStyle(Color(NSColor(hex: interfacePlan.chromeForeground)))
        .preferredColorScheme(interfacePlan.isDark ? .dark : .light)
        .background(InterfaceWindowAttachment(state: interfaceWindow, plan: interfacePlan))
        .animation(interfacePlan.swiftUIAnimation, value: store.state.layout.tabs)
        .animation(interfacePlan.swiftUIAnimation, value: store.zoomed)
        .onChange(of: store.interfacePreferences.toolbarLayout) { _, value in if value != .above { store.showSessionsSidebar = true } }
        .onChange(of: store.showSessionsSidebar) { old, next in
            guard old != next, let window = store.focusedID.flatMap({ store.terminalViews[$0]?.window }) else { return }
            InterfaceWindowEffects.resizeSidebar(window, preferences: store.interfacePreferences, previous: old ? store.interfacePreferences.sidebarWidth + 1 : 0, next: next ? store.interfacePreferences.sidebarWidth + 1 : 0)
        }
        .frame(minWidth: 900, minHeight: 580)
        .ignoresSafeArea(.container, edges: .top)
        .overlayPreferenceValue(WorkspaceSwitcherAnchor.self) { anchor in
            GeometryReader { geometry in
                if let kind = store.picker {
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.16).contentShape(Rectangle()).onTapGesture { store.dismissPicker() }
                        if kind == .sessions, let anchor {
                            let bounds = geometry[anchor]
                            navigationPicker(kind, compact: true)
                                .dismissOnOutsideClick("navigation-picker", canDismiss: { store.picker != nil }, perform: store.dismissPicker)
                                .offset(x: min(bounds.minX, max(0, geometry.size.width - 320)), y: bounds.maxY)
                        } else {
                            navigationPicker(kind, compact: false)
                                .dismissOnOutsideClick("navigation-picker", canDismiss: { store.picker != nil }, perform: store.dismissPicker)
                                .frame(maxWidth: .infinity, alignment: .top)
                                .padding(.top, 44)
                        }
                    }
                }
            }.ignoresSafeArea(.container, edges: .top)
        }
        .workspacePanel(isPresented: store.showSettings) { SettingsView(store: store) }
        .workspacePanel(isPresented: showAppearanceProfiles) { ProfileAppearanceView(store: store, onClose: { showAppearanceProfiles = false }) }
        .workspacePanel(isPresented: store.showVoice) { VoiceInputView(store: store) }
        .workspacePanel(isPresented: store.showRemoteHosts) { RemoteHostsView(store: store) }
        .workspacePanel(isPresented: store.showAccounts) { AccountsView(store: store) }
        .workspacePanel(isPresented: store.showExtensions) { ExtensionsView(store: store) }
        .workspacePanel(isPresented: store.remotePathRequest != nil) {
            if let request = store.remotePathRequest { RemotePathsView(store: store, request: request) }
        }
        .alert("Trano", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK") { store.message = nil }
        } message: { Text(store.message ?? "") }
        .environment(\.toolPanelTheme, store.toolPanelTheme)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if interfacePlan.toolbarLayout == .above { HStack {
                Text("SESSIONS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { store.execute(.newSession) } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("New Session · ⇧⌘N")
            }.padding(.horizontal, 15).padding(.top, 22).padding(.bottom, 14) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(store.state.layout.workspaces.filter { !$0.closed }) { workspace in
                        let workspaceTabs = store.state.layout.tabs.filter { $0.workspaceID == workspace.id }
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                Button { store.toggleCollapse(workspace.id) } label: {
                                    Image(systemName: workspace.collapsed ? "chevron.right" : "chevron.down").font(.system(size: 8, weight: .bold)).frame(width: 12)
                                }.buttonStyle(.plain).accessibilityLabel(workspace.collapsed ? "Expand session" : "Collapse session")
                                Button { store.selectWorkspace(workspace.id) } label: {
                                    HStack {
                                        Image(systemName: "square.stack.3d.up").foregroundStyle(workspace.id == store.state.layout.selectedWorkspaceID ? accent : .secondary)
                                        Text(workspace.title).font(.system(size: interfacePlan.toolbarLayout == .above ? 12 : interfacePlan.sidebarFontSize + 1, weight: .semibold)).lineLimit(1)
                                        Spacer(minLength: 2)
                                        Text(workspace.closed ? "closed" : "\(workspaceTabs.count)").font(.system(size: 9)).foregroundStyle(.secondary)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .modifier(WorkspaceDestinationDropTarget(store: store, workspaceID: workspace.id))
                                WorkspaceCloseButton(id: "sidebar-workspace-close-" + workspace.id, workspaceTitle: workspace.title) { store.closeWorkspace(workspace.id) }
                                    .frame(width: 18, height: 20)
                                    .disabled(store.followUpPaneID != nil || store.decisionPaneID != nil)
                            }.padding(.horizontal, 9).padding(.vertical, 9)
                                .background(workspace.id == store.state.layout.selectedWorkspaceID ? Color.white.opacity(0.05) : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .background(WorkspaceRegion("sidebar-workspace-" + workspace.id))
                                .contextMenu {
                                    Button("Open Session") { store.selectWorkspace(workspace.id) }
                                    Button("Rename Session…") { store.rename(.renameSession, target: workspace.id) }
                                    Button("Close Workspace") { store.closeWorkspace(workspace.id) }
                                }
                            if !workspace.collapsed && !workspace.closed {
                                ForEach(workspaceTabs) { tab in
                                    let display = store.presentation(for: tab)
                                    Button { store.selectTab(tab.id) } label: {
                                        HStack(spacing: 8) {
                                            programIcons(display, tab: tab, vertical: true).font(.system(size: 10))
                                            Text(display.title).font(.system(size: interfacePlan.toolbarLayout == .above ? 11 : interfacePlan.sidebarFontSize)).lineLimit(1)
                                            Spacer(minLength: 0)
                                            if let status = NotificationActivityProjection.indicatorState(tab: tab, sessions: store.sessions,
                                                                                                         readAt: store.state.activityReadAt, preferences: store.notificationPreferences) {
                                                NotificationTabStatus(state: status)
                                            }
                                        }.padding(.leading, 28).padding(.trailing, 12).padding(.vertical, 8)
                                            .background(tab.id == store.state.layout.selectedTabID ? accent.opacity(0.065) : .clear)
                                            .clipShape(RoundedRectangle(cornerRadius: 5))
                                    }.buttonStyle(.plain)
                                        .modifier(TabActivityHover(snapshot: TabActivitySnapshot(tab: tab, sessions: store.sessions, preferGeneratedTitles: store.terminalPreferences.preferGeneratedTitles), placement: .trailing))
                                        .modifier(PaneDropTarget(store: store, tabID: tab.id))
                                }
                            }
                        }
                    }
                }.padding(.horizontal, 7)
            }
            Spacer(minLength: 0)
            Button { store.picker = .anything } label: {
                HStack { Image(systemName: "arrow.up.right"); Text("Go to Anything"); Spacer(); Text("⌘P").font(.system(size: 10, design: .monospaced)) }
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(14)
            }.buttonStyle(.plain)
        }.background(surface)
    }

    private func navigationPicker(_ kind: AppStore.PickerKind, compact: Bool) -> some View {
        PickerView(store: store, kind: kind, compact: compact)
            .id(kind.id)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(separatorColor, lineWidth: 1).allowsHitTesting(false) }
            .background(WorkspaceRegion("navigation-picker"))
            .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }

    private var tabs: some View {
        let shortcuts = store.tabShortcutHints
        return HStack(spacing: 4) {
            Button { store.showActivity = false; store.picker = .sessions } label: {
                HStack(spacing: 7) {
                    Image(systemName: isMasterView ? "tray.full" : "square.stack.3d.up").font(.system(size: 11)).foregroundStyle(accent)
                    Text(workspaceTitle)
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8)).foregroundStyle(.secondary)
                }.padding(.horizontal, 6).frame(maxWidth: 160, minHeight: tabBarHeight, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                    .contentShape(Rectangle())
            }.accessibilityLabel("Switch Workspace").accessibilityValue(workspaceTitle).help("\(workspaceTitle) · Switch Workspace · ⌘K")
                .background(WorkspaceRegion("workspace-switcher"))
                .anchorPreference(key: WorkspaceSwitcherAnchor.self, value: .bounds) { $0 }
                .modifier(WorkspaceDragChooser(store: store))
                .overlay {
                    HeaderContextMenuRegion(id: "workspace-context-menu") { window in
                        store.headerContextMenu(showProfiles: { showAppearanceProfiles = true }, sourceWindow: window)
                    }
                }
            if let workspace = store.state.layout.workspaces.first(where: { $0.id == store.state.layout.selectedWorkspaceID && !$0.closed }) {
                WorkspaceCloseButton(id: "header-workspace-close-" + workspace.id, workspaceTitle: workspace.title) { store.closeWorkspace(workspace.id) }
                    .frame(width: 16, height: 22)
                    .disabled(store.followUpPaneID != nil || store.decisionPaneID != nil)
            }
            Rectangle().fill(separatorColor).frame(width: 1, height: 16)
            GeometryReader { geometry in
              ScrollViewReader { scroller in
              ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(store.state.layout.currentTabs) { tab in
                        let display = store.presentation(for: tab)
                        let width = CGFloat(interfacePlan.equalTabWidth(available: geometry.size.width, minimum: minimumTabWidth) ?? 0)
                        let inset = min(8, width / 8)
                        let closeWidth = min(16, max(0, width - inset * 2))
                        let spacing = min(6, max(0, width - inset * 2 - closeWidth))
                        let labelWidth = max(0, width - inset * 2 - closeWidth - spacing)
                        HStack(spacing: spacing) {
                          HStack(spacing: 9) {
                            ZStack {
                                programIcons(display, tab: tab).font(.system(size: 11))
                                    .background(WorkspaceRegion("tab-agents-" + tab.id, label: display.programs.map(\.rawValue).joined(separator: ",")))
                                    .opacity(shortcuts[tab.id] == nil ? 1 : 0)
                                    .accessibilityHidden(shortcuts[tab.id] != nil)
                                if let shortcut = shortcuts[tab.id] {
                                    Text(shortcut).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                                        .background(WorkspaceRegion("tab-shortcut-" + tab.id, label: shortcut))
                                }
                            }.frame(width: store.interfacePreferences.horizontalIconCount == 0 && shortcuts[tab.id] == nil ? 0 : 20, height: 16).allowsHitTesting(false)
                            if let source = presentedSourceTitle(tab) {
                                Text(source).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                                    .fixedSize().background(WorkspaceRegion("tab-master-source-" + tab.id, label: source))
                            }
                            Text(display.title).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading).help(display.title)
                                .background(WorkspaceRegion("tab-title-" + tab.id, label: display.title))
                            if tab.panes.count > 1 { Text("\(tab.panes.count)").font(.system(size: 9)).foregroundStyle(.secondary) }
                          }.frame(width: labelWidth, height: tabBarHeight, alignment: .leading).clipped()
                              .overlay { TabDragRegion(store: store, tabID: tab.id, title: display.title) }
                            Button { store.closeTab(tab.id, sourceWindow: NSApp.currentEvent?.window) } label: { Image(systemName: "xmark").font(.system(size: 8)).foregroundStyle(.tertiary) }
                                .buttonStyle(.plain).help("Close Tab").frame(width: closeWidth, height: 24)
                                .opacity(hoveredTabID == tab.id ? 1 : 0).allowsHitTesting(hoveredTabID == tab.id)
                                .background(WorkspaceRegion("tab-close-" + tab.id))
                        }.padding(.horizontal, inset).frame(width: width, height: tabBarHeight).clipped()
                            .background(interfacePlan.tabBackgroundVisible && tab.id == store.state.layout.selectedTabID ? Color.white.opacity(0.045) : .clear)
                            .background(WorkspaceRegion("workspace-tab-" + tab.id))
                            .background(HoverTrackingRegion { hovering in
                                if hovering { hoveredTabID = tab.id } else if hoveredTabID == tab.id { hoveredTabID = nil }
                            })
                            .overlay(alignment: .bottom) { if tab.id == store.state.layout.selectedTabID { Rectangle().fill(accent).frame(height: 1) } }
                            .contentShape(Rectangle()).onTapGesture { store.showActivity = false; store.selectTab(tab.id) }
                            .modifier(TabActivityHover(snapshot: TabActivitySnapshot(tab: tab, sessions: store.sessions, focusedPaneID: display.focusedPaneID, preferGeneratedTitles: store.terminalPreferences.preferGeneratedTitles), placement: .below))
                            .modifier(PaneDropTarget(store: store, tabID: tab.id))
                            .overlay {
                                HeaderContextMenuRegion(id: "tab-context-menu-" + tab.id) { window in
                                    store.headerContextMenu(tabID: tab.id, showProfiles: { showAppearanceProfiles = true }, sourceWindow: window)
                                }
                            }
                            .id(tab.id)
                    }
                    WindowDragRegion(contextMenu: { window in store.headerContextMenu(showProfiles: { showAppearanceProfiles = true }, sourceWindow: window) })
                        .frame(minWidth: interfacePlan.fillTabs ? 0 : 24, maxWidth: interfacePlan.fillTabs ? 0 : .infinity, minHeight: tabBarHeight, maxHeight: tabBarHeight)
                        .modifier(TabStripDropTarget(store: store))
                }.frame(minWidth: geometry.size.width, minHeight: tabBarHeight)
              }
              .onAppear { revealSelectedTab(scroller) }
              .onChange(of: store.state.layout.selectedTabID) { _, _ in revealSelectedTab(scroller) }
              .onChange(of: store.state.layout.currentTabs.count) { _, _ in revealSelectedTab(scroller) }
              .onChange(of: geometry.size.width) { _, _ in revealSelectedTab(scroller) }
              }
            }
            WindowDragRegion(contextMenu: { window in store.headerContextMenu(showProfiles: { showAppearanceProfiles = true }, sourceWindow: window) })
                .frame(width: 12, height: tabBarHeight)
            toolbarActions
        }.buttonStyle(.plain).padding(.leading, 72).padding(.trailing, 8).frame(height: tabBarHeight)
            .background(surface).background(WorkspaceRegion("workspace-header"))
            .onHover { store.interfaceToolbarHovered = $0 }
    }

    // Keeps the program icon and the first title character readable before the strip starts scrolling.
    private var minimumTabWidth: Double { store.interfacePreferences.horizontalIconCount == 0 ? 52 : 80 }

    private func revealSelectedTab(_ scroller: ScrollViewProxy) {
        guard let id = store.state.layout.selectedTabID, store.state.layout.currentTabs.contains(where: { $0.id == id }) else { return }
        DispatchQueue.main.async { scroller.scrollTo(id) }
    }

    @ViewBuilder private var toolbarActions: some View {
            if restart.pendingBuild != nil {
                Button { restart.restart() } label: {
                    Label("Restart", systemImage: "arrow.clockwise").labelStyle(.titleAndIcon)
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
                        .padding(.horizontal, 7).frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(accent.opacity(0.14)))
                }.fixedSize()
                    .help("A new Trano build is installed. Restart the app; running sessions keep running.")
                    .accessibilityLabel("Restart to Update")
                    .background(WorkspaceRegion("restart-update-button"))
            }
            Button { store.toggleConversationResume() } label: { WorkspaceToolbarIcon(systemName: "clock.arrow.circlepath") }
                .help("Resume Conversation · ⇧⌘R").accessibilityLabel("Resume Conversation")
                .foregroundStyle(store.conversationResume != nil ? accent : Color.primary)
                .background(WorkspaceRegion("conversation-resume-button"))
                .modifier(ToolbarItemVisibility(store: store, item: .resume))
            Group {
            Menu {
                Button("New Session") { store.showActivity = false; store.execute(.newSession) }
                Divider()
                Button(store.showSessionsSidebar ? "Hide Sessions Sidebar" : "Show Sessions Sidebar") { store.showSessionsSidebar.toggle() }
                Divider()
                Button("Remote Hosts…", action: store.openRemoteHosts)
                Button("Agent Accounts…") { store.showActivity = false; store.showAccounts = true }
                Button("Agent Extensions…") { store.showActivity = false; store.showExtensions = true }
                Button("Voice Input…") { store.showActivity = false; store.showVoice = true }.disabled(store.focusedID == nil)
                Divider()
                Button("Settings…") { store.showActivity = false; store.showSettings = true }
            } label: { WorkspaceToolbarIcon(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24).help("Workspace Actions").accessibilityLabel("Workspace Actions")
                .modifier(ToolbarItemVisibility(store: store, item: .workspaceActions))
            Button(action: store.openRemoteHosts) { WorkspaceToolbarIcon(systemName: "network") }
                .help("Add Remote Host / Remote Hosts").accessibilityLabel("Add Remote Host")
                .background(WorkspaceRegion("remote-hosts-button"))
                .modifier(ToolbarItemVisibility(store: store, item: .remoteHosts))
            Button {
                if store.decisionPaneID == nil { store.openDecisions() } else { store.dismissDecisions() }
            } label: {
                DecisionCountIcon(count: store.pendingDecisions.count)
                    .frame(width: WorkspaceToolbarStyle.buttonSize, height: WorkspaceToolbarStyle.buttonSize)
            }
            .disabled(store.focusedID == nil)
            .help("Decisions").accessibilityLabel("Decisions")
            .accessibilityValue("\(store.pendingDecisions.count) pending")
            .background(WorkspaceRegion("decision-inbox-button"))
                .modifier(ToolbarItemVisibility(store: store, item: .decisions))
            Button { store.onToggleSupervisor?() } label: { WorkspaceToolbarIcon(systemName: "terminal") }
                .foregroundStyle(store.unisessionPresented ? accent : Color.primary)
                .help("Unisession").accessibilityLabel("Unisession")
                .accessibilityValue(store.unisessionPresented ? "Shown" : "Hidden")
                .background(WorkspaceRegion("unisession-button"))
                .modifier(ToolbarItemVisibility(store: store, item: .supervisor))
            Button { store.showActivity.toggle() } label: { WorkspaceToolbarIcon(systemName: "waveform.path") }
                .overlay(alignment: .topTrailing) { if store.activityNeedsAttention { Circle().fill(.orange).frame(width: 5, height: 5).allowsHitTesting(false) } }
                .foregroundStyle(store.showActivity ? accent : Color.primary)
                .help(store.showActivity ? "Hide Activity" : "View Activity").accessibilityLabel("View Activity")
                .accessibilityValue(store.showActivity ? "Shown" : "Hidden")
                .background(WorkspaceRegion("activity-button"))
                .modifier(ToolbarItemVisibility(store: store, item: .activity))
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let count = store.availableResetCount(now: context.date)
                if count > 0 {
                    ResetTicketButton(count: count, action: store.openResetTickets)
                        .frame(width: max(38, CGFloat(String(count).count) * 7 + 26), height: 24)
                        .disabled(store.decisionPaneID != nil || store.followUpPaneID != nil)
                }
            }.fixedSize()
                .modifier(ToolbarItemVisibility(store: store, item: .resetTickets))
            Button { store.showActivity = false; store.picker = .commands } label: { WorkspaceToolbarIcon(systemName: "command") }
                .help("Command Palette · ⇧⌘P").accessibilityLabel("Command Palette")
                .background(WorkspaceRegion("command-palette-button"))
                .modifier(ToolbarItemVisibility(store: store, item: .commandPalette))
            }.disabled(store.conversationResume != nil)
    }
    private var verticalToolbar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Button { store.picker = .sessions } label: { Text(workspaceTitle).lineLimit(1).font(.system(size: 12, weight: .semibold)) }
                Spacer(minLength: 0)
                WindowDragRegion(contextMenu: { window in store.headerContextMenu(showProfiles: { showAppearanceProfiles = true }, sourceWindow: window) }).frame(width: 16)
            }.padding(.leading, 72).padding(.trailing, 8).frame(height: 40)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 26, maximum: 30), spacing: 2)], alignment: .leading, spacing: 2) { toolbarActions }.padding(.horizontal, 8).padding(.bottom, 5)
        }.buttonStyle(.plain).background(surface)
            .onHover { store.interfaceToolbarHovered = $0 }
    }

    @ViewBuilder private func panes(_ tab: TerminalTab) -> some View {
        if store.zoomed, let id = store.focusedID, tab.panes.contains(id) {
            pane(id)
        } else {
            tree(tab.tree)
        }
    }

    private func tree(_ node: PaneTree) -> AnyView {
        switch node {
        case .pane(let id): return AnyView(pane(id))
        case .split(let id, let axis, let ratio, let first, let second):
            return AnyView(PaneSplitView(id: id, axis: axis, ratio: ratio, first: tree(first), second: tree(second), dividerWidth: interfacePlan.dividerWidth, surfaceColor: Color(nsColor: NSColor(hex: interfacePlan.chromeBackground)), surfaceOpacity: interfacePlan.chromeOpacity) { value in
                store.resizeSplit(id, ratio: value)
            })
        }
    }

    private func pane(_ id: String) -> some View {
        let session = store.sessions.first { $0.id == id }
        let appearance = store.state.settings.resolvedAppearance(for: id)
        let profileID = store.state.settings.paneAppearanceProfiles[id]
        let queuedCount = store.state.followUpInputs.filter { $0.paneID == id }.count
        let plan = panePlan(id)
        return InterfacePaneChrome(plan: plan, active: id == store.focusedID, namespace: interfaceHighlight, header: {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(id == store.focusedID ? accent : .secondary).frame(width: 5, height: 5)
                    ProgramLogo(program: session?.displayProgram ?? .shell).frame(width: 13, height: 13)
                        .background(WorkspaceRegion("pane-program-" + id, label: session?.displayProgram.rawValue ?? "shell"))
                    Text(session?.displayTitle(preferGeneratedTitles: store.terminalPreferences.preferGeneratedTitles) ?? "Terminal")
                        .font(.system(size: 10, weight: .medium)).lineLimit(1).help(session?.cwd ?? "")
                    Spacer(minLength: 0)
                }.padding(.leading, 12).padding(.trailing, 8).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay { PaneDragRegion(store: store, paneID: id, title: session?.displayTitle(preferGeneratedTitles: store.terminalPreferences.preferGeneratedTitles) ?? "Terminal") }
                PessimisticTwinButton(store: store, paneID: id).frame(width: 22, height: 22)
                QueuedInputButton(paneID: id, count: queuedCount, shortcut: store.queuedInputShortcut, selected: store.followUpPaneID == id) {
                    store.toggleFollowUps(paneID: id)
                }.frame(width: queuedCount == 0 ? 20 : CGFloat(20 + String(queuedCount).count * 7), height: 22)
                Text(session?.activity.state.rawValue ?? "unknown").font(.system(size: 9)).foregroundStyle(activityColor(session?.activity.state ?? .unknown))
                    .padding(.leading, 8).padding(.trailing, 12).frame(maxHeight: .infinity)
                    .overlay { PaneDragRegion(store: store, paneID: id, title: session?.displayTitle(preferGeneratedTitles: store.terminalPreferences.preferGeneratedTitles) ?? "Terminal", regionID: "pane-status-drag-" + id) }
            }.frame(height: plan.paneHeaderHeight)
                .background(WorkspaceRegion("pane-header-" + id))
                .contentShape(Rectangle())
                .contextMenu {
                  Button(store.floatingPaneIDs.contains(id) ? "Return to Pane" : "Float Pane") { store.floatingPanes.toggle(id) }
                  Divider()
                  Menu("Appearance Profile") {
                    Button {
                        store.perform { try $0.setAppearanceProfile(nil, paneID: id) }
                    } label: { if profileID == nil { Label("Default", systemImage: "checkmark") } else { Text("Default") } }
                    ForEach(store.state.settings.appearanceProfiles) { profile in
                        Button { store.perform { try $0.setAppearanceProfile(profile.id, paneID: id) } } label: {
                            if profileID == profile.id { Label(profile.name, systemImage: "checkmark") } else { Text(profile.name) }
                        }
                    }
                    Divider()
                    Button("Manage Profiles…") { showAppearanceProfiles = true }
                  }
                }
        }, content: {
            if let recovery = store.state.recoveryResults.first(where: { $0.paneID == id }), [.needsAttention, .failed, .restoring].contains(recovery.status) {
                HStack {
                    Image(systemName: recovery.status == .restoring ? "arrow.clockwise" : "exclamationmark.circle")
                    Text(recovery.message).font(.caption).lineLimit(2)
                    Spacer()
                    if recovery.status != .restoring && (session?.alive == false || store.state.agentLaunches.contains(where: { $0.paneID == id && $0.lifecycle == .active })) {
                        Button("Retry") { store.perform(restoringContext: false, holdingTransaction: false) { _ = try $0.retryRecovery(paneID: id) } }
                    }
                }.foregroundStyle(.orange).padding(10).background(surface)
            }
            if store.floatingPaneIDs.contains(id) {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.on.rectangle").foregroundStyle(.secondary)
                    Button("Return to Pane") { store.floatingPanes.returnPane(id) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor(hex: appearance.background)).opacity(plan.paneOpacity))
                .background(WorkspaceRegion("floating-pane-placeholder-" + id))
            } else {
                TerminalPane(store: store, id: id, interfacePresentation: plan).id(id).background { TerminalBackgroundView(settings: appearance, backgroundOpacity: plan.paneOpacity) }
            }
        })
        .onHover { if $0 { hoveredPanes.insert(id) } else { hoveredPanes.remove(id) } }
    }

    private var activity: some View {
        ActivityListView(store: store)
    }
}

struct WorkspaceRegion: NSViewRepresentable {
    let id: String
    let label: String?
    init(_ id: String, label: String? = nil) { self.id = id; self.label = label }
    func makeNSView(context: Context) -> NSView {
        let view = RegionView()
        view.identifier = NSUserInterfaceItemIdentifier(rawValue: id)
        view.setAccessibilityLabel(label)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.identifier = NSUserInterfaceItemIdentifier(rawValue: id)
        nsView.setAccessibilityLabel(label)
    }
    private final class RegionView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct PaneSplitView: View {
    let id: String
    let axis: SplitAxis
    let ratio: Double
    let first: AnyView
    let second: AnyView
    var dividerWidth: CGFloat = 5
    var surfaceColor = Color(nsColor: NSColor(hex: "#141416"))
    var surfaceOpacity = 1.0
    let resize: (Double) -> Void
    @State private var dragRatio: Double?

    var body: some View {
        GeometryReader { geometry in
            let length = max(1, (axis == .horizontal ? geometry.size.width : geometry.size.height) - dividerWidth)
            let minimum = min(0.4, (axis == .horizontal ? 180.0 : 100.0) / length)
            let value = min(1 - minimum, max(minimum, dragRatio ?? ratio))
            let divider = Rectangle().fill(separatorColor).background(surfaceColor).compositingGroup().opacity(surfaceOpacity).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                    let offset = axis == .horizontal ? gesture.translation.width : gesture.translation.height
                    dragRatio = min(1 - minimum, max(minimum, ratio + offset / length))
                }.onEnded { _ in resize(dragRatio ?? ratio); dragRatio = nil })
                .onHover { inside in
                    if inside { (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() }
                    else { NSCursor.pop() }
                }
            if axis == .horizontal {
                HStack(spacing: 0) { first.frame(width: length * value); divider.frame(width: dividerWidth); second }
            } else {
                VStack(spacing: 0) { first.frame(height: length * value); divider.frame(height: dividerWidth); second }
            }
        }
    }
}

private struct WorkspaceActivityDot: NSViewRepresentable {
    let workspaceID: String
    let color: NSColor
    func makeNSView(context: Context) -> DotView {
        let view = DotView()
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: DotView, context: Context) {
        view.identifier = NSUserInterfaceItemIdentifier("picker-workspace-activity-" + workspaceID)
        view.color = color.withAlphaComponent(0.85)
        view.needsDisplay = true
    }
    final class DotView: NSView {
        var color = NSColor.clear
        override var intrinsicContentSize: NSSize { NSSize(width: 6, height: 6) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            color.setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
    }
}

struct PickerView: View {
    @ObservedObject var store: AppStore
    let kind: AppStore.PickerKind
    var compact = false
    @State private var query = ""
    @State private var selection = 0
    private struct ResultIdentity: Equatable {
        let query: String
        let ids: [String]
    }
    private var resultIdentity: ResultIdentity {
        ResultIdentity(query: query, ids: entries.map { $0.4 ?? "action:" + $0.0 })
    }
    private var entries: [(String, String, () -> Void, String?, String?)] {
        var all: [(String, String, () -> Void, String?, String?)] = []
        switch kind {
        case .commands:
            return ((try? ActionCatalog.resolved(overrides: store.state.settings.keyBindings)) ?? ActionCatalog.all)
                .filter { query.isEmpty || ($0.title + " " + $0.category + " " + $0.keywords).localizedCaseInsensitiveContains(query) }
                .map { item in (item.title, item.bindings.first.map(KeyBindingMap.display) ?? "", { store.execute(item.action) }, nil, nil) }
                + ((query.isEmpty || "Reveal Toolbar".localizedCaseInsensitiveContains(query)) ? [("Reveal Toolbar", "", { store.interfaceToolbarRevealed = true; store.showSessionsSidebar = store.interfacePreferences.toolbarLayout != .above || store.showSessionsSidebar }, nil, nil)] : [])
        case .sessions:
            all = store.state.layout.workspaces.filter { !$0.closed }.map { workspace in
                let count = store.state.layout.tabs.filter { $0.workspaceID == workspace.id }.count
                return (workspace.title, "\(count) tabs", { store.selectWorkspace(workspace.id) }, workspace.id, workspace.id)
            }
        case .movePane:
            all = store.state.layout.tabs.filter { $0.id != store.selectedTab?.id }.map { tab in
                let workspace = store.state.layout.workspaces.first { $0.id == tab.workspaceID }?.title ?? ""
                let title = store.presentation(for: tab).title
                return (title, workspace, { if let id = store.focusedID { store.move(id, to: tab.id) } }, nil, nil)
            }
        case .anything:
            if store.developerPreferences.usesNewQuickSwitcher {
                return DeveloperQuickSwitcher.entries(layout: store.state.layout, sessions: store.sessions, query: query).map { entry in
                    (entry.title, entry.detail, {
                        if let paneID = entry.paneID { store.attach(paneID) }
                        else if let tabID = entry.tabID { store.selectTab(tabID) }
                        else if let workspaceID = entry.workspaceID { store.selectWorkspace(workspaceID) }
                    }, nil, entry.id)
                }
            }
            all = store.sessions.map { item in
                let tab = store.state.layout.tabs.first { $0.panes.contains(item.id) }
                let workspace = store.state.layout.workspaces.first { $0.id == tab?.workspaceID }?.title ?? "Detached"
                return (item.displayTitle(preferGeneratedTitles: store.terminalPreferences.preferGeneratedTitles), workspace + " · " + URL(fileURLWithPath: item.cwd).lastPathComponent, { store.attach(item.id) }, nil, nil)
            }
        }
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var matches: [(String, String, () -> Void, String?, String?)]
        if kind == .sessions {
            let search = KeyboardLayoutSearch(query: name)
            var tiers = Array(repeating: [Int](), count: KeyboardLayoutSearch.Match.allCases.count)
            for (index, entry) in all.enumerated() {
                if let match = search.match(title: entry.0, detail: entry.1) { tiers[match.rawValue].append(index) }
            }
            matches = tiers.flatMap { $0.map { all[$0] } }
            let exact = matches.filter { $0.0.caseInsensitiveCompare(name) == .orderedSame }
            if !name.isEmpty && exact.isEmpty { matches.append(("Create “\(name)”", "New Session", { store.newSession(title: name) }, nil, nil)) }
            matches.append(("New Session", "⇧⌘N", { store.newSession() }, nil, nil))
            matches.append(("Add Remote Host…", "", { store.openRemoteHosts() }, nil, nil))
        } else {
            matches = all.filter { name.isEmpty || ($0.0 + " " + $0.1).localizedCaseInsensitiveContains(name) }
        }
        return matches
    }
    private var activeWorkspaceIDs: Set<String> {
        guard kind == .sessions else { return [] }
        let activePaneIDs = Set(store.sessions.filter {
            $0.alive && ActivityInbox.isUnread($0, readAt: store.state.activityReadAt[$0.id])
        }.map(\.id))
        return Set(store.state.layout.tabs.compactMap { tab in
            activePaneIDs.isDisjoint(with: tab.panes) ? nil : tab.workspaceID
        })
    }
    private var placeholder: String {
        switch kind {
        case .commands: return "Search commands…"
        case .sessions: return "Filter or create"
        case .anything: return "Find a pane, tab or session…"
        case .movePane: return "Move pane to tab…"
        }
    }
    private var panelTitle: String? {
        switch kind {
        case .commands: return "Command Palette"
        case .sessions: return nil
        case .anything: return "Go to Anything"
        case .movePane: return "Move Pane"
        }
    }
    var body: some View {
        let activeWorkspaces = activeWorkspaceIDs
        let newSessionIndex: Int? = kind == .sessions ? entries.count - 2 : nil
        let remoteHostIndex: Int? = kind == .sessions ? entries.count - 1 : nil
        let scrollingEntries = Array(entries.enumerated()).filter { $0.offset != newSessionIndex && $0.offset != remoteHostIndex }
        VStack(spacing: 0) {
            if let panelTitle { ToolPanelHeader(panelTitle, onClose: store.dismissPicker) }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(store.toolPanelTheme.accent)
                PickerSearchField(text: $query, placeholder: placeholder, previewsMarkedText: kind == .sessions,
                                  onQuickSelect: kind == .sessions ? quickChoose : nil,
                                  onMove: moveSelection, onSubmit: choose, onCancel: store.dismissPicker)
                    .frame(maxWidth: .infinity).frame(height: 20)
            }
                .padding(.horizontal, ToolPanelMetrics.contentInset).padding(.vertical, 8)
            Divider()
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(scrollingEntries, id: \.offset) { index, entry in
                            HStack(spacing: 0) {
                                Button { selection = index; choose() } label: {
                                    HStack {
                                        HStack(spacing: 6) {
                                            Text(entry.0).lineLimit(1)
                                                .background {
                                                    if kind == .sessions, let id = entry.4 { WorkspaceRegion("picker-workspace-title-" + id) }
                                                }
                                            if kind == .sessions, let id = entry.4, activeWorkspaces.contains(id) {
                                                WorkspaceActivityDot(workspaceID: id, color: store.toolPanelTheme.accentNS)
                                                    .frame(width: 6, height: 6).allowsHitTesting(false).accessibilityHidden(true)
                                            }
                                        }
                                        Spacer()
                                        Text(entry.1).foregroundStyle(.secondary).lineLimit(1)
                                        if let position = quickPositions[index] {
                                            Text("⌘\(position + 1)").foregroundStyle(.secondary).monospacedDigit()
                                                .frame(width: 28, alignment: .trailing)
                                        }
                                    }
                                        .font(.system(size: 12)).padding(12).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                if let id = entry.3 {
                                    WorkspaceCloseButton(id: "picker-workspace-close-" + id, workspaceTitle: entry.0) { store.closeWorkspace(id) }
                                        .frame(width: 22, height: 24).padding(.trailing, 8)
                                        .disabled(store.followUpPaneID != nil || store.decisionPaneID != nil)
                                }
                            }.background(index == selection ? store.toolPanelTheme.accent.opacity(0.12) : .clear).clipShape(RoundedRectangle(cornerRadius: 5)).id(index)
                                .overlay {
                                    if let id = entry.4 {
                                        HeaderContextMenuRegion(id: "picker-workspace-context-" + id) { window in
                                            store.workspacePickerContextMenu(workspaceID: id, sourceWindow: window)
                                        }
                                    }
                                }
                                .background {
                                    if index == selection { WorkspaceRegion("picker-selected-command", label: entry.0) }
                                }
                        }
                        if entries.isEmpty { Text("No results").foregroundStyle(.secondary).padding(30) }
                    }
                    .padding(8)
                }.frame(height: compact ? min(290, max(56, CGFloat(scrollingEntries.count) * 42 + 12)) : 290)
                    .background(WorkspaceRegion("picker-results"))
                    .onChange(of: selection) { scroll.scrollTo($0) }
                    .onChange(of: query) { _ in scroll.scrollTo(0, anchor: .top) }
            }
            if kind == .sessions {
                Divider()
                Button {
                    store.picker = nil
                    store.newSession()
                } label: {
                    HStack {
                        Label("New Session", systemImage: "square.stack.3d.up")
                        Spacer()
                        Text("⇧⌘N").foregroundStyle(.secondary)
                    }.font(.system(size: 12)).padding(14).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .background(newSessionIndex == selection ? store.toolPanelTheme.accent.opacity(0.12) : .clear)
                    .background(WorkspaceRegion("picker-new-session-footer"))
                    .background {
                        if newSessionIndex == selection { WorkspaceRegion("picker-selected-command", label: "New Session") }
                    }
                Button(action: store.openRemoteHosts) {
                    Label("Add Remote Host…", systemImage: "network")
                        .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }.buttonStyle(.plain).accessibilityLabel("Add Remote Host")
                    .background(remoteHostIndex == selection ? store.toolPanelTheme.accent.opacity(0.12) : .clear)
                    .background(WorkspaceRegion("picker-add-remote-host-footer"))
                    .background {
                        if remoteHostIndex == selection { WorkspaceRegion("picker-selected-command", label: "Add Remote Host…") }
                    }
            }
        }.frame(width: compact ? 320 : 540).toolPanelSurface(store.toolPanelTheme)
            .onChange(of: query) { selection = 0 }
            .onChange(of: resultIdentity) { before, after in
                guard kind == .sessions, before.query == after.query else { return }
                let id = before.ids.indices.contains(selection) ? before.ids[selection] : nil
                if let id, let index = after.ids.firstIndex(of: id) { selection = index }
                else { selection = min(selection, max(0, after.ids.count - 1)) }
            }
    }
    private var quickRows: [Int] {
        guard kind == .sessions else { return [] }
        return Array(entries.indices.filter { entries[$0].4 != nil }.prefix(9))
    }
    private var quickPositions: [Int: Int] {
        Dictionary(uniqueKeysWithValues: quickRows.enumerated().map { ($0.element, $0.offset) })
    }
    private func quickChoose(_ position: Int) {
        let rows = quickRows
        guard rows.indices.contains(position) else { return }
        selection = rows[position]
        choose()
    }
    private func moveSelection(_ delta: Int) {
        let count = entries.count
        guard count > 0 else { selection = 0; return }
        if kind == .sessions {
            selection = (selection + delta + count) % count
        } else {
            selection = min(max(0, selection + delta), count - 1)
        }
    }
    private func choose() {
        guard entries.indices.contains(selection) else { return }
        let action = entries[selection].2
        store.picker = nil
        action()
    }
}
