import AppKit
import Combine
import SwiftUI
import TerminalCore

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    var window: NSWindow?
    var store: AppStore?
    var monitor: Any?
    var service: APIService?
    var notifications: NotificationController?
    var windows: [NSWindow: AppStore] = [:]
    private var settingsObservers: [ObjectIdentifier: AnyCancellable] = [:]
    private var keyMaps: [ObjectIdentifier: KeyBindingMap] = [:]
    private var readinessTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let helper = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("trano").path
            let runtime = try TerminalRuntime(helperExecutable: helper)
            if CommandLine.arguments.contains("--service") {
                let mainBundle = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                let notifications = NotificationController(runtime: runtime, applicationURL: mainBundle)
                let service = APIService(runtime: runtime, customHandler: notifications.handle, responseDidSend: notifications.responseDidSend)
                notifications.onShutdown = { [weak service] in service?.stop(); NSApp.terminate(nil) }
                try service.start()
                notifications.start()
                self.service = service; self.notifications = notifications
                return
            }
            let benchmark = argument("--benchmark-readiness") != nil
            if !CommandLine.arguments.contains("--snapshot") && !benchmark { BackgroundService.start(runtime: runtime) }
            if !CommandLine.arguments.contains("--snapshot") && !benchmark { UpdateController.shared.start() }
            let model = AppStore(runtime: runtime)
            store = model
            let snapshot = CommandLine.arguments.contains("--snapshot")
            let snapshotSurface = argument("--snapshot-view") ?? "workspace"
            let content: AnyView = snapshot && ["appearance", "shortcuts", "general", "updates"].contains(snapshotSurface)
                ? AnyView(SettingsView(store: model, initialSection: snapshotSurface)) : AnyView(WorkspaceView(store: model))
            let view = NSHostingView(rootView: content)
            let dimensions = argument("--snapshot-size")?.split(separator: "x").compactMap { Double($0) }.filter(\.isFinite) ?? []
            let width = snapshot && dimensions.count == 2 ? min(4096, max(900, dimensions[0])) : 1280
            let height = snapshot && dimensions.count == 2 ? min(2160, max(620, dimensions[1])) : 800
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Trano"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = false
            window.backgroundColor = .clear
            window.isOpaque = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = view
            window.minSize = NSSize(width: 900, height: 620)
            window.center()
            self.window = window
            window.delegate = self
            windows[window] = model
            model.isActiveWindow = { [weak self, weak window] in self?.window === window }
            model.onNewWindow = { [weak self] in self?.newWindow() }
            model.onCloseWindow = { [weak window] in window?.close() }
            configureMenu()
            observeSettings(model, window: window)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
                self?.handle(event) == true ? nil : event
            }
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

    func newWindow() {
        guard let runtime = store?.runtime else { return }
        let model = AppStore(runtime: runtime)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Trano"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: WorkspaceView(store: model))
        window.minSize = NSSize(width: 900, height: 620)
        window.center()
        window.delegate = self
        windows[window] = model
        observeSettings(model, window: window)
        model.isActiveWindow = { [weak self, weak window] in self?.window === window }
        model.onNewWindow = { [weak self] in self?.newWindow() }
        model.onCloseWindow = { [weak window] in window?.close() }
        window.makeKeyAndOrderFront(nil)
        model.execute(.newSession)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let model = windows[window] else { return }
        self.window = window; store = model
        refreshMenuBindings(model.state.settings.keyBindings)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let model = windows.removeValue(forKey: window) else { return }
        settingsObservers.removeValue(forKey: ObjectIdentifier(window))
        keyMaps.removeValue(forKey: ObjectIdentifier(window))
        for view in model.terminalViews.values { view.terminate() }
        if self.window === window { self.window = windows.keys.first; store = self.window.flatMap { windows[$0] } }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "trano" && url.host == "session" {
            let id = url.lastPathComponent
            guard UUID(uuidString: id) != nil else { continue }
            store?.attach(id)
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        readinessTimer?.invalidate()
        if let monitor { NSEvent.removeMonitor(monitor) }
        for model in windows.values { for view in model.terminalViews.values { view.terminate() } }
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

    private func observeSettings(_ model: AppStore, window: NSWindow) {
        settingsObservers[ObjectIdentifier(window)] = model.$state.map(\.settings.keyBindings).removeDuplicates().sink { [weak self, weak model, weak window] overrides in
            guard let self, let window else { return }
            self.keyMaps[ObjectIdentifier(window)] = (try? KeyBindingMap(overrides: overrides)) ?? (try? KeyBindingMap())
            guard self.store === model else { return }
            self.refreshMenuBindings(overrides)
        }
    }

    private func refreshMenuBindings(_ overrides: [String: [String]]) {
        let resolved = (try? KeyBindingMap(overrides: overrides)) ?? (try? KeyBindingMap())
        func update(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { update(submenu) }
                guard let id = item.identifier?.rawValue, ActionID(rawValue: id) != nil else { continue }
                let value = NativeKeyBinding.menuEquivalent(resolved?.bindings[id]?.first ?? "")
                item.keyEquivalent = value.0; item.keyEquivalentModifierMask = value.1
            }
        }
        if let menu = NSApp.mainMenu { update(menu) }
    }

    @objc func checkForUpdates() { UpdateController.shared.checkForUpdates() }

    @objc func performMenuAction(_ sender: NSMenuItem) {
        guard let id = sender.identifier?.rawValue, let action = ActionID(rawValue: id) else { return }
        store?.execute(action)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates) { return UpdateController.shared.canCheckForUpdates }
        guard menuItem.action == #selector(performMenuAction(_:)), let store else { return true }
        return store.picker == nil && !store.showSettings && !store.showVoice && !store.showRemoteHosts && !store.showAccounts && !store.showExtensions && store.remotePathRequest == nil && window?.attachedSheet == nil
    }

    func handle(_ event: NSEvent) -> Bool {
        guard let eventWindow = event.window, let store = windows[eventWindow] else { return false }
        if store.picker != nil {
            if event.type == .keyDown, event.keyCode == 53 {
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
        if store.showActivity {
            if event.type == .keyDown, event.keyCode == 53 {
                store.showActivity = false
                return true
            }
            if event.type == .leftMouseDown { return false }
        }
        if event.type == .leftMouseDown {
            for (id, view) in store.terminalViews where view.window === event.window {
                if view.bounds.contains(view.convert(event.locationInWindow, from: nil)) { store.focus(id); break }
            }
            return false
        }
        if let recorder = eventWindow.firstResponder as? ShortcutButton, recorder.recording {
            recorder.capture(event); return true
        }
        guard store.picker == nil, !store.showSettings, !store.showVoice, !store.showRemoteHosts, !store.showAccounts, !store.showExtensions, store.remotePathRequest == nil else { return false }
        guard eventWindow.attachedSheet == nil else { return false }
        if let text = eventWindow.firstResponder as? NSTextView, text.isFieldEditor { return false }
        if let terminal = eventWindow.firstResponder as? TranoView, terminal.hasMarkedText() { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard flags.contains(.command) || flags.contains(.control) else { return false }
        let special: [UInt16: String] = [123: "left", 124: "right", 125: "down", 126: "up", 36: "enter", 48: "tab", 24: "=", 27: "-"]
        var key = special[event.keyCode] ?? event.charactersIgnoringModifiers?.lowercased() ?? ""
        if key == "{" { key = "[" }; if key == "}" { key = "]" }
        if flags == .command, let number = Int(key), (1...9).contains(number) {
            let tabs = store.state.layout.currentTabs
            let index = number == 9 ? tabs.count - 1 : number - 1
            if tabs.indices.contains(index) { store.selectTab(tabs[index].id) }
            return true
        }
        guard let binding = NativeKeyBinding.binding(for: event),
              let map = keyMaps[ObjectIdentifier(eventWindow)],
              let action = map.action(for: binding) else { return false }
        store.execute(action)
        return true
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
        app.setActivationPolicy(CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--service") || CommandLine.arguments.contains("--benchmark-readiness") ? .prohibited : .regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
