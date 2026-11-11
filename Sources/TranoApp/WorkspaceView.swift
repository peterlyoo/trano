import AppKit
import SwiftUI
import TerminalCore
import UniformTypeIdentifiers

private let surface = Color(red: 20/255, green: 20/255, blue: 22/255)
private let separatorColor = Color.white.opacity(0.08)
private let accent = Color(red: 133/255, green: 215/255, blue: 193/255)

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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "terminal").foregroundStyle(accent)
                Text("Trano").font(.system(size: 13, weight: .semibold))
                Text("DEVELOPMENT").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button { store.showRemoteHosts = true } label: {
                    HStack { Image(systemName: "network"); Text(store.sessions.first { $0.id == store.focusedID }?.host ?? "Local") }.font(.system(size: 11)).foregroundStyle(.secondary)
                }.help("Remote hosts")
                Divider().frame(height: 14)
                Button { store.picker = .sessions } label: { Image(systemName: "magnifyingglass") }.help("Switch Session · ⌘K").accessibilityLabel("Switch Session")
                Button { store.showActivity.toggle() } label: { Image(systemName: "waveform.path") }
                    .help("Show Activity").accessibilityLabel("Show Activity")
                    .popover(isPresented: $store.showActivity, arrowEdge: .top) {
                        activity.frame(width: 320, height: 420).preferredColorScheme(.dark)
                    }
                Button { store.showAccounts = true } label: { Image(systemName: "person.crop.circle") }.help("Agent accounts").accessibilityLabel("Agent accounts")
                Button { store.showExtensions = true } label: { Image(systemName: "puzzlepiece.extension") }.help("Agent extensions").accessibilityLabel("Agent extensions")
                Button { store.showVoice = true } label: { Image(systemName: "mic") }.help("Voice Input").accessibilityLabel("Voice Input").disabled(store.focusedID == nil)
                Button { store.showSettings = true } label: { Image(systemName: "gearshape") }.help("Settings · ⌘,").accessibilityLabel("Settings")
            }
            .buttonStyle(.plain).padding(.horizontal, 18).frame(height: 43).background(surface)
            Rectangle().fill(separatorColor).frame(height: 1)
            HStack(spacing: 0) {
                sidebar.frame(width: 216)
                Rectangle().fill(separatorColor).frame(width: 1)
                VStack(spacing: 0) {
                    tabs
                    Rectangle().fill(separatorColor).frame(height: 1)
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
                    }
                }
            }
            Rectangle().fill(separatorColor).frame(height: 1)
            HStack(spacing: 8) {
                Circle().fill(accent).frame(width: 5, height: 5)
                Text("Persistent sessions").font(.system(size: 10))
                Spacer()
                Text("\(store.sessions.filter(\.alive).count) live").font(.system(size: 10, design: .monospaced))
                Text("·").foregroundStyle(.tertiary)
                Text(store.sessions.first { $0.id == store.focusedID }?.host ?? "local").font(.system(size: 10))
            }.foregroundStyle(.secondary).padding(.horizontal, 14).frame(height: 26).background(surface)
        }
        .background(.clear)
        .foregroundStyle(Color(NSColor(hex: "#ECECEE")))
        .preferredColorScheme(.dark)
        .frame(minWidth: 900, minHeight: 580)
        .sheet(item: $store.picker) { kind in PickerView(store: store, kind: kind) }
        .sheet(isPresented: $store.showSettings) { SettingsView(store: store) }
        .sheet(isPresented: $showAppearanceProfiles) { ProfileAppearanceView(store: store) }
        .sheet(isPresented: $store.showVoice) { VoiceInputView(store: store) }
        .sheet(isPresented: $store.showRemoteHosts) { RemoteHostsView(store: store) }
        .sheet(isPresented: $store.showAccounts) { AccountsView(store: store) }
        .sheet(isPresented: $store.showExtensions) { ExtensionsView(store: store) }
        .sheet(item: $store.remotePathRequest) { RemotePathsView(store: store, request: $0) }
        .alert("Trano", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK") { store.message = nil }
        } message: { Text(store.message ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SESSIONS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { store.execute(.newSession) } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("New Session · ⇧⌘N")
            }.padding(.horizontal, 15).padding(.top, 22).padding(.bottom, 14)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(store.state.layout.workspaces) { workspace in
                        let workspaceTabs = store.state.layout.tabs.filter { $0.workspaceID == workspace.id }
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                Button { store.toggleCollapse(workspace.id) } label: {
                                    Image(systemName: workspace.collapsed ? "chevron.right" : "chevron.down").font(.system(size: 8, weight: .bold)).frame(width: 12)
                                }.buttonStyle(.plain).accessibilityLabel(workspace.collapsed ? "Expand session" : "Collapse session")
                                Button { store.selectWorkspace(workspace.id) } label: {
                                    HStack {
                                        Image(systemName: "square.stack.3d.up").foregroundStyle(workspace.id == store.state.layout.selectedWorkspaceID ? accent : .secondary)
                                        Text(workspace.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                        Spacer(minLength: 2)
                                        Text(workspace.closed ? "closed" : "\(workspaceTabs.count)").font(.system(size: 9)).foregroundStyle(.secondary)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }.padding(.horizontal, 9).padding(.vertical, 9)
                                .background(workspace.id == store.state.layout.selectedWorkspaceID ? Color.white.opacity(0.05) : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .contextMenu {
                                    Button("Open Session") { store.selectWorkspace(workspace.id) }
                                    Button("Rename Session…") { store.rename(.renameSession, target: workspace.id) }
                                    Button("Close Session View") { store.perform { try $0.update { $0.layout.closeWorkspace(workspace.id) } } }
                                }
                            if !workspace.collapsed && !workspace.closed {
                                ForEach(workspaceTabs) { tab in
                                    let session = store.sessions.first { $0.id == tab.panes.first }
                                    Button { store.selectTab(tab.id) } label: {
                                        HStack(spacing: 8) {
                                            AgentBadge(agent: session?.agent ?? .shell).font(.system(size: 10))
                                            Text(tab.title == "Terminal" ? session?.title ?? "Terminal" : tab.title).font(.system(size: 11)).lineLimit(1)
                                            Spacer(minLength: 0)
                                            if let status = session?.activity.state, ![.unknown, .idle].contains(status) { Circle().fill(activityColor(status)).frame(width: 5, height: 5) }
                                        }.padding(.leading, 28).padding(.trailing, 12).padding(.vertical, 8)
                                            .background(tab.id == store.state.layout.selectedTabID ? accent.opacity(0.065) : .clear)
                                            .clipShape(RoundedRectangle(cornerRadius: 5))
                                    }.buttonStyle(.plain)
                                        .modifier(TabActivityHover(snapshot: TabActivitySnapshot(tab: tab, sessions: store.sessions), placement: .trailing))
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

    private var tabs: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(store.state.layout.currentTabs) { tab in
                        let session = store.sessions.first { $0.id == tab.panes.first }
                        HStack(spacing: 9) {
                            AgentBadge(agent: session?.agent ?? .shell).font(.system(size: 10))
                            Text(tab.title == "Terminal" ? session?.title ?? "Terminal" : tab.title).font(.system(size: 11)).lineLimit(1)
                            if tab.panes.count > 1 { Text("\(tab.panes.count)").font(.system(size: 9)).foregroundStyle(.secondary) }
                            Button { store.perform { try $0.update { $0.layout.closeTab(tab.id) } } } label: { Image(systemName: "xmark").font(.system(size: 8)).foregroundStyle(.tertiary) }.buttonStyle(.plain).help("Close Tab · keep running")
                        }.padding(.horizontal, 16).frame(height: 37)
                            .background(tab.id == store.state.layout.selectedTabID ? Color.white.opacity(0.045) : .clear)
                            .overlay(alignment: .bottom) { if tab.id == store.state.layout.selectedTabID { Rectangle().fill(accent).frame(height: 1) } }
                            .contentShape(Rectangle()).onTapGesture { store.selectTab(tab.id) }
                            .modifier(TabActivityHover(snapshot: TabActivitySnapshot(tab: tab, sessions: store.sessions), placement: .below))
                            .modifier(PaneDropTarget(store: store, tabID: tab.id))
                            .contextMenu {
                                Button("Rename Tab…") { store.rename(.renameTab, target: tab.id) }
                                Button("Move Tab Backward") { store.perform { try $0.update { $0.layout.reorderTab(tab.id, delta: -1) } } }
                                Button("Move Tab Forward") { store.perform { try $0.update { $0.layout.reorderTab(tab.id, delta: 1) } } }
                                Button("Close Tab · keep running") { store.perform { try $0.update { $0.layout.closeTab(tab.id) } } }
                            }
                    }
                }
            }
            Button(action: store.newTab) { Image(systemName: "plus").font(.system(size: 12)) }.buttonStyle(.plain).padding(.horizontal, 13).help("New Tab · ⌘T")
        }.background(surface)
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
            return AnyView(PaneSplitView(id: id, axis: axis, ratio: ratio, first: tree(first), second: tree(second)) { value in
                store.resizeSplit(id, ratio: value)
            })
        }
    }

    private func pane(_ id: String) -> some View {
        let session = store.sessions.first { $0.id == id }
        let appearance = store.state.settings.resolvedAppearance(for: id)
        let profileID = store.state.settings.paneAppearanceProfiles[id]
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(id == store.focusedID ? accent : .secondary).frame(width: 5, height: 5)
                AgentLogo(agent: session?.agent ?? .shell).frame(width: 13, height: 13)
                Text(session?.agent.rawValue ?? "shell").font(.system(size: 10, weight: .medium))
                Text(session.map { URL(fileURLWithPath: $0.cwd).lastPathComponent } ?? "").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).help(session?.cwd ?? "")
                Spacer()
                Menu {
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
                } label: { Image(systemName: "paintpalette").font(.system(size: 10)) }
                    .menuStyle(.borderlessButton).frame(width: 20).help("Appearance profile").accessibilityLabel("Pane appearance profile")
                Text(session?.activity.state.rawValue ?? "unknown").font(.system(size: 9)).foregroundStyle(activityColor(session?.activity.state ?? .unknown))
            }.padding(.horizontal, 12).frame(height: 28).background(surface.opacity(0.45))
                .contentShape(Rectangle()).onTapGesture { store.focus(id) }
                .onDrag { PaneDrag.provider(id) }
            if let recovery = store.state.recoveryResults.first(where: { $0.paneID == id }), [.needsAttention, .failed, .restoring].contains(recovery.status) {
                HStack {
                    Image(systemName: recovery.status == .restoring ? "arrow.clockwise" : "exclamationmark.circle")
                    Text(recovery.message).font(.caption).lineLimit(2)
                    Spacer()
                    if recovery.status != .restoring && session?.alive == false { Button("Retry") { store.perform(restoringContext: false, holdingTransaction: false) { _ = try $0.recoverSessions(paneID: id) } } }
                }.foregroundStyle(.orange).padding(10).background(surface)
            }
            TerminalPane(store: store, id: id).padding(8).background { TerminalBackgroundView(settings: appearance) }
        }.overlay { Rectangle().stroke(id == store.focusedID ? accent.opacity(0.35) : .clear, lineWidth: 1).allowsHitTesting(false) }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Activity").font(.system(size: 13, weight: .semibold)); Spacer(); Button { store.showActivity = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).keyboardShortcut(.cancelAction).help("Close Activity").accessibilityLabel("Close Activity") }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(store.sessions.sorted { $0.activity.updatedAt > $1.activity.updatedAt }) { session in
                        Button { store.showActivity = false; store.attach(session.id) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack { Circle().fill(activityColor(session.activity.state)).frame(width: 6, height: 6); Text(session.activity.state.rawValue.capitalized).font(.system(size: 11, weight: .medium)) }
                                Text(session.title).font(.system(size: 12))
                                if !session.activity.reason.isEmpty { Text(session.activity.reason).font(.system(size: 11)).foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }.padding(16).background(surface)
    }
}

struct PaneSplitView: View {
    let id: String
    let axis: SplitAxis
    let ratio: Double
    let first: AnyView
    let second: AnyView
    let resize: (Double) -> Void
    @State private var dragRatio: Double?

    var body: some View {
        GeometryReader { geometry in
            let length = max(1, (axis == .horizontal ? geometry.size.width : geometry.size.height) - 5)
            let minimum = min(0.4, (axis == .horizontal ? 180.0 : 100.0) / length)
            let value = min(1 - minimum, max(minimum, dragRatio ?? ratio))
            let divider = Rectangle().fill(separatorColor).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                    let offset = axis == .horizontal ? gesture.translation.width : gesture.translation.height
                    dragRatio = min(1 - minimum, max(minimum, ratio + offset / length))
                }.onEnded { _ in resize(dragRatio ?? ratio); dragRatio = nil })
                .onHover { inside in
                    if inside { (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() }
                    else { NSCursor.pop() }
                }
            if axis == .horizontal {
                HStack(spacing: 0) { first.frame(width: length * value); divider.frame(width: 5); second }
            } else {
                VStack(spacing: 0) { first.frame(height: length * value); divider.frame(height: 5); second }
            }
        }
    }
}

struct PickerView: View {
    @ObservedObject var store: AppStore
    let kind: AppStore.PickerKind
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool
    private var entries: [(String, String, () -> Void)] {
        var all: [(String, String, () -> Void)] = []
        switch kind {
        case .commands:
            return ActionCatalog.all.filter { query.isEmpty || ($0.title + " " + $0.category + " " + $0.keywords).localizedCaseInsensitiveContains(query) }
                .map { item in (item.title, (store.state.settings.keyBindings[item.id] ?? item.bindings).first.map(KeyBindingMap.display) ?? "", { store.execute(item.action) }) }
        case .sessions:
            all = store.state.layout.workspaces.map { workspace in
                let count = store.state.layout.tabs.filter { $0.workspaceID == workspace.id }.count
                return (workspace.title, "\(count) tabs", { store.selectWorkspace(workspace.id) })
            }
        case .movePane:
            all = store.state.layout.tabs.filter { $0.id != store.selectedTab?.id }.map { tab in
                let workspace = store.state.layout.workspaces.first { $0.id == tab.workspaceID }?.title ?? ""
                let title = tab.title == "Terminal" ? store.sessions.first { $0.id == tab.panes.first }?.title ?? tab.title : tab.title
                return (title, workspace, { if let id = store.focusedID { store.move(id, to: tab.id) } })
            }
        case .anything:
            all = store.sessions.map { item in
                let tab = store.state.layout.tabs.first { $0.panes.contains(item.id) }
                let workspace = store.state.layout.workspaces.first { $0.id == tab?.workspaceID }?.title ?? "Detached"
                return (item.title, workspace + " · " + URL(fileURLWithPath: item.cwd).lastPathComponent, { store.attach(item.id) })
            }
        }
        return all.filter { query.isEmpty || ($0.0 + " " + $0.1).localizedCaseInsensitiveContains(query) }
    }
    private var placeholder: String {
        switch kind {
        case .commands: return "Search commands…"
        case .sessions: return "Change session…"
        case .anything: return "Find a pane, tab or session…"
        case .movePane: return "Move pane to tab…"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(accent); TextField(placeholder, text: $query).textFieldStyle(.plain).focused($focused).onSubmit(choose) }
                .padding(20)
            Divider()
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        Button { selection = index; choose() } label: {
                            HStack { Text(entry.0); Spacer(); Text(entry.1).foregroundStyle(.secondary) }
                                .font(.system(size: 12)).padding(12).background(index == selection ? accent.opacity(0.1) : .clear).clipShape(RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain)
                    }
                    if entries.isEmpty { Text("No results").foregroundStyle(.secondary).padding(30) }
                }.padding(8)
            }.frame(height: 290)
        }.frame(width: 540).background(surface).preferredColorScheme(.dark)
            .onAppear { focused = true }
            .onChange(of: query) { selection = 0 }
            .onMoveCommand { direction in
                if direction == .down { selection = min(selection + 1, max(0, entries.count - 1)) }
                if direction == .up { selection = max(0, selection - 1) }
            }
            .onExitCommand { store.picker = nil }
    }
    private func choose() {
        guard entries.indices.contains(selection) else { return }
        let action = entries[selection].2
        store.picker = nil
        action()
    }
}
