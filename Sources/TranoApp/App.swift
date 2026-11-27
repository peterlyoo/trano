import AppKit
import Combine
import SwiftUI
import TerminalCore

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    var window: NSWindow?
    var store: AppStore?
    var monitor: Any?
    private var presenceTimer: Timer?
    private var publishedPresence: InterfacePresence?
    var service: APIService?
    private var serverStatus: ServerStatusController?
    private var serverHost: BackgroundServerHost?
    var notifications: NotificationController?
    var unisession: UnisessionController?
    var supervisorWindow: SupervisorWindowController?
    var supervisorAdapter: SupervisorNativeRuntimeAdapter?
    private weak var supervisorPresentationOwner: NSWindow?
    private var supervisorTargetNavigationLease: SupervisorNavigationLease?
    var windows: [NSWindow: AppStore] = [:]
    var floatingWindows: [NSWindow: AppStore] = [:]
    private weak var actionWindow: NSWindow?
    private let interfacePolicy = InterfaceApplicationPolicy()
    private var interfaceRuntime: TerminalRuntime?
    private var interfaceObservers: [ObjectIdentifier: AnyCancellable] = [:]
    private var windowlessInterfaceObserver: AnyCancellable?
    private var settingsObservers: [ObjectIdentifier: AnyCancellable] = [:]
    private var keyMaps: [ObjectIdentifier: TerminalKeySequenceMap] = [:]
    private var keySequenceControllers: [ObjectIdentifier: TerminalKeySequenceController] = [:]
    private var readinessTimer: Timer?
    var commandHintWindowIsActive: (NSWindow) -> Bool = { NSApp.isActive && $0.isKeyWindow }
    var isBackgroundService = false

    private func startBackgroundServer() {
        let root = TerminalRuntime.defaultRoot
        let cache = ServerStatusCache(ServerStatusState(pid: getpid(), buildID: BuildIdentity.process.buildID).snapshot)
        var lease: ServerHelperLease?
        do { lease = try ServerHelperLease(root: root) }
        catch ServerHelperLeaseError.alreadyRunning {
            // Notification Center relaunches the helper to deliver a click; let the relay open the session first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.terminate(nil) }
            return
        }
        catch { /* The status owner retains startup errors and permits a retry. */ }
        let applicationURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let host = BackgroundServerHost(root: root, applicationURL: applicationURL, cache: cache, lease: lease) { [weak self] in
            self?.shutdownBackgroundServer()
        }
        serverHost = host
        let controller = ServerStatusController(cache: cache, start: host.start, restart: host.restart,
            probe: { try ServerHealthClient.probe(path: root.appendingPathComponent("api.sock").path) },
            open: { NSWorkspace.shared.openApplication(at: applicationURL, configuration: NSWorkspace.OpenConfiguration()) },
            quit: { [weak self] in self?.shutdownBackgroundServer() })
        serverStatus = controller
        controller.start()
    }

    private func shutdownBackgroundServer() {
        let host = serverHost
        serverStatus?.shutdown({ host?.stop() }, completion: { NSApp.terminate(nil) })
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        if LaunchRole.isService { NotificationResponseRelay.shared.install() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if LaunchRole.isService {
            isBackgroundService = true
            startBackgroundServer()
            return
        }
        do {
            let helper = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("trano").path
            let runtime = try TerminalRuntime(helperExecutable: helper)
            let interfacePreferences = try runtime.interfacePreferences()
            interfaceRuntime = runtime
            let benchmark = argument("--benchmark-readiness") != nil
            if !CommandLine.arguments.contains("--snapshot") && !benchmark { BackgroundService.start(runtime: runtime) }
            if !CommandLine.arguments.contains("--snapshot") && !benchmark { UpdateController.shared.start() }
            if !CommandLine.arguments.contains("--snapshot") && !benchmark { AppRestartController.shared.start() }
            let explicitWindow = CommandLine.arguments.contains("--snapshot") || benchmark || argument("--open-session") != nil
            let model = AppStore(runtime: runtime, bootstrapIfEmpty: !CommandLine.arguments.contains("--snapshot") && !benchmark && (interfacePreferences.showWindowOnLaunch || explicitWindow))
            model.interfacePreferences = interfacePreferences
            model.showSessionsSidebar = interfacePreferences.toolbarLayout != .above
            store = model
            UpdateController.shared.automaticInstallInputIsSafe = { [weak self] in
                guard let self else { return false }
                return Array(self.windows.values).allSatisfy { $0.safeInterfaceNavigation }
                    && Array(self.floatingWindows.values).allSatisfy { $0.safeInterfaceNavigation }
            }
            interfacePolicy.openWindow = { [weak self] in self?.openInterfaceWindow() }
            interfacePolicy.openSettings = { [weak self] in self?.openInterfaceWindow(); self?.store?.showSettings = true }
            if !CommandLine.arguments.contains("--snapshot") && !benchmark {
                windowlessInterfaceObserver = model.$interfacePreferences.removeDuplicates().sink { [weak self] _ in self?.refreshInterfacePolicy() }
            }
            configureMenu()
            startPresencePublisher(root: runtime.root)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown, .flagsChanged, .mouseMoved, .swipe, .magnify, .scrollWheel]) { [weak self] event in self?.handle(event) == true ? nil : event }
            if !interfacePreferences.showWindowOnLaunch && !explicitWindow {
                refreshInterfacePolicy()
                return
            }
            let snapshot = CommandLine.arguments.contains("--snapshot")
            let snapshotSurface = argument("--snapshot-view") ?? "workspace"
            let content: AnyView = snapshot && ["appearance", "shortcuts", "general", "updates"].contains(snapshotSurface)
                ? AnyView(SettingsView(store: model, initialSection: snapshotSurface)) : AnyView(WorkspaceView(store: model))
            let view = NSHostingView(rootView: content)
            let dimensions = argument("--snapshot-size")?.split(separator: "x").compactMap { Double($0) }.filter(\.isFinite) ?? []
            let width = snapshot && dimensions.count == 2 ? min(4096, max(900, dimensions[0])) : 1280
            let height = snapshot && dimensions.count == 2 ? min(2160, max(620, dimensions[1])) : 800
            let window = WorkspaceWindow.make(contentRect: NSRect(x: 0, y: 0, width: width, height: height), contentView: view)
            window.center()
            self.window = window
            window.delegate = self
            windows[window] = model
            configurePaneDetachment(model)
            configureSupervisor(model, window: window)
            model.isActiveWindow = { [weak self, weak window] in self?.window === window }
            model.onNewWindow = { [weak self] in self?.newWindow() }
            model.onCloseWindow = { [weak window] in window?.close() }
            configureMenu()
            observeSettings(model, window: window)
            configureFloatingPanes(model)
            refreshInterfacePolicy()
            if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > index + 1 {
                let destination = CommandLine.arguments[index + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    view.layoutSubtreeIfNeeded()
                    for terminal in model.terminalViews.values {
                        terminal.viewDidUnhide()
                        terminal.needsDisplay = true
                        terminal.display()
                    }
                    let scale = self.argument("--snapshot-scale") == "1" ? 1.0 : 2.0
                    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale), pixelsHigh: Int(view.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(2) }
                    bitmap.size = view.bounds.size
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(2) }
                    do { try data.write(to: URL(fileURLWithPath: destination)); exit(0) } catch { exit(2) }
                }
            } else if let destination = argument("--benchmark-readiness") {
                beginReadinessProbe(view: view, model: model, destination: destination, marker: argument("--benchmark-token") ?? "")
            } else {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                if let index = CommandLine.arguments.firstIndex(of: "--open-session"), CommandLine.arguments.count > index + 1 {
                    model.attach(CommandLine.arguments[index + 1])
                }
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            NSApp.terminate(nil)
        }
    }

    private func argument(_ flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }

    private func beginReadinessProbe(view: NSView, model: AppStore, destination: String, marker: String) {
        view.layoutSubtreeIfNeeded()
        let start = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self, weak view, weak model] timer in
            guard let self, let view, let model else { timer.invalidate(); return }
            let terminals = Array(model.terminalViews.values)
            let ready = !model.loading && !terminals.isEmpty && terminals.allSatisfy { terminal in
                terminal.started && terminal.process.running && terminal.bounds.width > 0 && terminal.bounds.height > 0 &&
                    (marker.isEmpty || terminal.terminalStateSnapshot().visibleRows.contains(where: { $0.text.contains(marker) }))
            }
            guard ready || ProcessInfo.processInfo.systemUptime - start > 30 else { return }
            timer.invalidate(); self.readinessTimer = nil
            var result: [String: Any] = ["ready": ready, "pid": ProcessInfo.processInfo.processIdentifier, "terminalViews": terminals.count, "probeSeconds": ProcessInfo.processInfo.systemUptime - start]
            if ready {
                let drawStart = ProcessInfo.processInfo.systemUptime
                view.layoutSubtreeIfNeeded()
                for terminal in terminals { terminal.viewDidUnhide(); terminal.needsDisplay = true; terminal.display() }
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) { view.cacheDisplay(in: view.bounds, to: bitmap) }
                result["drawSeconds"] = ProcessInfo.processInfo.systemUptime - drawStart
            } else { result["error"] = "Timed out waiting for attached terminal output and layout." }
            do { try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: URL(fileURLWithPath: destination), options: .atomic) }
            catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); NSApp.terminate(nil) }
        }
        readinessTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func openInterfaceWindow() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        else { newWindow() }
    }
    private func refreshInterfacePolicy() {
        guard !LaunchRole.isService, !CommandLine.arguments.contains("--snapshot"), argument("--benchmark-readiness") == nil else { return }
        let prefs = store?.interfacePreferences ?? (try? interfaceRuntime?.interfacePreferences()) ?? InterfacePreferences()
        interfacePolicy.apply(prefs, windowCount: windows.count + floatingWindows.count, systemIsDark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }
    func newWindow(createWorkspace: Bool = true) {
        guard let runtime = store?.runtime ?? interfaceRuntime else { return }
        let inheritedInterface = store?.interfacePreferences ?? (try? runtime.interfacePreferences()) ?? InterfacePreferences()
        let model = AppStore(runtime: runtime)
        model.interfacePreferences = inheritedInterface
        model.showSessionsSidebar = inheritedInterface.toolbarLayout != .above
        let window = WorkspaceWindow.make(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), contentView: NSHostingView(rootView: WorkspaceView(store: model)))
        window.center()
        window.delegate = self
        windows[window] = model
        self.window = window
        self.store = model
        refreshInterfacePolicy()
        configurePaneDetachment(model)
        configureSupervisor(model, window: window)
        observeSettings(model, window: window)
        configureFloatingPanes(model)
        model.isActiveWindow = { [weak self, weak window] in self?.window === window }
        model.onNewWindow = { [weak self] in self?.newWindow() }
        model.onCloseWindow = { [weak window] in window?.close() }
        window.makeKeyAndOrderFront(nil)
        if createWorkspace {
            model.perform { runtime in
                let title = try runtime.state().layout.randomWorkspaceTitle()
                try runtime.performAction(.newSession, title: title)
            }
        }
    }

    func configureSupervisor(_ model: AppStore, window: NSWindow) {
        model.onToggleSupervisor = { [weak self, weak model, weak window] in
            guard let self, let model, let window else { return }
            self.unisessionController(runtime: model.runtime).toggle(in: window, store: model)
        }
        model.onRevealSupervisor = { [weak self, weak model, weak window] in
            guard let self, let model, let window else { return }
            self.unisessionController(runtime: model.runtime).reveal(in: window, store: model)
        }
        model.onUnisessionAnchor = { [weak self, weak model] anchor in
            guard let self, let model else { return }
            model.unisessionAnchor = anchor
            if let window = anchor.window, window.isKeyWindow { self.unisession?.follow(in: window, store: model) }
            self.unisession?.anchorChanged(anchor, store: model)
        }
    }

    private func unisessionController(runtime: TerminalRuntime) -> UnisessionController {
        if let unisession { return unisession }
        let controller = UnisessionController(runtime: runtime)
        controller.onVisibilityChange = { [weak self] visible in
            for model in self?.windows.values ?? [:].values where model.unisessionPresented != visible { model.unisessionPresented = visible }
        }
        controller.onHideFocus = { [weak self] window in
            guard let model = self?.windows[window], window.isKeyWindow, window.attachedSheet == nil,
                  let id = model.focusedID, let view = model.terminalViews[id], !view.hasMarkedText(),
                  window.firstResponder == nil || window.firstResponder === window else { return }
            window.makeFirstResponder(view)
        }
        unisession = controller
        return controller
    }

    private func presentSupervisor(runtime: TerminalRuntime, cwd: String, owner: NSWindow?, toggle: Bool) {
        supervisorTargetNavigationLease?.invalidate()
        if let owner, let model = windows[owner] ?? floatingWindows[owner] {
            supervisorPresentationOwner = model.floatingPanes.presentationOwner(for: owner)
        } else { supervisorPresentationOwner = nil }
        if supervisorWindow == nil {
            let adapter = SupervisorNativeRuntimeAdapter(runtime: runtime)
            supervisorAdapter = adapter
            supervisorWindow = adapter.makeController(initialCWD: cwd, makeLoadAccessory: { binding in
                NSHostingView(rootView: CachedSessionLoadStrip(cache: SessionLoadClientCache.shared(root: runtime.root),
                    paneID: binding.paneID, showHook: binding.configuration.provider == .claude))
            }, captureTargetNavigation: { [weak self] authority, target in
                self?.captureSupervisorTargetNavigation(authority: authority, target: target, runtime: runtime)
            })
        }
        if toggle { supervisorWindow?.toggle(relativeTo: owner) }
        else { supervisorWindow?.show(relativeTo: owner) }
    }

    private func supervisorFloatingTargets(_ paneID: String, root: URL) -> [(window: NSWindow, model: AppStore)] {
        floatingWindows.compactMap { panel, model in
            guard WorkspaceOwners.canonicalRoot(for: model) == root.standardizedFileURL,
                  model.floatingPanes.paneID(in: panel) == paneID else { return nil }
            return (panel, model)
        }
    }

    private func captureSupervisorTargetNavigation(authority: SupervisorContinuationAuthority,
                                                   target: SupervisorContinuationIdentity,
                                                   runtime: TerminalRuntime) -> SupervisorTargetActionOwner? {
        guard let owner = supervisorPresentationOwner, let model = windows[owner], model.externalPanePolicy == nil,
              WorkspaceOwners.canonicalRoot(for: model) == runtime.root.standardizedFileURL,
              let controller = supervisorWindow, let panel = controller.window,
              controller.targetNavigationIsCurrent(authority: authority, target: target),
              model.safeInterfaceNavigation else { return nil }
        let sourceSelection = SupervisorNavigationSelection(workspaceID: model.preferredWorkspaceID,
            tabID: model.state.layout.selectedTabID, paneID: model.focusedID)
        let input = SupervisorNavigationInput(owner)
        let sourceView = model.focusedID.flatMap { model.terminalViews[$0] }
        let sourceViewWindow = sourceView?.window
        if model.focusedID != nil {
            guard let sourceView, sourceView.store === model, let sourceViewWindow,
                  model.floatingPanes.presentationOwner(for: sourceViewWindow) === owner else { return nil }
        }
        let sourceViewInput = sourceViewWindow.map(SupervisorNavigationInput.init)
        let routes = supervisorFloatingTargets(target.paneID, root: runtime.root)
        guard routes.count <= 1 else { return nil }
        let route = routes.first
        let floating = route?.model
        let floatingWindow = route?.window
        let floatingView = floating?.terminalViews[target.paneID]
        if let floating {
            guard let floatingWindow, floatingWindows[floatingWindow] === floating,
                  floatingView?.store === floating, floating.safeInterfaceNavigation else { return nil }
        }
        let floatingInput = floatingWindow.map(SupervisorNavigationInput.init)
        let floatingSelection = floating.map { SupervisorNavigationSelection(workspaceID: $0.preferredWorkspaceID,
            tabID: $0.state.layout.selectedTabID, paneID: $0.focusedID) }
        let lease = SupervisorNavigationLease()
        supervisorTargetNavigationLease?.invalidate()
        supervisorTargetNavigationLease = lease
        let isCurrent: @MainActor () -> Bool = { [weak self, weak owner, weak model, weak controller, weak panel,
                                                weak floating, weak floatingWindow, weak floatingView, weak sourceView, weak sourceViewWindow, weak lease] in
            guard let self, let owner, let model, let controller, let panel, lease?.isValid == true else { return false }
            let currentRoutes = self.supervisorFloatingTargets(target.paneID, root: runtime.root)
            guard self.supervisorPresentationOwner === owner, self.windows[owner] === model,
                  self.supervisorWindow === controller, controller.window === panel, controller.isPresented,
                  panel.isKeyWindow, NSApp.isActive, controller.acceptsActions,
                  controller.targetNavigationIsCurrent(authority: authority, target: target),
                  input.isCurrent, model.safeInterfaceNavigation,
                  SupervisorNavigationSelection(workspaceID: model.preferredWorkspaceID,
                    tabID: model.state.layout.selectedTabID, paneID: model.focusedID) == sourceSelection,
                  currentRoutes.count <= 1,
                  currentRoutes.first?.model === floating,
                  currentRoutes.first?.window === floatingWindow else { return false }
            if let sourcePane = sourceSelection.paneID {
                guard let sourceView, let sourceViewWindow, model.terminalViews[sourcePane] === sourceView,
                      sourceView.store === model, sourceView.window === sourceViewWindow, sourceViewInput?.isCurrent == true,
                      model.floatingPanes.presentationOwner(for: sourceViewWindow) === owner else { return false }
            }
            if let floating {
                guard let floatingWindow, let floatingView, self.floatingWindows[floatingWindow] === floating,
                      floating.terminalViews[target.paneID] === floatingView, floatingView.store === floating,
                      floatingView.window === floatingWindow, floatingInput?.isCurrent == true,
                      floating.safeInterfaceNavigation,
                      SupervisorNavigationSelection(workspaceID: floating.preferredWorkspaceID,
                        tabID: floating.state.layout.selectedTabID, paneID: floating.focusedID) == floatingSelection else { return false }
            }
            return true
        }
        guard isCurrent() else { lease.invalidate(); return nil }
        lease.watch([owner, panel] + (sourceViewWindow.map { [$0] } ?? []) + (floatingWindow.map { [$0] } ?? []), isCurrent: isCurrent)
        lease.retain(model.$state.dropFirst().sink { [weak lease] snapshot in
            if SupervisorNavigationSelection(snapshot.layout) != sourceSelection { lease?.invalidate() }
        })
        if let floating, let floatingSelection {
            lease.retain(floating.$state.dropFirst().sink { [weak lease] snapshot in
                if SupervisorNavigationSelection(snapshot.layout) != floatingSelection { lease?.invalidate() }
            })
        }
        let queue = model.queue
        return SupervisorTargetActionOwner(isCurrent: isCurrent, goToSession: { [weak self, weak model, weak owner,
                                                                               weak floating, weak floatingWindow] selected in
            guard selected == target, isCurrent() else { throw TerminalError.invalid("The selected session window changed.") }
            let request = SupervisorNavigationRequest(authority: authority, target: target)
            queue.async {
                let allowed = { DispatchQueue.main.sync { MainActor.assumeIsolated { isCurrent() } } }
                let result = Result { () -> (RuntimeState, [TerminalSession]) in
                    guard allowed() else { throw TerminalError.invalid("Session navigation was cancelled.") }
                    try runtime.supervisorContinuationCoordinator().validateTarget(authority: request.authority, target: request.target)
                    guard allowed() else { throw TerminalError.invalid("The session window changed during validation.") }
                    return try runtime.transaction {
                        try runtime.supervisorContinuationCoordinator().validateTarget(authority: request.authority, target: request.target)
                        guard lease.isValid else { throw TerminalError.invalid("Session input changed before navigation.") }
                        let sessions = try runtime.list()
                        try runtime.update { state in
                            guard lease.isValid else { throw TerminalError.invalid("Session navigation was cancelled.") }
                            state.layout = try SupervisorSessionNavigation.open(request.target, workspaceID: sourceSelection.workspaceID,
                                state: state, sessions: sessions).layout
                        }
                        return (try runtime.state(), sessions)
                    }
                }
                DispatchQueue.main.async {
                    defer {
                        lease.invalidate()
                        if self?.supervisorTargetNavigationLease === lease { self?.supervisorTargetNavigationLease = nil }
                    }
                    guard let model, let owner, isCurrent() else { return }
                    switch result {
                    case .failure(let error): model.message = error.localizedDescription
                    case .success(let (state, sessions)):
                        let destination = floating ?? model
                        destination.commandKeyHints.cancel()
                        destination.showActivity = false
                        destination.zoomed = false
                        destination.floatingPanes.suppressOwnerReturnFocus()
                        destination.applyCapturedNavigation(state, sessions: sessions)
                        if let floating, let floatingWindow {
                            guard floatingWindow.isVisible, floatingWindow.attachedSheet == nil,
                                  (floatingWindow.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return }
                            floating.floatingPanes.focus(request.target.paneID)
                        } else {
                            owner.makeKeyAndOrderFront(nil)
                            owner.contentView?.layoutSubtreeIfNeeded()
                            if destination.focusedID == request.target.paneID,
                               let view = destination.terminalViews[request.target.paneID], view.store === destination, view.window === owner {
                                owner.makeFirstResponder(view)
                            }
                        }
                    }
                }
            }
        })
    }

    func configurePaneDetachment(_ model: AppStore) {
        let runtime = model.runtime
        model.onPaneDetachedWindow = { [weak self] workspaceID, point in
            _ = self?.makeDetachedPaneWindow(runtime: runtime, workspaceID: workspaceID, at: point)
        }
    }

    @discardableResult func makeDetachedPaneWindow(runtime: TerminalRuntime, workspaceID: String, at point: NSPoint) -> NSWindow {
        let model = AppStore(runtime: runtime, initialWorkspaceID: workspaceID, recoverOnStartup: false)
        model.interfacePreferences = store?.interfacePreferences ?? (try? runtime.interfacePreferences()) ?? InterfacePreferences()
        model.showSessionsSidebar = model.interfacePreferences.toolbarLayout != .above
        let window = WorkspaceWindow.make(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), contentView: NSHostingView(rootView: WorkspaceView(store: model)))
        window.setFrameTopLeftPoint(NSPoint(x: point.x - 80, y: point.y + 14))
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            window.setFrame(window.constrainFrameRect(window.frame, to: screen), display: false)
        }
        window.delegate = self
        windows[window] = model
        observeSettings(model, window: window)
        configureFloatingPanes(model)
        configurePaneDetachment(model)
        configureSupervisor(model, window: window)
        model.isActiveWindow = { [weak self, weak window] in self?.window === window }
        model.onNewWindow = { [weak self] in self?.newWindow() }
        model.onCloseWindow = { [weak window] in window?.close() }
        window.makeKeyAndOrderFront(nil)
        return window
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let panel = notification.object as? NSWindow, let model = floatingWindows[panel] {
            actionWindow = panel
            store = model
            window = windows.first { $0.value === model }?.key
            if let id = model.floatingPanes.paneID(in: panel) { model.focus(id) }
            refreshMenuBindings(model.state.settings.keyBindings)
            return
        }
        guard let window = notification.object as? NSWindow, let model = windows[window] else { return }
        actionWindow = window
        self.window = window; store = model
        refreshMenuBindings(model.state.settings.keyBindings)
        unisession?.follow(in: window, store: model)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        (windows[window] ?? floatingWindows[window])?.commandKeyHints.cancel()
    }

    func applicationDidResignActive(_ notification: Notification) {
        for model in windows.values { model.commandKeyHints.cancel() }
    }

    func windowWillClose(_ notification: Notification) {
        if let owner = notification.object as? NSWindow {
            unisession?.ownerWillClose(owner)
            (windows[owner] ?? floatingWindows[owner])?.cancelConversationResumeForWindowClosure(owner)
        }
        if let window = notification.object as? NSWindow, let model = floatingWindows[window] {
            model.floatingPanes.didCloseWindow(window)
            return
        }
        guard let window = notification.object as? NSWindow, let model = windows.removeValue(forKey: window) else { return }
        model.commandKeyHints.cancel()
        model.floatingPanes.closeAll()
        settingsObservers.removeValue(forKey: ObjectIdentifier(window))
        interfaceObservers.removeValue(forKey: ObjectIdentifier(window))
        keyMaps.removeValue(forKey: ObjectIdentifier(window))
        keySequenceControllers.removeValue(forKey: ObjectIdentifier(window))?.cancel()
        for view in model.terminalViews.values { view.terminate() }
        if self.window === window { self.window = windows.keys.first; store = self.window.flatMap { windows[$0] } }
        if let next = self.window, let model = windows[next] { unisession?.follow(in: next, store: model) }
        refreshInterfacePolicy()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "trano" && url.host == "session" {
            let id = url.lastPathComponent
            guard UUID(uuidString: id) != nil else { continue }
            if window == nil { newWindow(createWorkspace: false) }
            store?.attach(id)
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openInterfaceWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The service owns only a status item; ControlCenter can close its window at login.
        if isBackgroundService { return false }
        let preferences = (try? interfaceRuntime?.interfacePreferences()) ?? store?.interfacePreferences ?? InterfacePreferences()
        return preferences.iconVisibility == .dockOnly && preferences.showWindowOnLaunch
    }
    func applicationWillTerminate(_ notification: Notification) {
        unisession?.shutdownFrontend()
        supervisorAdapter?.shutdownFrontend()
        readinessTimer?.invalidate()
        if let monitor { NSEvent.removeMonitor(monitor) }
        for (owner, model) in windows {
            model.cancelConversationResumeForWindowClosure(owner)
            model.commandKeyHints.cancel()
            model.floatingPanes.closeAll()
            for view in model.terminalViews.values { view.terminate() }
        }
    }

    func configureMenu() {
        let menu = NSMenu()
        let app = NSMenuItem()
        let submenu = NSMenu()
        submenu.addItem(withTitle: "About Trano", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let updates = submenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        for command in ActionCatalog.all where command.category == "App" {
            let item = NSMenuItem(title: command.title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
            item.target = self; item.identifier = NSUserInterfaceItemIdentifier(command.id)
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        submenu.addItem(withTitle: "Quit Trano", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = submenu
        menu.addItem(app)
        let groups: [(String, [String])] = [("Session", ["Session"]), ("Tab", ["Tab"]), ("Pane", ["Pane"]), ("Edit", ["Edit", "Input"]), ("View", ["Navigation", "Appearance"]), ("Window", ["Window"])]
        for (title, categories) in groups {
            let root = NSMenuItem(); root.title = title
            let submenu = NSMenu(title: title)
            for command in ActionCatalog.all where categories.contains(command.category) {
                let item = NSMenuItem(title: command.title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
                item.target = self
                item.identifier = NSUserInterfaceItemIdentifier(command.id)
                if command.action == .copy { item.target = nil; item.action = #selector(NSText.copy(_:)) }
                if command.action == .paste { item.target = nil; item.action = #selector(NSText.paste(_:)) }
                if command.action == .selectAll { item.target = nil; item.action = #selector(NSText.selectAll(_:)) }
                submenu.addItem(item)
            }
            root.submenu = submenu; menu.addItem(root)
        }
        NSApp.mainMenu = menu
        refreshMenuBindings(store?.state.settings.keyBindings ?? [:])
    }

    func observeSettings(_ model: AppStore, window: NSWindow) {
        window.acceptsMouseMovedEvents = true
        interfaceObservers[ObjectIdentifier(window)] = model.$interfacePreferences.removeDuplicates().sink { [weak self] _ in self?.refreshInterfacePolicy() }
        refreshInterfacePolicy()
        configureKeySequences(model, window: window)
        settingsObservers[ObjectIdentifier(window)] = model.$state.map(\.settings.keyBindings).removeDuplicates().sink { [weak self, weak model, weak window] overrides in
            guard let self, let window else { return }
            self.keyMaps[ObjectIdentifier(window)] = (try? TerminalKeySequenceMap(overrides: overrides)) ?? (try? TerminalKeySequenceMap())
            if let controller = self.keySequenceControllers[ObjectIdentifier(window)] {
                do { try controller.reload(overrides: overrides) }
                catch { try? controller.reload(overrides: [:]) }
            }
            guard self.store === model else { return }
            self.refreshMenuBindings(overrides)
        }
    }

    func configureFloatingPanes(_ model: AppStore) {
        model.onFloatingWindowChange = { [weak self, weak model] panel, opened in
            guard let self, let model else { return }
            if opened {
                self.floatingWindows[panel] = model
                panel.delegate = self
                self.observeSettings(model, window: panel)
            } else {
                self.floatingWindows.removeValue(forKey: panel)
                self.settingsObservers.removeValue(forKey: ObjectIdentifier(panel))
                self.keyMaps.removeValue(forKey: ObjectIdentifier(panel))
                self.keySequenceControllers.removeValue(forKey: ObjectIdentifier(panel))?.cancel()
                self.interfaceObservers.removeValue(forKey: ObjectIdentifier(panel))
            }
            self.refreshInterfacePolicy()
        }
    }

    private func configureKeySequences(_ model: AppStore, window: NSWindow) {
        let overlay = TerminalKeySequenceOverlay(owner: window)
        let controller = try? TerminalKeySequenceController(owner: window, overrides: model.state.settings.keyBindings,
            eligible: { [weak self, weak model, weak window] in
                guard let self, let model, let window,
                      self.windows[window] === model || self.floatingWindows[window] === model,
                      NSApp.isActive, window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil,
                      model.decisionPaneID == nil, model.followUpPaneID == nil, model.picker == nil, model.conversationResume == nil,
                      !model.showSettings, !model.showVoice, !model.showRemoteHosts, !model.showAccounts,
                      !model.showExtensions, !model.showActivity, model.remotePathRequest == nil else { return false }
                if let focusedID = model.focusedID {
                    guard let terminal = model.terminalViews[focusedID], terminal.store === model,
                          terminal.window === window, window.firstResponder === terminal else { return false }
                } else {
                    guard self.windows[window] === model, model.selectedTab == nil, model.state.layout.currentTabs.isEmpty,
                          !(window.firstResponder is NSTextInputClient) else { return false }
                }
                if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor { return false }
                if let recorder = window.firstResponder as? ShortcutButton, recorder.recording { return false }
                if let paneID = model.focusedID, model.terminalViews[paneID]?.urlHints.isActive == true { return false }
                return true
            }, composing: { [weak window] in
                (window?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
            }, target: { [weak model] in model?.focusedID }, supportsAction: { [weak model] action in
                guard let model else { return false }
                return model.focusedID != nil || action == .newSession || action == .newWindow
            }, onHints: { [weak model, weak window] hints in
                guard let model, let window else { overlay.dismiss(); return }
                if let paneID = model.focusedID, let terminal = model.terminalViews[paneID], terminal.window === window {
                    overlay.present(hints, in: terminal, bounds: terminal.bounds)
                } else if let content = window.contentView {
                    overlay.present(hints, in: content, bounds: content.bounds)
                } else { overlay.dismiss() }
            }, dispatch: { [weak self, weak window] action in
                guard let window else { return }
                self?.dispatchAction(action, from: window)
            })
        keySequenceControllers[ObjectIdentifier(window)]?.cancel()
        keySequenceControllers[ObjectIdentifier(window)] = controller
    }

    private func refreshMenuBindings(_ overrides: [String: [String]]) {
        let resolved = (try? TerminalKeySequenceMap(overrides: overrides)) ?? (try? TerminalKeySequenceMap())
        func update(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { update(submenu) }
                guard let id = item.identifier?.rawValue, ActionID(rawValue: id) != nil else { continue }
                let value = NativeKeyBinding.menuEquivalent(resolved?.singles.bindings[id]?.first ?? "")
                item.keyEquivalent = value.0; item.keyEquivalentModifierMask = value.1
                item.toolTip = resolved?.bindings[id]?.map(KeyBindingMap.display).joined(separator: ", ")
            }
        }
        if let menu = NSApp.mainMenu { update(menu) }
    }

    @objc func checkForUpdates() { UpdateController.shared.checkForUpdates() }

    @objc func performMenuAction(_ sender: NSMenuItem) {
        guard let id = sender.identifier?.rawValue, let action = ActionID(rawValue: id) else { return }
        dispatchAction(action)
    }

    private func dispatchAction(_ action: ActionID, from eventWindow: NSWindow? = nil) {
        guard NSApp.modalWindow == nil, !(eventWindow is WorkspaceToolPanelWindow), !(NSApp.keyWindow is WorkspaceToolPanelWindow) else { return }
        let supervisorTarget = eventWindow ?? NSApp.keyWindow
        if unisession?.ownsFocus(in: supervisorTarget) == true, unisession?.perform(action) == true { return }
        if let supervisorWindow, supervisorWindow.owns(supervisorTarget) || supervisorWindow.owns(supervisorTarget?.sheetParent) {
            _ = supervisorWindow.perform(action)
            return
        }
        if windows.isEmpty && floatingWindows.isEmpty {
            if action == .newWindow { newWindow(); return }
            if action == .settings { newWindow(createWorkspace: false); store?.showSettings = true; return }
        }
        let input = eventWindow ?? [NSApp.keyWindow, actionWindow, window].compactMap { $0 }.first {
            windows[$0] != nil || floatingWindows[$0] != nil
        }
        guard let model = input.flatMap({ windows[$0] ?? floatingWindows[$0] }) ?? store else { return }
        model.floatingPanes.noteInteraction(in: input)
        model.execute(action, sourceWindow: input)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates) { return UpdateController.shared.canCheckForUpdates }
        if menuItem.action == #selector(performMenuAction(_:)), let id = menuItem.identifier?.rawValue,
           let action = ActionID(rawValue: id), unisession?.ownsFocus(in: NSApp.keyWindow) == true, unisession?.supports(action) == true {
            return (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true
        }
        if menuItem.action == #selector(performMenuAction(_:)), NSApp.modalWindow != nil || NSApp.keyWindow is WorkspaceToolPanelWindow { return false }
        if menuItem.action == #selector(performMenuAction(_:)), let supervisorWindow,
           supervisorWindow.owns(NSApp.keyWindow) || supervisorWindow.owns(NSApp.keyWindow?.sheetParent) {
            guard let id = menuItem.identifier?.rawValue, let action = ActionID(rawValue: id) else { return false }
            return supervisorWindow.acceptsActions && supervisorWindow.supports(action)
        }
        guard menuItem.action == #selector(performMenuAction(_:)), let store else { return true }
        let queueToggle = menuItem.identifier?.rawValue == ActionID.queuedInput.rawValue && store.followUpEditor?.hasMarkedText() != true
        return (store.conversationResume == nil || menuItem.identifier?.rawValue == ActionID.resumeConversation.rawValue) && store.decisionPaneID == nil && (store.followUpPaneID == nil || queueToggle) && store.picker == nil && !store.showSettings && !store.showVoice && !store.showRemoteHosts && !store.showAccounts && !store.showExtensions && store.remotePathRequest == nil && window?.attachedSheet == nil
    }

    private func startPresencePublisher(root: URL) {
        guard !CommandLine.arguments.contains("--snapshot") else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishPresence(root: root) }
        }
        RunLoop.main.add(timer, forMode: .common)
        presenceTimer = timer
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification, NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.publishPresence(root: root) }
            }
        }
    }

    private func publishPresence(root: URL) {
        let key = NSApp.keyWindow
        let store = key.flatMap { windows[$0] ?? floatingWindows[$0] }
        let presence = InterfacePresence(pid: getpid(), focusedPaneID: NSApp.isActive ? store?.focusedID : nil)
        guard presence != publishedPresence else { return }
        do { try InterfacePresence.write(presence, root: root); publishedPresence = presence } catch {}
    }

    func handle(_ event: NSEvent) -> Bool {
        if event.type == .keyUp { return (event.window?.firstResponder as? TranoView)?.handleInterruptHandoff(event) ?? false }
        if OutsideClickDismissalRegistry.shared.handle(event, modalWindow: NSApp.modalWindow) { return true }
        let candidate = event.window ?? (event.type == .flagsChanged ? NSApp.keyWindow : nil)
        if let eventWindow = candidate, let store = windows[eventWindow] ?? floatingWindows[eventWindow],
           let handled = ActivityKeyboardInput.handle(event, store: store, in: eventWindow) { return handled }
        if event.type == .leftMouseDown,
           let candidate, let store = windows[candidate] ?? floatingWindows[candidate], store.canFocusPaneFromPointer,
           let target = TerminalPointerInput.primaryClickTarget(in: candidate, location: event.locationInWindow, store: store) {
            store.focus(target.paneID, in: candidate)
        }
        if let candidate, let unisession {
            unisession.noteInput(event)
            DispatchQueue.main.async { [weak unisession] in unisession?.reconcilePendingOwner() }
            if unisession.ownsFocus(in: candidate) || unisession.containsPointer(event) {
                (windows[candidate] ?? floatingWindows[candidate])?.commandKeyHints.cancel()
                keySequenceControllers[ObjectIdentifier(candidate)]?.cancel()
            }
            if let handled = unisession.route(event, action: event.type == .keyDown ? shortcutAction(for: event, in: candidate) : nil) {
                return handled
            }
        }
        if let supervisorWindow, supervisorWindow.owns(candidate) || supervisorWindow.owns(candidate?.sheetParent) {
            if supervisorWindow.handle(event) { return true }
            if supervisorWindow.acceptsActions, let terminal = supervisorWindow.renderer as? TranoView,
               let owner = supervisorWindow.window, let store = terminal.store {
                if event.type == .scrollWheel,
                   TerminalPointerInput.historyWheelTarget(in: owner, location: event.locationInWindow, store: store) === terminal {
                    return terminal.handleHistoryScrollWheel(event)
                }
                if event.type == .keyDown, owner.firstResponder === terminal, terminal.handleHistoryKeyDown(event) { return true }
                if event.type == .keyDown, owner.firstResponder === terminal, terminal.handleInterruptHandoff(event) { return true }
            }
            return false
        }
        guard let eventWindow = candidate, let store = windows[eventWindow] ?? floatingWindows[eventWindow] else { return false }
        TerminalColorPreviewRouting.handle(event, store: store, in: eventWindow)
        let sequenceController = keySequenceControllers[ObjectIdentifier(eventWindow)]
        sequenceController?.refreshEligibility()
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) { sequenceController?.cancel() }
        if [.rightMouseDown, .otherMouseDown].contains(event.type) { return false }
        if event.type == .scrollWheel {
            guard let view = TerminalPointerInput.historyWheelTarget(in: eventWindow, location: event.locationInWindow, store: store) else { return false }
            return view.handleHistoryScrollWheel(event)
        }
        if [.mouseMoved, .swipe, .magnify].contains(event.type) { return store.handleInterfaceEvent(event, in: eventWindow) }
        if let paneID = store.focusedID, let view = store.terminalViews[paneID], view.window === eventWindow,
           view.urlHints.isActive, view.urlHints.handle(event) { return true }
        if event.type == .flagsChanged {
            store.commandKeyHints.flagsChanged(event.modifierFlags) { [weak self, weak eventWindow, weak store] in
                guard let self, let eventWindow, let store else { return false }
                if let text = eventWindow.firstResponder as? NSTextView, text.isFieldEditor { return false }
                if let terminal = eventWindow.firstResponder as? TranoView, terminal.hasMarkedText() { return false }
                return self.window === eventWindow && self.commandHintWindowIsActive(eventWindow) && store.canShowTabShortcutHints && eventWindow.attachedSheet == nil && NSApp.modalWindow == nil
            }
            return false
        }
        if event.type == .keyDown { store.commandKeyHints.interrupt() }
        if event.type == .leftMouseDown { store.commandKeyHints.cancel() }
        if store.conversationResume != nil {
            return ConversationResumeInput.handle(event,
                composing: (eventWindow.firstResponder as? NSTextInputClient)?.hasMarkedText() == true,
                terminalIsResponder: eventWindow.firstResponder is TranoView,
                toggle: event.type == .keyDown && shortcutAction(for: event, in: eventWindow) == .resumeConversation,
                dismiss: { store.dismissConversationResume() })
        }
        if store.decisionPaneID != nil {
            if event.type == .keyDown, event.keyCode == 53 {
                if (eventWindow.firstResponder as? NSTextInputClient)?.hasMarkedText() == true { return false }
                store.dismissDecisions()
                return true
            }
            if event.type == .leftMouseDown {
                guard let content = eventWindow.contentView,
                      let panel = decisionPanel(in: content) else { return true }
                if !panel.bounds.contains(panel.convert(event.locationInWindow, from: nil)) {
                    store.dismissDecisions()
                    return true
                }
            }
            return event.type == .keyDown && eventWindow.firstResponder is TranoView
        }

        if store.followUpPaneID != nil {
            if event.type == .keyDown, shortcutAction(for: event, in: eventWindow) == .queuedInput {
                if !event.isARepeat { store.execute(.queuedInput) }
                return true
            }
            if event.type == .keyDown, event.keyCode == 53 {
                if store.followUpEditor?.hasMarkedText() == true { return false }
                store.dismissFollowUps()
                return true
            }
            if event.type == .leftMouseDown {
                guard let content = eventWindow.contentView,
                      let panel = followUpPanel(in: content) else { return true }
                if !panel.bounds.contains(panel.convert(event.locationInWindow, from: nil)) {
                    store.dismissFollowUps()
                    return true
                }
            }
            return event.type == .keyDown && eventWindow.firstResponder is TranoView
        }

        if store.picker != nil {
            if store.picker == .sessions, event.type == .keyDown,
               shortcutAction(for: event, in: eventWindow) == .newSession,
               eventWindow.attachedSheet == nil, NSApp.modalWindow == nil,
               !store.showSettings, !store.showVoice, !store.showRemoteHosts, !store.showAccounts,
               !store.showExtensions, store.remotePathRequest == nil,
               (eventWindow.firstResponder as? NSTextInputClient)?.hasMarkedText() != true {
                if !event.isARepeat {
                    store.dismissPicker()
                    dispatchAction(.newSession, from: eventWindow)
                }
                return true
            }
            if event.type == .keyDown, event.keyCode == 53 {
                if (eventWindow.firstResponder as? NSTextInputClient)?.hasMarkedText() == true { return false }
                store.dismissPicker()
                return true
            }
            if event.type == .leftMouseDown, let content = eventWindow.contentView,
               let picker = navigationPicker(in: content),
               !picker.bounds.contains(picker.convert(event.locationInWindow, from: nil)) {
                store.dismissPicker()
                return true
            }
            return false
        }
        if event.type == .leftMouseDown { return false }
        if let recorder = eventWindow.firstResponder as? ShortcutButton, recorder.recording {
            recorder.capture(event); return true
        }
        guard store.decisionPaneID == nil, store.followUpPaneID == nil, store.picker == nil, !store.showSettings, !store.showVoice, !store.showRemoteHosts, !store.showAccounts, !store.showExtensions, store.remotePathRequest == nil else { return false }
        guard eventWindow.attachedSheet == nil else { return false }
        if let text = eventWindow.firstResponder as? NSTextView, text.isFieldEditor,
           !(ActivityKeyboardInput.ownsFieldEditor(text) && !text.hasMarkedText() && event.type == .keyDown &&
             shortcutAction(for: event, in: eventWindow) == .activity) { return false }
        if let terminal = eventWindow.firstResponder as? TranoView, terminal.hasMarkedText() { return false }
        if sequenceController?.handle(event, showHints: store.terminalPreferences.showKeySequenceHints) == true { return true }
        if event.type == .keyDown, shortcutAction(for: event, in: eventWindow) == .copy,
           let terminal = eventWindow.firstResponder as? TranoView, terminal.window === eventWindow,
           terminal.store === store, store.terminalViews[terminal.paneID] === terminal {
            terminal.copy(self)
            return true
        }
        if let terminal = eventWindow.firstResponder as? TranoView,
           terminal.paneID != store.focusedID || terminal.store !== store || store.terminalViews[terminal.paneID] !== terminal {
            sequenceController?.cancel()
            if let action = shortcutAction(for: event, in: eventWindow),
               action == .nextTab || action == .previousTab,
               let external = terminal.store,
               case .unisession(let binding)? = external.externalPanePolicy,
               binding.paneID == terminal.paneID, external.focusedID == terminal.paneID,
               external.terminalViews[terminal.paneID] === terminal,
               external.runtime.root == store.runtime.root,
               terminal.window === eventWindow, !terminal.isHiddenOrHasHiddenAncestor,
               external.sessions.contains(where: { $0.id == binding.paneID && $0.pid == binding.backendPID && $0.remote == nil && $0.host == "local" }) {
                dispatchAction(action, from: eventWindow)
                return true
            }
            return !event.modifierFlags.intersection([.command, .control]).isEmpty
        }
        if event.type == .keyDown, let terminal = eventWindow.firstResponder as? TranoView,
           terminal.handleHistoryKeyDown(event) { return true }
        if event.type == .keyDown, shortcutAction(for: event, in: eventWindow) == nil,
           let terminal = eventWindow.firstResponder as? TranoView, terminal.handleInterruptHandoff(event) { return true }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard flags.contains(.command) || flags.contains(.control) else { return false }
        let special: [UInt16: String] = [123: "left", 124: "right", 125: "down", 126: "up", 36: "enter", 48: "tab", 24: "=", 27: "-"]
        var key = special[event.keyCode] ?? event.charactersIgnoringModifiers?.lowercased() ?? ""
        if key == "{" { key = "[" }; if key == "}" { key = "]" }
        if flags == .command, key == "y", store.developerPreferences.previewsLinks,
           keyMaps[ObjectIdentifier(eventWindow)]?.singles.action(for: "cmd+y") == nil {
            if !event.isARepeat {
                _ = previewQuickLookLink(in: eventWindow, store: store,
                                         pointerInWindow: eventWindow.mouseLocationOutsideOfEventStream)
            }
            return true
        }
        if flags == .command, let number = Int(key), (1...9).contains(number) {
            let tabs = store.state.layout.currentTabs
            let index = number == 9 ? tabs.count - 1 : number - 1
            if tabs.indices.contains(index) { store.selectTab(tabs[index].id) }
            return true
        }
        guard let action = shortcutAction(for: event, in: eventWindow) else { return false }
        if (action == .queuedInput || action == .urlHints || action == .activity) && event.isARepeat { return true }
        dispatchAction(action, from: eventWindow)
        return true
    }

    private func previewQuickLookLink(in owner: NSWindow, store: AppStore, pointerInWindow: NSPoint) -> Bool {
        guard windows[owner] === store || floatingWindows[owner] === store,
              let responder = owner.firstResponder as? TranoView,
              responder.window === owner, responder.store === store,
              store.terminalViews[responder.paneID] === responder else { return false }

        let sources = store.terminalViews.compactMap { paneID, view -> QuickLookHoverPane? in
            guard view.window === owner, view.store === store, view.paneID == paneID,
                  let session = store.sessions.first(where: { $0.id == paneID }), session.cwd.hasPrefix("/") else { return nil }
            return QuickLookHoverPane(paneID: paneID, cwd: URL(fileURLWithPath: session.cwd, isDirectory: true),
                isRemote: session.host != "local" || session.remote != nil,
                ownerID: ObjectIdentifier(owner),
                visible: owner.isVisible && !owner.isMiniaturized && !view.isHiddenOrHasHiddenAncestor && !view.visibleRect.isEmpty,
                pointInView: { [weak view] point in
                    view?.convert(point, from: nil) ?? NSPoint(x: CGFloat.nan, y: CGFloat.nan)
                },
                containsPoint: { [weak view] point in
                    guard let view else { return false }
                    return view.bounds.contains(point) && view.visibleRect.contains(point)
                },
                hoveredLink: { [weak view] point in view?.link(atViewPoint: point) },
                selectedText: { [weak view] in view?.getSelection() })
        }
        return QuickLookHoverHost.handle(preferences: store.developerPreferences,
            ownerID: ObjectIdentifier(owner), ownerIsRegistered: true,
            firstResponderPaneID: responder.paneID, focusedPaneID: store.focusedID,
            hasMarkedText: responder.hasMarkedText(), hasModal: owner.attachedSheet != nil || NSApp.modalWindow != nil,
            inputBusy: !store.safeInterfaceNavigation,
            configuredSingleAction: keyMaps[ObjectIdentifier(owner)]?.singles.action(for: "cmd+y"),
            pointerInOwner: pointerInWindow, panes: sources) { result in
                guard let current = store.terminalViews[result.paneID], current.window === owner,
                      current.store === store, current.paneID == result.paneID else { return }
                DeveloperLinkPreviewController.shared.show(result.target, owner: owner)
            }
    }

    private func shortcutAction(for event: NSEvent, in window: NSWindow) -> ActionID? {
        guard let binding = NativeKeyBinding.binding(for: event) else { return nil }
        return keyMaps[ObjectIdentifier(window)]?.singles.action(for: binding)
    }

    private func decisionPanel(in view: NSView) -> NSView? {
        if view.identifier?.rawValue == "decision-inbox-panel" { return view }
        for child in view.subviews { if let panel = decisionPanel(in: child) { return panel } }
        return nil
    }

    private func followUpPanel(in view: NSView) -> NSView? {
        if view.identifier?.rawValue == "follow-up-panel" { return view }
        for child in view.subviews {
            if let panel = followUpPanel(in: child) { return panel }
        }
        return nil
    }

    private func navigationPicker(in view: NSView) -> NSView? {
        if view.identifier?.rawValue == "navigation-picker" { return view }
        for child in view.subviews {
            if let picker = navigationPicker(in: child) { return picker }
        }
        return nil
    }

}

@main enum TranoEntry {
    @MainActor static func main() {
        _ = BuildIdentity.process
        if CommandLine.arguments.contains("--ensure-service") {
            do {
                let runtime = try TerminalRuntime(helperExecutable: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/trano").path)
                let result = try ServiceHandoff.ensure(runtime: runtime, executable: BackgroundService.helperBundle.appendingPathComponent("Contents/MacOS/TranoApp"))
                FileHandle.standardOutput.write(try JSONEncoder().encode(result)); FileHandle.standardOutput.write(Data([10]))
                exit(0)
            } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
        }
        if CommandLine.arguments.contains("--check") || CommandLine.arguments.contains("--state-json") {
            do {
                let runtime = try TerminalRuntime()
                let response = APIService(runtime: runtime).route(APIRequest(method: CommandLine.arguments.contains("--check") ? "server.info" : "state.get"))
                FileHandle.standardOutput.write(try JSONEncoder().encode(response)); FileHandle.standardOutput.write(Data([10]))
                exit(response.error == nil ? 0 : 1)
            } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
        }
        let app = NSApplication.shared
        let delegate = ApplicationDelegate()
        app.delegate = delegate
        app.setActivationPolicy(LaunchRole.isService ? .accessory : (CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--benchmark-readiness") ? .prohibited : .regular))
        withExtendedLifetime(delegate) { app.run() }
    }
}
