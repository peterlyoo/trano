import AppKit
import TerminalCore

struct SupervisorPanelServices: @unchecked Sendable {
    let readState: @Sendable () throws -> SupervisorState
    let start: @Sendable (SupervisorConfiguration) throws -> SupervisorState
    let stop: @Sendable (String, Int32) throws -> SupervisorState
    let makeRenderer: @MainActor (SupervisorBinding) throws -> NSView
    let synchronizeRenderer: @MainActor (NSView, SupervisorBinding) throws -> Void
    let performRendererAction: @MainActor (ActionID, NSView) -> Bool
    let cachedAccounts: @MainActor () -> [AccountProfile]
    let cachedKeyBindings: @MainActor () -> [String: [String]]
    var cachedKeySequenceHints: @MainActor () -> Bool = { true }
    var readReadiness: (@Sendable (SupervisorState) throws -> SupervisorState)?
}

protocol SupervisorPanelScheduling: Sendable {
    func schedule(_ work: @escaping @Sendable () -> Void)
    func deliver(_ work: @escaping @MainActor @Sendable () -> Void)
}

final class SupervisorPanelDispatchScheduler: SupervisorPanelScheduling, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.trano.supervisor-panel", qos: .userInitiated)
    func schedule(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }
    func deliver(_ work: @escaping @MainActor @Sendable () -> Void) { DispatchQueue.main.async(execute: work) }
}

@MainActor final class SupervisorPanelModel {
    let services: SupervisorPanelServices
    let scheduler: SupervisorPanelScheduling
    var configuration: SupervisorConfiguration
    private(set) var snapshot: SupervisorState?
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var operation: String?
    private var refreshPending = false
    private var readinessRefreshPending = false
    var onChange: (() -> Void)?
    var onReadinessChange: (() -> Void)?

    init(services: SupervisorPanelServices, configuration: SupervisorConfiguration,
         scheduler: SupervisorPanelScheduling = SupervisorPanelDispatchScheduler()) {
        self.services = services
        self.configuration = configuration
        self.scheduler = scheduler
    }

    var canStart: Bool {
        !isBusy && (snapshot == nil || snapshot?.phase == .notStarted || snapshot?.phase == .stopped)
    }

    var canStop: Bool { !isBusy && snapshot?.binding != nil && snapshot?.binding?.stoppedAt == nil }

    func refreshReadiness() {
        guard let snapshot, let read = services.readReadiness else { return }
        guard !isBusy else {
            if !refreshPending { readinessRefreshPending = true }
            return
        }
        run("Checking input", { try read(snapshot) }, readinessOnly: true)
    }

    func refresh() {
        guard !isBusy else { refreshPending = true; readinessRefreshPending = false; return }
        readinessRefreshPending = false
        run("Loading", services.readState)
    }

    func start() {
        guard canStart else { return }
        let configuration = configuration, start = services.start
        run("Starting") { try start(configuration) }
    }

    func stop() {
        guard canStop, let binding = snapshot?.binding else { return }
        let stop = services.stop
        run("Stopping") { try stop(binding.paneID, binding.backendPID) }
    }

    private func run(_ operation: String, _ work: @escaping @Sendable () throws -> SupervisorState, readinessOnly: Bool = false) {
        isBusy = true
        self.operation = operation
        errorMessage = nil
        if readinessOnly { onReadinessChange?() } else { onChange?() }
        let scheduler = scheduler
        scheduler.schedule { [weak self] in
            let result = Result { try work() }
            scheduler.deliver { [weak self] in
                guard let self else { return }
                self.isBusy = false
                self.operation = nil
                switch result {
                case .success(let state):
                    self.snapshot = state
                    if let binding = state.binding, binding.stoppedAt == nil { self.configuration = binding.configuration }
                case .failure(let error): self.errorMessage = error.localizedDescription
                }
                if readinessOnly { self.onReadinessChange?() } else { self.onChange?() }
                if self.refreshPending {
                    self.refreshPending = false
                    self.readinessRefreshPending = false
                    self.refresh()
                } else if self.readinessRefreshPending {
                    self.readinessRefreshPending = false
                    self.refreshReadiness()
                }
            }
        }
    }
}

@MainActor final class SupervisorWindowController: NSObject, NSWindowDelegate {
    let model: SupervisorPanelModel
    private let makeWindow: @MainActor (NSWindow?) -> NSPanel
    private let presentWindow: @MainActor (NSPanel) -> Void
    private let makeLoadAccessory: @MainActor (SupervisorBinding) -> NSView?
    private let targetActionServices: SupervisorTargetActionServices?
    private let inputWindowIsActive: @MainActor (NSWindow) -> Bool
    private var keySequenceController: TerminalKeySequenceController?
    private var keySequenceBindings: [String: [String]]?
    private(set) var window: NSPanel?
    private(set) var renderer: NSView?
    private(set) var isPresented = false
    private var rendererBinding: SupervisorBinding?
    private var rendererError: String?
    private var provider = NSPopUpButton(frame: .zero, pullsDown: false)
    private var account = NSPopUpButton(frame: .zero, pullsDown: false)
    private var startButton = NSButton(title: "Start", target: nil, action: nil)
    private var stopButton = NSButton(title: "Stop", target: nil, action: nil)
    private var status = NSTextField(labelWithString: "Not started")
    private var terminalHost = NSView()
    private let loadHost = NSView()
    private let targetHost = NSView()
    private var targetHeight: NSLayoutConstraint?
    private var targetActions: SupervisorTargetActionsView?
    private var loadHeight: NSLayoutConstraint?
    private var loadBinding: SupervisorBinding?
    private var emptyLabel = NSTextField(labelWithString: "Supervisor")
    private var accountIDs: [String?] = []

    init(model: SupervisorPanelModel,
         makeWindow: @escaping @MainActor (NSWindow?) -> NSPanel = { SupervisorWindowController.makePanel(relativeTo: $0) },
         presentWindow: @escaping @MainActor (NSPanel) -> Void = { $0.makeKeyAndOrderFront(nil) },
         makeLoadAccessory: @escaping @MainActor (SupervisorBinding) -> NSView? = { _ in nil },
         targetActionServices: SupervisorTargetActionServices? = nil,
         inputWindowIsActive: @escaping @MainActor (NSWindow) -> Bool = { NSApp.isActive && $0.isKeyWindow }) {
        self.model = model
        self.makeWindow = makeWindow
        self.presentWindow = presentWindow
        self.makeLoadAccessory = makeLoadAccessory
        self.targetActionServices = targetActionServices
        self.inputWindowIsActive = inputWindowIsActive
        super.init()
        model.onChange = { [weak self] in self?.render() }
        model.onReadinessChange = { [weak self] in self?.render(synchronizeTerminal: false) }
    }

    func toggle(relativeTo owner: NSWindow? = nil) {
        if isPresented { hide() } else { show(relativeTo: owner) }
    }

    func show(relativeTo owner: NSWindow? = nil) {
        let panel = window ?? buildWindow(relativeTo: owner)
        isPresented = true
        render()
        presentWindow(panel)
        if let renderer { panel.makeFirstResponder(renderer) }
        model.refresh()
    }

    func hide() {
        targetActions?.model.cancel()
        keySequenceController?.cancel()
        isPresented = false
        (renderer as? TerminalInteractionInvalidating)?.invalidateTerminalInteractions()
        window?.orderOut(nil)
    }

    func owns(_ window: NSWindow?) -> Bool { window != nil && window === self.window }

    var acceptsActions: Bool {
        isPresented && window?.attachedSheet == nil && NSApp.modalWindow == nil &&
        (window?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true
    }

    func supports(_ action: ActionID) -> Bool {
        switch action {
        case .closePane, .closeTab: return true
        case .copy, .paste, .selectAll, .clear, .find, .findNext, .findPrevious, .increaseFont, .decreaseFont, .resetFont:
            return renderer != nil
        default: return false
        }
    }

    @discardableResult func perform(_ action: ActionID) -> Bool {
        guard acceptsActions, supports(action) else { return false }
        if action == .closePane || action == .closeTab { hide(); return true }
        guard let renderer else { return false }
        return model.services.performRendererAction(action, renderer)
    }

    func handle(_ event: NSEvent) -> Bool {
        guard owns(event.window), let owner = window else { keySequenceController?.cancel(); return false }
        let overrides = model.services.cachedKeyBindings()
        if keySequenceController == nil {
            let overlay = TerminalKeySequenceOverlay(owner: owner)
            keySequenceController = try? TerminalKeySequenceController(owner: owner, overrides: overrides,
                eligible: { [weak self] in self?.acceptsSequenceInput == true },
                composing: { [weak self] in (self?.window?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true },
                target: { [weak self] in self?.rendererBinding.map { $0.paneID + ":" + String($0.backendPID) } },
                supportsAction: { [weak self] in self?.supports($0) == true }, onHints: { [weak self] hints in
                    guard let self else { overlay.dismiss(); return }
                    let host = self.renderer ?? self.terminalHost
                    overlay.present(hints, in: host, bounds: host.bounds)
                }, dispatch: { [weak self] in _ = self?.perform($0) })
            keySequenceBindings = overrides
        } else if keySequenceBindings != overrides {
            do { try keySequenceController?.reload(overrides: overrides) }
            catch { try? keySequenceController?.reload(overrides: [:]) }
            keySequenceBindings = overrides
        }
        if keySequenceController?.handle(event, showHints: model.services.cachedKeySequenceHints()) == true { return true }
        guard event.type == .keyDown, acceptsSequenceInput,
              let binding = NativeKeyBinding.binding(for: event),
              let map = (try? TerminalKeySequenceMap(overrides: overrides)) ?? (try? TerminalKeySequenceMap()),
              let action = map.singles.action(for: binding), supports(action) else { return false }
        if !event.isARepeat { _ = perform(action) }
        return true
    }

    private var acceptsSequenceInput: Bool {
        guard acceptsActions, let window, inputWindowIsActive(window) else { return false }
        if let renderer { return window.firstResponder === renderer && renderer.window === window }
        return !(window.firstResponder is NSTextInputClient)
    }

    func targetNavigationIsCurrent(authority: SupervisorContinuationAuthority, target: SupervisorContinuationIdentity) -> Bool {
        isPresented && model.snapshot?.continuationAuthority == authority &&
            targetActions?.model.navigationIsCurrent(authority: authority, target: target) == true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard owns(sender) else { return true }
        hide()
        return false
    }

    static func placementFrame(_ windowFrame: NSRect, ownerFrame: NSRect?, visibleFrame: NSRect) -> NSRect {
        guard !visibleFrame.isEmpty else { return windowFrame }
        let size = NSSize(width: min(windowFrame.width, visibleFrame.width),
                          height: min(windowFrame.height, visibleFrame.height))
        let origin = NSPoint(x: ownerFrame.map { $0.maxX + 12 } ?? visibleFrame.maxX - size.width - 16,
                             y: (ownerFrame?.maxY ?? visibleFrame.maxY - 16) - size.height)
        return NSRect(x: min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - size.width),
                      y: min(max(origin.y, visibleFrame.minY), visibleFrame.maxY - size.height),
                      width: size.width, height: size.height)
    }

    private static func makePanel(relativeTo owner: NSWindow?) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        if let screen = owner?.screen ?? NSScreen.main {
            panel.setFrame(placementFrame(panel.frame, ownerFrame: owner?.frame, visibleFrame: screen.visibleFrame), display: false)
        }
        return panel
    }

    private func buildWindow(relativeTo owner: NSWindow?) -> NSPanel {
        let panel = makeWindow(owner)
        window = panel
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.title = "Supervisor"
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.isOpaque = true
        panel.backgroundColor = NSColor(calibratedWhite: 0.055, alpha: 1)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentMinSize = NSSize(width: 360, height: 420)

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = panel.backgroundColor.cgColor
        panel.contentView = content
        provider.identifier = NSUserInterfaceItemIdentifier("supervisor-provider")
        provider.addItems(withTitles: ["Claude", "Codex"])
        provider.setAccessibilityLabel("Supervisor agent")
        provider.target = self
        provider.action = #selector(providerChanged)
        account.identifier = NSUserInterfaceItemIdentifier("supervisor-account")
        account.setAccessibilityLabel("Supervisor account")
        account.target = self
        account.action = #selector(accountChanged)
        startButton.identifier = NSUserInterfaceItemIdentifier("supervisor-start")
        startButton.target = self
        startButton.action = #selector(startClicked)
        stopButton.identifier = NSUserInterfaceItemIdentifier("supervisor-stop")
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        for button in [startButton, stopButton] { button.bezelStyle = .rounded; button.controlSize = .small }
        status.identifier = NSUserInterfaceItemIdentifier("supervisor-status")
        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        emptyLabel.textColor = NSColor(calibratedWhite: 0.38, alpha: 1)
        emptyLabel.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        emptyLabel.alignment = .center
        terminalHost.identifier = NSUserInterfaceItemIdentifier("supervisor-terminal")
        loadHost.identifier = NSUserInterfaceItemIdentifier("supervisor-load")
        targetHost.identifier = NSUserInterfaceItemIdentifier("supervisor-target-actions")
        for view in [provider, account, startButton, stopButton, status, loadHost, targetHost, terminalHost] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.addSubview(emptyLabel)
        loadHeight = loadHost.heightAnchor.constraint(equalToConstant: 0)
        loadHeight?.isActive = true
        targetHeight = targetHost.heightAnchor.constraint(equalToConstant: 0)
        targetHeight?.isActive = true
        if let targetActionServices {
            let actions = SupervisorTargetActionsView(model: SupervisorTargetActionsModel(services: targetActionServices, scheduler: model.scheduler))
            actions.translatesAutoresizingMaskIntoConstraints = false
            targetHost.addSubview(actions)
            NSLayoutConstraint.activate([
                actions.leadingAnchor.constraint(equalTo: targetHost.leadingAnchor), actions.trailingAnchor.constraint(equalTo: targetHost.trailingAnchor),
                actions.topAnchor.constraint(equalTo: targetHost.topAnchor), actions.bottomAnchor.constraint(equalTo: targetHost.bottomAnchor)
            ])
            targetActions = actions
        }
        NSLayoutConstraint.activate([
            provider.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            provider.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            provider.widthAnchor.constraint(equalToConstant: 105),
            provider.heightAnchor.constraint(equalToConstant: 26),
            account.leadingAnchor.constraint(equalTo: provider.trailingAnchor, constant: 6),
            account.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            account.centerYAnchor.constraint(equalTo: provider.centerYAnchor),
            account.heightAnchor.constraint(equalToConstant: 26),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            status.topAnchor.constraint(equalTo: provider.bottomAnchor, constant: 8),
            status.trailingAnchor.constraint(equalTo: startButton.leadingAnchor, constant: -8),
            status.heightAnchor.constraint(equalToConstant: 24),
            startButton.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            startButton.widthAnchor.constraint(equalToConstant: 54),
            startButton.heightAnchor.constraint(equalToConstant: 24),
            stopButton.leadingAnchor.constraint(equalTo: startButton.trailingAnchor, constant: 6),
            stopButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            stopButton.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            stopButton.widthAnchor.constraint(equalToConstant: 54),
            stopButton.heightAnchor.constraint(equalToConstant: 24),
            loadHost.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8),
            loadHost.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            loadHost.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            targetHost.topAnchor.constraint(equalTo: loadHost.bottomAnchor),
            targetHost.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            targetHost.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            terminalHost.topAnchor.constraint(equalTo: targetHost.bottomAnchor),
            terminalHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            terminalHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            terminalHost.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: terminalHost.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: terminalHost.centerYAnchor)
        ])
        return panel
    }

    private func render(synchronizeTerminal: Bool = true) {
        guard window != nil else { return }
        targetActions?.model.update(authority: model.snapshot?.continuationAuthority, targets: model.snapshot?.targets ?? [], panelBusy: model.isBusy)
        targetHeight?.constant = targetActions?.model.targets.isEmpty == false ? 96 : 0
        targetHost.isHidden = targetActions?.model.targets.isEmpty != false
        provider.selectItem(at: model.configuration.provider == .codex ? 1 : 0)
        refreshAccounts()
        provider.isEnabled = model.canStart
        account.isEnabled = model.canStart
        startButton.isEnabled = model.canStart
        stopButton.isEnabled = model.canStop
        if let binding = model.snapshot?.binding {
            if loadBinding != binding {
                loadHost.subviews.forEach { $0.removeFromSuperview() }
                if let accessory = makeLoadAccessory(binding) {
                    accessory.translatesAutoresizingMaskIntoConstraints = false
                    loadHost.addSubview(accessory)
                    NSLayoutConstraint.activate([
                        accessory.leadingAnchor.constraint(equalTo: loadHost.leadingAnchor),
                        accessory.trailingAnchor.constraint(equalTo: loadHost.trailingAnchor),
                        accessory.topAnchor.constraint(equalTo: loadHost.topAnchor),
                        accessory.bottomAnchor.constraint(equalTo: loadHost.bottomAnchor)
                    ])
                    loadHeight?.constant = 24
                } else { loadHeight?.constant = 0 }
                loadBinding = binding
            }
        } else {
            loadHost.subviews.forEach { $0.removeFromSuperview() }
            loadHeight?.constant = 0
            loadBinding = nil
        }
        if synchronizeTerminal {
            let binding = model.snapshot?.binding
            if let binding, let previous = rendererBinding,
               previous.paneID != binding.paneID || previous.backendPID != binding.backendPID {
                discardRenderer()
            }
            if isPresented, let binding, binding.stoppedAt == nil {
                do {
                    if rendererBinding?.paneID != binding.paneID || rendererBinding?.backendPID != binding.backendPID {
                        let view = try model.services.makeRenderer(binding)
                        renderer = view
                        rendererBinding = binding
                        view.translatesAutoresizingMaskIntoConstraints = false
                        terminalHost.addSubview(view)
                        NSLayoutConstraint.activate([
                            view.leadingAnchor.constraint(equalTo: terminalHost.leadingAnchor),
                            view.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor),
                            view.topAnchor.constraint(equalTo: terminalHost.topAnchor),
                            view.bottomAnchor.constraint(equalTo: terminalHost.bottomAnchor)
                        ])
                        window?.makeFirstResponder(view)
                    }
                    if let renderer { try model.services.synchronizeRenderer(renderer, binding) }
                    rendererError = nil
                } catch {
                    discardRenderer()
                    rendererError = error.localizedDescription
                }
            } else if binding?.stoppedAt != nil {
                rendererError = nil
            }
        }
        emptyLabel.isHidden = renderer != nil
        if let message = model.errorMessage ?? rendererError {
            status.stringValue = message
            status.textColor = .systemOrange
        } else {
            let count = model.snapshot?.targets.count ?? 0
            let phase: String
            switch model.snapshot?.phase ?? .notStarted {
            case .notStarted: phase = "Not started"
            case .starting: phase = "Starting"
            case .running: phase = "Running"
            case .needsAttention: phase = "Needs attention"
            case .stopped: phase = "Stopped"
            }
            status.stringValue = model.operation.map { $0 + "…" } ?? (count > 0 ? "\(phase) · \(count) sessions" : phase)
            status.textColor = .secondaryLabelColor
        }
        status.toolTip = model.errorMessage ?? rendererError ?? model.snapshot?.message ?? status.stringValue
    }

    private func discardRenderer() {
        targetActions?.model.cancel()
        keySequenceController?.cancel()
        if let renderer, let responder = window?.firstResponder as? NSView,
           responder === renderer || responder.isDescendant(of: renderer) {
            window?.makeFirstResponder(nil)
        }
        renderer?.removeFromSuperview()
        renderer = nil
        rendererBinding = nil
    }

    private func refreshAccounts() {
        let values = model.services.cachedAccounts().filter { $0.provider == model.configuration.provider && $0.enabled }
        let selected = model.configuration.accountID
        account.removeAllItems()
        account.addItem(withTitle: "Default account")
        accountIDs = [nil]
        for value in values {
            account.addItem(withTitle: value.label)
            accountIDs.append(value.id)
        }
        if let selected, !accountIDs.contains(where: { $0 == selected }) {
            account.addItem(withTitle: "Unavailable account")
            accountIDs.append(selected)
        }
        account.selectItem(at: accountIDs.firstIndex(where: { $0 == selected }) ?? 0)
    }

    @objc private func providerChanged() {
        guard model.canStart else { return }
        model.configuration = SupervisorConfiguration(provider: provider.indexOfSelectedItem == 1 ? .codex : .claude,
            cwd: model.configuration.cwd)
        render()
    }

    @objc private func accountChanged() {
        guard model.canStart, accountIDs.indices.contains(account.indexOfSelectedItem) else { return }
        model.configuration = SupervisorConfiguration(provider: model.configuration.provider,
            accountID: accountIDs[account.indexOfSelectedItem], cwd: model.configuration.cwd)
        render()
    }

    @objc private func startClicked() { model.start() }
    @objc private func stopClicked() { model.stop() }
}
