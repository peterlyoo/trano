import AppKit
import TerminalCore

enum ServerSettingsNativeAction: Equatable {
    case refresh, refreshServer, signIn, signOut, cancel, pair, copyAddress, copyLocalAPI
    case revokeClient(String), setClientRemoteControl(String, Bool)
}

@MainActor private final class ServerSettingsActionButton: NSButton {
    var handler: () -> Void = {}
    convenience init(_ title: String, id: String, checkbox: Bool = false, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title; identifier = NSUserInterfaceItemIdentifier(id)
        if checkbox { setButtonType(.switch) } else { bezelStyle = .rounded }
        handler = action; target = self; self.action = #selector(invoke)
    }
    @objc private func invoke() { handler() }
}

@MainActor final class ServerSettingsTextField: NSTextField, NSTextFieldDelegate {
    var onChange: (String) -> Void = { _ in }
    var editorProvider: (() -> NSTextView?)?
    private var committedValue = ""
    private var desiredEnabled = true
    private var draftEditor: NSTextView? { editorProvider?() ?? currentEditor() as? NSTextView }
    var activeDraftValue: String? {
        guard let editor = draftEditor else { return nil }
        return editor.hasMarkedText() ? committedValue : editor.string
    }
    convenience init(_ value: String, id: String, action: @escaping (String) -> Void) {
        self.init(frame: .zero)
        stringValue = value; identifier = NSUserInterfaceItemIdentifier(id); onChange = action; delegate = self
        committedValue = value
        usesSingleLineMode = true
    }
    func synchronize(_ value: String, enabled: Bool = true) {
        desiredEnabled = enabled
        guard draftEditor == nil else { return }
        if stringValue != value { stringValue = value }
        committedValue = value
        if isEnabled != enabled { isEnabled = enabled }
    }
    func controlTextDidChange(_ notification: Notification) {
        guard draftEditor?.hasMarkedText() != true else { return }
        committedValue = draftEditor?.string ?? stringValue
        onChange(committedValue)
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard draftEditor?.hasMarkedText() != true else { return }
        committedValue = draftEditor?.string ?? stringValue
        onChange(committedValue)
        if draftEditor == nil, isEnabled != desiredEnabled { isEnabled = desiredEnabled }
    }
}

@MainActor private enum ServerSettingsLayout {
    static func label(_ value: String, id: String? = nil) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.font = .systemFont(ofSize: 12); field.lineBreakMode = .byTruncatingMiddle
        field.isSelectable = true
        if let id { field.identifier = NSUserInterfaceItemIdentifier(id) }
        return field
    }
    static func title(_ value: String) -> NSTextField {
        let field = label(value); field.font = .systemFont(ofSize: 12, weight: .semibold); return field
    }
    static func row(_ title: String, _ control: NSView) -> NSStackView {
        let label = self.label(title); label.isSelectable = false
        label.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let row = NSStackView(views: [label, control]); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 12
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }
    static func install(_ views: [NSView], in host: NSView) {
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: host.leadingAnchor), stack.trailingAnchor.constraint(equalTo: host.trailingAnchor), stack.topAnchor.constraint(equalTo: host.topAnchor), stack.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor)])
        for view in views { view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true }
    }
}

@MainActor final class ServerSettingsNativeView: NSView {
    var onChange: (ServerPreferences) -> Void = { _ in }
    var onAction: (ServerSettingsNativeAction) -> Void = { _ in }
    private var preferences = ServerPreferences()
    private var labels: [String: NSTextField] = [:]
    private var buttons: [String: NSButton] = [:]
    private var labelField: ServerSettingsTextField!
    private var hostnameField: ServerSettingsTextField!
    private let clientStack = NSStackView()
    private let clientTitle = ServerSettingsLayout.title("Paired Clients")
    private let missingTool = ServerSettingsLayout.label("Tailscale CLI is not installed.")
    private let errorField = ServerSettingsLayout.label("")
    private struct ClientRow {
        let row: NSStackView
        let label: NSTextField
        let control: ServerSettingsActionButton
        let revoke: NSButton
    }
    private var clientRows: [String: ClientRow] = [:]
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 590, height: 610) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }
    required init?(coder: NSCoder) { return nil }

    private func build() {
        var views: [NSView] = [ServerSettingsLayout.title("Server")]
        for (title, id) in [("Status", "server-status"), ("Compatibility", "server-compatibility"), ("Version", "server-version"), ("Uptime", "server-uptime"), ("Local API", "server-local-api")] {
            views.append(valueRow(title, id))
        }
        let tools = NSStackView(views: [actionButton("Refresh", "server-refresh", .refresh, enabled: true), actionButton("Refresh Server", "server-refresh-helper", .refreshServer, enabled: false), actionButton("Copy Local API", "server-copy-local-api", .copyLocalAPI, enabled: true)])
        tools.spacing = 8; views.append(tools)
        labelField = ServerSettingsTextField("", id: "server-label") { [weak self] value in self?.edit { $0.clientLabel = value } }
        views.append(ServerSettingsLayout.row("Label", labelField))
        views.append(toggle("Remote Control", "server-remote-control") { $0.remoteControl = $1 })
        views.append(ServerSettingsLayout.title("Tailscale"))
        views.append(toggle("Serve over Tailscale", "server-serve") { $0.serveOverTailscale = $1 })
        hostnameField = ServerSettingsTextField("", id: "server-hostname") { [weak self] value in self?.edit { $0.preferredHostname = value } }
        hostnameField.placeholderString = "System hostname"
        views.append(ServerSettingsLayout.row("Preferred Hostname", hostnameField))
        views.append(toggle("Limit access to your Tailscale account", "server-same-account") { $0.limitToSameAccount = $1 })
        for (title, id) in [("Remote Address", "server-remote-address"), ("Tags", "server-tags"), ("Control Server", "server-control-server")] {
            views.append(valueRow(title, id))
        }
        let authentication = NSStackView(views: [
            actionButton("Sign In…", "server-sign-in", .signIn, enabled: false), actionButton("Sign Out", "server-sign-out", .signOut, enabled: false),
            actionButton("Cancel", "server-cancel", .cancel, enabled: false), actionButton("Copy Address", "server-copy-address", .copyAddress, enabled: false),
            actionButton("Pair Client…", "server-pair", .pair, enabled: false)
        ])
        authentication.spacing = 8; views.append(authentication)
        views.append(missingTool)
        views.append(ServerSettingsLayout.label("Sign-in, sign-out and hostname changes apply to this Mac’s Tailscale connection."))
        clientTitle.isHidden = true; views.append(clientTitle)
        clientStack.orientation = .vertical; clientStack.alignment = .leading; clientStack.spacing = 8
        clientStack.isHidden = true; views.append(clientStack)
        errorField.textColor = .systemOrange; errorField.isHidden = true; views.append(errorField)
        ServerSettingsLayout.install(views, in: self)
    }

    func configure(preferences: ServerPreferences, snapshot: ServerRuntimeSnapshot, tailscale: TailscaleSnapshot?, clients: [AuthorizedRemoteClient], toolAvailable: Bool, busy: Bool, error: String?) {
        self.preferences = preferences
        let status = snapshot.running ? "Running" : "Not running"
        let compatibility: String
        switch snapshot.compatibility {
        case .compatible: compatibility = "Compatible"
        case .restartRequired: compatibility = "Installed update requires a server refresh"
        case .unsupported: compatibility = "Unsupported API version"
        case .unavailable: compatibility = "Unavailable"
        }
        setLabel("server-status", status); setLabel("server-compatibility", compatibility)
        setLabel("server-version", snapshot.identity.map { $0.version + " (" + $0.buildNumber + ")" } ?? "Unavailable")
        setLabel("server-uptime", snapshot.uptime.map { Duration.seconds($0).formatted(.time(pattern: .hourMinuteSecond)) } ?? "Unavailable")
        setLabel("server-local-api", snapshot.localAPIURL)
        labelField.synchronize(preferences.clientLabel)
        hostnameField.synchronize(preferences.preferredHostname, enabled: toolAvailable && !busy)
        setToggle("server-remote-control", value: preferences.remoteControl, enabled: !busy)
        setToggle("server-serve", value: preferences.serveOverTailscale, enabled: toolAvailable && !busy)
        setToggle("server-same-account", value: preferences.limitToSameAccount, enabled: !busy)
        setLabel("server-remote-address", preferences.serveOverTailscale && snapshot.remoteReady && error == nil ? tailscale?.remoteAddress?.absoluteString ?? "Unavailable" : "Unavailable")
        setLabel("server-tags", tailscale.map { $0.tags.isEmpty ? "None" : $0.tags.joined(separator: ", ") } ?? "Unavailable")
        setLabel("server-control-server", tailscale?.controlURL ?? "Unavailable")
        buttons["server-refresh"]?.isEnabled = !busy
        buttons["server-refresh-helper"]?.isEnabled = snapshot.compatibility == .restartRequired && !busy
        buttons["server-sign-in"]?.isEnabled = toolAvailable && !busy
        buttons["server-sign-out"]?.isEnabled = toolAvailable && tailscale != nil && !busy
        buttons["server-cancel"]?.isEnabled = busy
        buttons["server-copy-address"]?.isEnabled = preferences.serveOverTailscale && snapshot.remoteReady && tailscale?.remoteAddress != nil && !busy
        buttons["server-pair"]?.isEnabled = preferences.serveOverTailscale && snapshot.remoteReady && !busy
        missingTool.isHidden = toolAvailable
        reconcileClients(clients, busy: busy)
        if let error, errorField.currentEditor() == nil, errorField.stringValue != error { errorField.stringValue = error }
        errorField.isHidden = error == nil
    }
    private func edit(_ action: (inout ServerPreferences) -> Void) {
        if let value = labelField.activeDraftValue { preferences.clientLabel = value }
        if let value = hostnameField.activeDraftValue { preferences.preferredHostname = value }
        action(&preferences); onChange(preferences)
    }
    private func valueRow(_ title: String, _ id: String) -> NSView {
        let field = ServerSettingsLayout.label("Unavailable", id: id); labels[id] = field
        return ServerSettingsLayout.row(title, field)
    }
    private func setLabel(_ id: String, _ value: String) {
        guard let field = labels[id], field.currentEditor() == nil, field.stringValue != value else { return }
        field.stringValue = value
    }
    private func setToggle(_ id: String, value: Bool, enabled: Bool) {
        buttons[id]?.state = value ? .on : .off; buttons[id]?.isEnabled = enabled
    }
    private func toggle(_ title: String, _ id: String, edit: @escaping (inout ServerPreferences, Bool) -> Void) -> NSButton {
        let button = ServerSettingsActionButton(title, id: id, checkbox: true) {}
        button.handler = { [weak self, weak button] in
            guard let button else { return }; self?.edit { edit(&$0, button.state == .on) }
        }
        buttons[id] = button
        return button
    }
    private func actionButton(_ title: String, _ id: String, _ action: ServerSettingsNativeAction, enabled: Bool) -> NSButton {
        let button = ServerSettingsActionButton(title, id: id) { [weak self] in self?.onAction(action) }
        button.isEnabled = enabled; buttons[id] = button
        return button
    }

    private func reconcileClients(_ clients: [AuthorizedRemoteClient], busy: Bool) {
        let ids = Set(clients.map(\.id))
        for id in Array(clientRows.keys) where !ids.contains(id) {
            guard let entry = clientRows.removeValue(forKey: id) else { continue }
            clientStack.removeArrangedSubview(entry.row); entry.row.removeFromSuperview()
        }
        for (index, client) in clients.enumerated() {
            let entry: ClientRow
            if let existing = clientRows[client.id] { entry = existing }
            else {
                let id = client.id
                let control = ServerSettingsActionButton("Remote Control", id: "server-client-control-" + id, checkbox: true) {}
                control.handler = { [weak self, weak control] in
                    guard let self, let control, self.clientRows[id]?.control === control else { return }
                    self.onAction(.setClientRemoteControl(id, control.state == .on))
                }
                let revoke = ServerSettingsActionButton("Remove", id: "server-client-revoke-" + id) {}
                revoke.handler = { [weak self, weak revoke] in
                    guard let self, let revoke, self.clientRows[id]?.revoke === revoke else { return }
                    self.onAction(.revokeClient(id))
                }
                let label = ServerSettingsLayout.label(client.label)
                let row = NSStackView(views: [label, control, revoke]); row.spacing = 12
                entry = ClientRow(row: row, label: label, control: control, revoke: revoke)
                clientRows[id] = entry
            }
            if entry.label.currentEditor() == nil, entry.label.stringValue != client.label { entry.label.stringValue = client.label }
            entry.control.state = client.remoteControl ? .on : .off
            entry.control.isEnabled = !busy; entry.revoke.isEnabled = !busy
            let currentIndex = clientStack.arrangedSubviews.firstIndex(where: { $0 === entry.row })
            if currentIndex != index {
                if currentIndex != nil { clientStack.removeArrangedSubview(entry.row) }
                clientStack.insertArrangedSubview(entry.row, at: min(index, clientStack.arrangedSubviews.count))
            }
        }
        clientTitle.isHidden = clients.isEmpty; clientStack.isHidden = clients.isEmpty
    }
}

@MainActor final class IntegrationsSettingsNativeView: NSView {
    var onChange: (IntegrationsPreferences) -> Void = { _ in }
    private var preferences = IntegrationsPreferences()
    private var master: ServerSettingsActionButton!
    private var naming: ServerSettingsActionButton!
    private var cleanup: ServerSettingsActionButton!
    private var worktreeTitle: NSView!
    private var states: [AgentKind: NSTextField] = [:]
    private var rootStack: NSStackView!
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 590, height: 260) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        master = ServerSettingsActionButton("Integrate with available agents", id: "integrations-enabled", checkbox: true) { [weak self] in
            guard let self else { return }
            self.preferences.integrateWithAvailableAgents = self.master.state == .on
            self.onChange(self.preferences)
        }
        var views: [NSView] = [ServerSettingsLayout.title("Coding Agents"), master]
        for provider in [AgentKind.claude, .codex] {
            let name = provider == .claude ? "Claude Code" : "Codex"
            let field = ServerSettingsLayout.label("Not found"); states[provider] = field
            views.append(ServerSettingsLayout.row(name, field))
        }
        naming = ServerSettingsActionButton("Let agents name sessions", id: "integrations-agent-naming", checkbox: true) { [weak self] in
            guard let self, self.preferences.integrateWithAvailableAgents else { return }
            self.preferences.letAgentsNameSessions = self.naming.state == .on
            self.onChange(self.preferences)
        }
        cleanup = ServerSettingsActionButton("Automatically clean up completed-task worktrees", id: "integrations-worktree-cleanup", checkbox: true) { [weak self] in
            guard let self else { return }
            self.preferences.automaticallyCleanWorktrees = self.cleanup.state == .on
            self.onChange(self.preferences)
        }
        worktreeTitle = ServerSettingsLayout.title("Worktrees")
        views.append(worktreeTitle); views.append(cleanup)
        ServerSettingsLayout.install(views, in: self)
        rootStack = subviews.first as? NSStackView
    }
    required init?(coder: NSCoder) { return nil }

    func configure(preferences: IntegrationsPreferences, available: [AgentKind], installed: [AgentKind], busy: Bool) {
        self.preferences = preferences
        master.state = preferences.integrateWithAvailableAgents ? .on : .off; master.isEnabled = !busy
        naming.state = preferences.letAgentsNameSessions ? .on : .off; naming.isEnabled = !busy
        cleanup.state = preferences.automaticallyCleanWorktrees ? .on : .off; cleanup.isEnabled = !busy
        for provider in [AgentKind.claude, .codex] {
            let value = installed.contains(provider) ? "Integrated" : available.contains(provider) ? "Available" : "Not found"
            if let field = states[provider], field.currentEditor() == nil, field.stringValue != value { field.stringValue = value }
        }
        if preferences.integrateWithAvailableAgents {
            if naming.superview == nil { rootStack.insertArrangedSubview(naming, at: rootStack.arrangedSubviews.firstIndex(where: { $0 === worktreeTitle }) ?? rootStack.arrangedSubviews.count) }
        } else if naming.superview != nil {
            rootStack.removeArrangedSubview(naming); naming.removeFromSuperview()
        }
    }
}
