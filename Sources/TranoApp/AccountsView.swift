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
    @State private var newOrganizationID = ""
    @State private var newOrganizationUUID = ""
    @State private var newOrganizationName = ""
    @State private var organizationDraft: AccountOrganizationDraft?

    var body: some View {
        VStack(spacing: 0) {
            ToolPanelHeader("Agent accounts", canClose: organizationDraft?.isSaving != true, onClose: closeAccounts)
            VStack(alignment: .leading, spacing: ToolPanelMetrics.sectionSpacing) {
                Text("Separate logins. One conversation, even when your account changes.")
                    .font(.callout).foregroundStyle(.secondary)
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
                    Button("Add account", action: addAccount).disabled(!canAddAccount)
                }
                if provider == .claude {
                    HStack {
                        Picker("Organization", selection: $newOrganizationID) {
                            Text("Unbound").tag("")
                            ForEach(knownOrganizations) { organization in Text(organization.name ?? organization.uuid).tag(organization.uuid) }
                            Text("Other UUID…").tag("other")
                        }.frame(maxWidth: 320)
                        if newOrganizationID == "other" {
                            TextField("Organization UUID", text: $newOrganizationUUID).textFieldStyle(.roundedBorder)
                            TextField("Name (optional)", text: $newOrganizationName).textFieldStyle(.roundedBorder).frame(width: 150)
                        }
                    }
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
            }.padding(ToolPanelMetrics.contentInset)
        }.frame(width: 740).toolPanelSurface(store.toolPanelTheme)
            .dismissOnOutsideClick("accounts-sheet", canDismiss: { organizationDraft?.isSaving != true }, perform: closeAccounts)
            .workspacePanel(isPresented: organizationDraft != nil) {
                if let draft = organizationDraft {
                    AccountOrganizationEditorPresentation(draft: draft, theme: store.toolPanelTheme) { organizationDraft = nil }
                }
            }
            .onAppear { refreshCached() }
            .onChange(of: store.state.revision) { _, _ in refreshCached() }
            .onChange(of: store.accountUsageSnapshots) { _, values in usage = values }
            .alert("Rename account", isPresented: $showRename) {
                TextField("Name", text: $renameLabel)
                Button("Cancel", role: .cancel) {}
                Button("Save") { if let id = renameID { let name = renameLabel; store.perform { try $0.updateAccount(id, label: name) } } }
            }
    }

    private func closeAccounts() {
        guard organizationDraft?.isSaving != true else { return }
        store.showAccounts = false
    }

    private func accountRow(_ account: AccountProfile) -> some View {
        let snapshot = usage.first { $0.accountID == account.id && $0.provider == account.provider }
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
                    if account.provider == .claude {
                        Text(organizationStatus(account.organization)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                Button { refresh(account.id) } label: {
                    if refreshing.contains(account.id) { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }.buttonStyle(.borderless).disabled(refreshing.contains(account.id)).help(account.provider == .claude ? "Refresh account usage and organization" : "Refresh account usage")
                if account.provider == .claude {
                    Button("Organization…") { editOrganization(account) }.buttonStyle(.borderless)
                }
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
                        Button("Switch current conversation here") { store.perform(holdingTransaction: false) { _ = try $0.requestAccountSwitch(paneID: pane, targetAccountID: account.id) } }.disabled(!account.enabled)
                    }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22)
            }
            if let snapshot {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    if let count = snapshot.freshAvailableResetCount(now: context.date), count > 0 {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("\(count) \(count == 1 ? "reset" : "resets") available", systemImage: "ticket")
                                .font(.caption).foregroundStyle(.mint)
                                .accessibilityIdentifier("account-reset-" + account.id)
                            if let expiration = snapshot.resetCredits?.credits?.filter({ $0.status == .available && ($0.expiresAt ?? .distantFuture) > context.date }).compactMap(\.expiresAt).min() {
                                Text("Expires \(expiration.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if let snapshot, !snapshot.windows.isEmpty {
                HStack(spacing: 18) {
                    ForEach(snapshot.windows, id: \.id) { window in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(window.id.replacingOccurrences(of: "_", with: " ")); Spacer(); Text("\(Int(window.usedPercent))%") }.font(.caption2)
                            ProgressView(value: window.usedPercent, total: 100).tint(window.usedPercent >= 100 ? .orange : store.toolPanelTheme.accent)
                            if let reset = window.resetsAt { Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }.padding(ToolPanelMetrics.sectionSpacing).background(store.toolPanelTheme.foreground.opacity(0.035), in: RoundedRectangle(cornerRadius: ToolPanelMetrics.cornerRadius))
    }

    private var knownOrganizations: [ClaudeOrganizationSelection] {
        var values: [ClaudeOrganizationSelection] = []
        for account in store.state.accounts where account.provider == .claude {
            for value in [account.organization?.selection, account.organization?.observed].compactMap({ $0 }) {
                if !values.contains(where: { $0.uuid == value.uuid }) { values.append(value) }
            }
        }
        return values
    }

    private func newOrganization() throws -> ClaudeOrganizationSelection? {
        guard provider == .claude, !newOrganizationID.isEmpty else { return nil }
        if newOrganizationID == "other" {
            guard let selection = try AccountOrganizationValidation.selection(uuid: newOrganizationUUID, name: newOrganizationName) else {
                throw TerminalError.invalid("Enter an organization UUID")
            }
            return selection
        }
        guard let choice = knownOrganizations.first(where: { $0.uuid == newOrganizationID }) else {
            throw TerminalError.invalid("This organization choice changed. Choose it again.")
        }
        return choice
    }

    private var canAddAccount: Bool {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.count <= 100 else { return false }
        do { _ = try newOrganization(); return true } catch { return false }
    }

    private func addAccount() {
        do {
            let organization = try newOrganization(), name = label, agent = provider
            store.perform(holdingTransaction: false, completion: { error in
                if error == nil { label = ""; newOrganizationID = ""; newOrganizationUUID = ""; newOrganizationName = "" }
            }) { _ = try $0.addAccount(provider: agent, label: name, organization: organization) }
        } catch { store.message = error.localizedDescription }
    }

    private func organizationStatus(_ state: AccountOrganizationState?) -> String {
        guard let selection = state?.selection else {
            return state?.observed.map { "Unbound · observed " + ($0.name ?? $0.uuid) } ?? "Organization: Unbound"
        }
        let configured = selection.name ?? selection.uuid
        switch state?.verification ?? .unverified {
        case .verified: return "Organization: " + configured + " · Verified"
        case .mismatch: return "Organization: " + configured + " · Mismatch: " + (state?.observed?.name ?? state?.observed?.uuid ?? "unknown")
        case .missing: return "Organization: " + configured + " · Provider did not report an organization"
        case .unavailable: return "Organization: " + configured + " · Verification unavailable"
        case .unbound, .unverified: return "Organization: " + configured + " · Unverified"
        }
    }

    private func editOrganization(_ account: AccountProfile) {
        let runtime = store.runtime, queue = store.queue
        organizationDraft = AccountOrganizationDraft(profileID: account.id, state: account.organization, knownOrganizations: knownOrganizations,
            isCurrent: { id, binding in
                store.state.accounts.contains { $0.id == id && $0.provider == .claude && ($0.organization?.bindingID ?? "") == binding }
            }, refresh: { id, binding in
                let value = try await AccountOrganizationBackground.run(on: queue) {
                    try runtime.refreshAccountOrganization(accountID: id, expectedBindingID: binding)
                }
                store.perform(restoringContext: false, holdingTransaction: false) { _ in }
                return value
            }, save: { id, binding, selection in
                try await AccountOrganizationBackground.run(on: queue) {
                    try runtime.setAccountOrganization(id, selection: selection, expectedBindingID: binding)
                }
                store.perform(restoringContext: false, holdingTransaction: false) { _ in }
            })
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
        DispatchQueue.global(qos: .utility).async {
            let result = Result {
                if try runtime.state().accounts.first(where: { $0.id == id })?.provider == .claude {
                    _ = try runtime.refreshAccountOrganization(accountID: id)
                }
                return try runtime.refreshAccountUsage(accountID: id)
            }
            DispatchQueue.main.async {
                refreshing.remove(id)
                if case .failure(let error) = result { store.message = error.localizedDescription }
                store.perform(restoringContext: false, holdingTransaction: false) { _ in }
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
        store.perform(holdingTransaction: false) { _ = try $0.launchAccount(id, cwd: directory, login: login) }
    }
}

private enum AccountOrganizationBackground {
    static func run<Value>(on queue: DispatchQueue, work: @escaping () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: work)) }
        }
    }
}

struct AccountOrganizationEditorPresentation: View {
    @ObservedObject var draft: AccountOrganizationDraft
    @StateObject private var cancellation = AccountOrganizationCancellation()
    var theme: ToolPanelTheme = .defaultDark
    let close: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            ToolPanelHeader("Claude organization", canClose: !draft.isSaving, closeLabel: "Cancel", onClose: cancellation.cancel)
            VStack(alignment: .leading, spacing: ToolPanelMetrics.sectionSpacing) {
                Text("Login preselects this organization. Trano verifies the reported organization before starting or switching. Running agents keep their existing login.")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 460, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                OrganizationSelectionControls(draft: draft, cancellation: cancellation, theme: theme).frame(width: 460, height: draft.usesManualEntry ? 290 : 228)
            }.padding(ToolPanelMetrics.contentInset)
        }.toolPanelSurface(theme).interactiveDismissDisabled(draft.isSaving)
            .dismissOnOutsideClick("account-organization-sheet-" + draft.profileID + "-" + draft.bindingID,
                canDismiss: { cancellation.canCancel }, perform: cancellation.cancel)
            .onChange(of: draft.isClosed) { _, closed in if closed { close() } }
    }
}
