import SwiftUI
import TerminalCore

struct AgentBadge: View {
    let agent: AgentKind
    var body: some View { AgentLogo(agent: agent) }
}

struct AccountsView: View {
    @ObservedObject var store: AppStore
    @State private var provider = AgentKind.claude
    @State private var label = ""
    @State private var usage: [AccountUsageSnapshot] = []
    @State private var refreshing = Set<String>()
    @State private var renameID: String?
    @State private var renameLabel = ""
    @State private var showRename = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Agent accounts").font(.title2.weight(.semibold))
                    Text("Separate logins. One conversation, even when your account changes.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { store.showAccounts = false }.keyboardShortcut(.cancelAction)
            }
            if store.state.accounts.isEmpty {
                ContentUnavailableView("Add your first account", systemImage: "person.crop.circle.badge.plus", description: Text("Sign in through Claude or Codex in a separate terminal tab."))
                    .frame(height: 190)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.state.accounts) { account in accountRow(account) }
                    }
                }.frame(minHeight: 180, maxHeight: 300)
            }
            HStack {
                Picker("Provider", selection: $provider) { Text("Claude.ai").tag(AgentKind.claude); Text("Codex").tag(AgentKind.codex) }.frame(width: 180)
                TextField("Account name", text: $label).textFieldStyle(.roundedBorder)
                Button("Add account") {
                    let name = label, agent = provider
                    store.perform { _ = try $0.addAccount(provider: agent, label: name) }
                    label = ""
                }.disabled(label.trimmingCharacters(in: .whitespaces).isEmpty || label.count > 100)
            }
            Text("For Codex, review and enable the Trano hooks in /hooks after signing in. Codex may ask again when hook definitions change.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            Toggle(isOn: Binding(get: { store.state.settings.automaticAccountSwitching }, set: { enabled in
                var settings = store.state.settings; settings.automaticAccountSwitching = enabled; store.saveSettings(settings)
            })) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Switch accounts when a quota is reached").font(.callout.weight(.medium))
                    Text("Resumes the same conversation on the next enabled account of the same provider after tools finish. Pinned accounts stay in place.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.toggleStyle(.switch)
            if let launch = store.state.agentLaunches.first(where: { $0.paneID == store.focusedID && $0.lifecycle == .active }),
               let monitor = store.state.supervision.first(where: { $0.generation == launch.id }), let message = monitor.message {
                Label(message, systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24).frame(width: 740).preferredColorScheme(.dark)
            .onAppear { refreshCached() }
            .onChange(of: store.state.revision) { _, _ in refreshCached() }
            .alert("Rename account", isPresented: $showRename) {
                TextField("Name", text: $renameLabel)
                Button("Cancel", role: .cancel) {}
                Button("Save") { if let id = renameID { let name = renameLabel; store.perform { try $0.updateAccount(id, label: name) } } }
            }
    }

    private func accountRow(_ account: AccountProfile) -> some View {
        let snapshot = usage.first { $0.accountID == account.id }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                AgentBadge(agent: account.provider).frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(account.label).fontWeight(.medium)
                        if account.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
                        if !account.enabled { Text("Disabled").font(.caption).foregroundStyle(.secondary) }
                    }
                    Text(status(snapshot)).font(.caption).foregroundStyle(snapshot?.status == .limited ? .orange : .secondary)
                }
                Spacer()
                Button { refresh(account.id) } label: {
                    if refreshing.contains(account.id) { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }.buttonStyle(.borderless).disabled(refreshing.contains(account.id)).help("Refresh account usage")
                Button("Log in") { launch(account.id, login: true) }.disabled(!account.enabled)
                Button("Open") { launch(account.id) }.disabled(!account.enabled)
                Menu {
                    Button("Rename…") { renameID = account.id; renameLabel = account.label; showRename = true }
                    Button(account.enabled ? "Disable" : "Enable") { store.perform { try $0.updateAccount(account.id, enabled: !account.enabled) } }
                    Button(account.pinned ? "Unpin account" : "Pin account") { store.perform { try $0.updateAccount(account.id, pinned: !account.pinned) } }
                    if account.unavailableUntil != nil { Button("Clear retry cooldown") { store.perform { try $0.setAccountCooldown(account.id, until: nil) } } }
                    Button("Move up") { reorder(account.id, offset: -1) }
                    Button("Move down") { reorder(account.id, offset: 1) }
                    if let pane = store.focusedID, let current = store.state.agentLaunches.first(where: { $0.paneID == pane && $0.lifecycle == .active }), current.provider == account.provider, current.accountID != account.id {
                        Divider()
                        Button("Switch current conversation here") { store.perform { _ = try $0.requestAccountSwitch(paneID: pane, targetAccountID: account.id) } }.disabled(!account.enabled)
                    }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22)
            }
            if let snapshot, !snapshot.windows.isEmpty {
                HStack(spacing: 18) {
                    ForEach(snapshot.windows, id: \.id) { window in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(window.id.replacingOccurrences(of: "_", with: " ")); Spacer(); Text("\(Int(window.usedPercent))%") }.font(.caption2)
                            ProgressView(value: window.usedPercent, total: 100).tint(window.usedPercent >= 100 ? .orange : Color(red: 0.52, green: 0.84, blue: 0.76))
                            if let reset = window.resetsAt { Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }.padding(14).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private func status(_ snapshot: AccountUsageSnapshot?) -> String {
        guard let snapshot else { return "Usage has not been reported" }
        switch snapshot.status {
        case .available: return "Available"
        case .limited: return "Quota reached"
        case .authenticationRequired: return "Sign in to continue"
        case .unavailable: return snapshot.message ?? "Usage refresh unavailable"
        case .unknown: return snapshot.provider == .claude ? "Usage appears after Claude reports it during a conversation" : "Refresh to check usage"
        }
    }

    private func refreshCached() {
        let runtime = store.runtime
        store.queue.async {
            let values = (try? runtime.accountUsage()) ?? []
            DispatchQueue.main.async { usage = values }
        }
    }

    private func refresh(_ id: String) {
        refreshing.insert(id)
        let runtime = store.runtime
        store.queue.async {
            let result = Result { try runtime.refreshAccountUsage(accountID: id) }
            DispatchQueue.main.async {
                refreshing.remove(id)
                if case .failure(let error) = result { store.message = error.localizedDescription }
                refreshCached()
            }
        }
    }

    private func reorder(_ id: String, offset: Int) {
        var ids = store.state.accounts.map(\.id)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        store.perform { try $0.reorderAccounts(ids) }
    }

    private func launch(_ id: String, login: Bool = false) {
        let directory = store.currentDirectory
        store.showAccounts = false
        store.perform { _ = try $0.launchAccount(id, cwd: directory, login: login) }
    }
}
