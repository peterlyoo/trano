import AppKit
import TerminalCore

@MainActor final class ServerStatusMenu: NSObject {
    let menu = NSMenu()
    private let status = NSMenuItem(title: "Trano Server Starting…", action: nil, keyEquivalent: "")
    private let detail = NSMenuItem(title: "Checking local connection…", action: nil, keyEquivalent: "")
    private let openAction: () -> Void
    private let retryAction: () -> Void
    private let restartAction: () -> Void
    private let copyAction: () -> Void
    private let quitAction: () -> Void

    init(open: @escaping () -> Void, retry: @escaping () -> Void, restart: @escaping () -> Void, copy: @escaping () -> Void, quit: @escaping () -> Void = {}) {
        openAction = open; retryAction = retry; restartAction = restart; copyAction = copy; quitAction = quit
        super.init()
        menu.autoenablesItems = false
        status.isEnabled = false; detail.isEnabled = false
        menu.addItem(status); menu.addItem(detail); menu.addItem(.separator())
        add("Open Trano", #selector(openTrano), symbol: "macwindow")
        add("Retry Connection", #selector(ServerStatusMenu.retry), symbol: "arrow.clockwise")
        add("Restart Server", #selector(ServerStatusMenu.restart), symbol: "arrow.triangle.2.circlepath")
        menu.addItem(.separator())
        add("Copy Diagnostics", #selector(copyDiagnostics), symbol: "doc.on.doc")
        menu.addItem(.separator())
        add("Quit Server", #selector(quitServer), symbol: "power")
    }
    private func add(_ title: String, _ action: Selector, symbol: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menu.addItem(item)
    }
    func update(_ value: ServerStatusSnapshot) {
        status.title = value.title
        let symbol: String
        switch value.phase {
        case .running: symbol = "checkmark.circle.fill"; detail.title = "Local connection is healthy"
        case .starting, .restarting: symbol = "clock.fill"; detail.title = "Checking local connection…"
        case .connectionError, .startupError: symbol = "exclamationmark.triangle.fill"; detail.title = String((value.error ?? "Connection unavailable").prefix(100))
        case .stopped: symbol = "stop.circle"; detail.title = "Background server is stopped"
        }
        status.image = NSImage(systemSymbolName: symbol, accessibilityDescription: value.title)
        menu.item(withTitle: "Retry Connection")?.isEnabled = value.canRetry
        menu.item(withTitle: "Restart Server")?.isEnabled = value.canRestart
        menu.item(withTitle: "Quit Server")?.isEnabled = value.phase != .stopped
    }
    @objc private func openTrano() { openAction() }
    @objc private func retry() { retryAction() }
    @objc private func restart() { restartAction() }
    @objc private func copyDiagnostics() { copyAction() }
    @objc private func quitServer() { quitAction() }
}

@MainActor final class ServerStatusController {
    static let menuBarImage: NSImage? = {
        guard let url = Bundle.module.url(forResource: "TranoStatusMark", withExtension: "pdf"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 44, height: 16)
        image.isTemplate = true
        return image
    }()
    private var state: ServerStatusState
    private let cache: ServerStatusCache
    private var item: NSStatusItem?
    private var menu: ServerStatusMenu!
    private var timer: Timer?
    private let worker = DispatchQueue(label: "trano.server-status", qos: .utility)
    private let startOperation: () throws -> Void
    private let restartOperation: () throws -> Void
    private let probeOperation: () throws -> APIResponse
    private let openOperation: () -> Void
    private let quitOperation: () -> Void
    private var shuttingDown = false

    init(cache: ServerStatusCache, registerItem: Bool = true, start: @escaping () throws -> Void, restart: @escaping () throws -> Void,
         probe: @escaping () throws -> APIResponse, open: @escaping () -> Void, quit: @escaping () -> Void = {}) {
        self.cache = cache; state = ServerStatusState(pid: cache.snapshot().pid, buildID: cache.snapshot().buildID)
        startOperation = start; restartOperation = restart; probeOperation = probe; openOperation = open; quitOperation = quit
        menu = ServerStatusMenu(open: { [weak self] in self?.openOperation() }, retry: { [weak self] in self?.retry() },
                                restart: { [weak self] in self?.restart() }, copy: { [weak self] in self?.copyDiagnostics() }, quit: { [weak self] in self?.quitOperation() })
        if registerItem {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item?.button?.image = Self.menuBarImage
            item?.menu = menu.menu
            state.setItemRegistered(item?.button != nil)
        }
        publish()
    }
    func start() {
        guard timer == nil, !shuttingDown else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.probe() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        beginStart(restarting: false)
    }
    func stop() {
        timer?.invalidate(); timer = nil
        state.stop()
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil; state.setItemRegistered(false); publish()
    }
    func shutdown(_ operation: @escaping () -> Void, completion: @escaping () -> Void) {
        guard !shuttingDown else { return }
        shuttingDown = true
        stop()
        worker.async {
            operation()
            DispatchQueue.main.async(execute: completion)
        }
    }
    func retry() {
        guard state.snapshot.canRetry else { return }
        if state.snapshot.phase == .startupError { beginStart(restarting: false) } else { probe() }
    }
    func restart() {
        guard state.snapshot.canRestart else { return }
        beginStart(restarting: true)
    }
    private func beginStart(restarting: Bool) {
        let generation = state.beginStart(restarting: restarting)
        publish()
        let operation = restarting ? restartOperation : startOperation
        worker.async { [weak self] in
            let failure: String?
            do { try operation(); failure = nil } catch { failure = String(error.localizedDescription.prefix(512)) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.state.finishStart(generation, error: failure); self.publish()
                if failure == nil { self.probe() }
            }
        }
    }
    private func probe() {
        guard let lease = state.beginProbe() else { return }
        let operation = probeOperation
        worker.async { [weak self] in
            let result = Result { try operation() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.state.finishProbe(lease, result: result, now: Date()); self.publish()
            }
        }
    }
    private func publish() {
        let value = state.snapshot
        cache.update(value); menu.update(value)
        item?.button?.toolTip = value.title
        item?.button?.setAccessibilityLabel(value.title)
    }
    private func copyDiagnostics() {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(cache.snapshot()), let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}
