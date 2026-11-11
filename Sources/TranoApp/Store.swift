import AppKit
import SwiftUI
import TerminalCore
import UserNotifications

@MainActor final class AppStore: ObservableObject {
    @Published var state = RuntimeState()
    @Published var sessions: [TerminalSession] = []
    @Published var message: String?
    @Published var picker: PickerKind?
    @Published var showActivity = false
    @Published var showSessionsSidebar = false
    @Published var showSettings = false
    @Published var showVoice = false
    @Published var showRemoteHosts = false
    @Published var showAccounts = false
    @Published var showExtensions = false
    @Published var remotePathRequest: RemotePathRequest?
    @Published var zoomed = false
    @Published var loading = true
    let runtime: TerminalRuntime
    let queue = DispatchQueue(label: "trano.runtime", qos: .userInitiated)
    private var watcher: DispatchSourceFileSystemObject?
    private var refreshWork: DispatchWorkItem?
    var terminalViews: [String: TranoView] = [:]
    private var selection = WindowSelection()
    var preferredWorkspaceID: String? { selection.workspaceID }
    var isActiveWindow: () -> Bool = { true }

    enum PickerKind: String, Identifiable { case sessions, commands, anything, movePane; var id: String { rawValue } }
    var selectedTab: TerminalTab? { state.layout.tabs.first { $0.id == state.layout.selectedTabID } }
    var focusedID: String? { state.layout.focusedPaneID }
    var currentDirectory: String { sessions.first { $0.id == focusedID }?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path }

    init(runtime: TerminalRuntime) {
        self.runtime = runtime
        let fd = open(runtime.root.path, O_EVTONLY | O_CLOEXEC)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
            source.setEventHandler { [weak self] in self?.scheduleRefresh() }
            source.setCancelHandler { close(fd) }
            source.resume()
            watcher = source
        }
        perform(restoringContext: false, holdingTransaction: false) { _ = try $0.recoverSessions(automatic: true) }
    }

    func perform(restoringContext: Bool = true, holdingTransaction: Bool = true, _ work: @escaping (TerminalRuntime) throws -> Void) {
        let runtime = runtime
        let context = preferredWorkspaceID
        queue.async { [weak self] in
            do {
                let operation = {
                    if restoringContext, let context, try runtime.state().layout.selectedWorkspaceID != context {
                        try runtime.update { try $0.layout.selectWorkspace(context) }
                    }
                    try work(runtime)
                    return (try runtime.state(), try runtime.list())
                }
                let (state, sessions) = try holdingTransaction ? runtime.transaction(operation) : operation()
                DispatchQueue.main.async { self?.apply(state, sessions: sessions, takeSelection: restoringContext) }
            } catch { DispatchQueue.main.async { self?.message = error.localizedDescription; self?.loading = false } }
        }
    }

    func refresh() { perform(restoringContext: false) { _ in } }
    private func scheduleRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
    }

    private func apply(_ snapshot: RuntimeState, sessions: [TerminalSession], takeSelection: Bool) {
        let next = selection.resolve(snapshot, ownAction: takeSelection, acceptsRequests: isActiveWindow())
        self.state = next
        self.sessions = sessions
        loading = false
        let attached = Set(next.layout.tabs.flatMap(\.panes))
        for (id, terminal) in terminalViews where !attached.contains(id) {
            terminal.terminate()
            terminalViews.removeValue(forKey: id)
        }
        if takeSelection, let id = focusedID, let view = terminalViews[id] {
            DispatchQueue.main.async { if self.picker == nil && !self.showSettings && !self.showVoice { view.window?.makeFirstResponder(view) } }
        }
    }

    func newTab() { execute(.newTab) }

    func newSession(title: String? = nil) {
        picker = nil; zoomed = false
        perform { try $0.performAction(.newSession, title: title) }
    }

    func dismissPicker() {
        picker = nil
        restoreTerminalFocus()
    }

    private func restoreTerminalFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.picker == nil, !self.showSettings, !self.showVoice,
                  !self.showRemoteHosts, !self.showAccounts, !self.showExtensions,
                  self.remotePathRequest == nil, NSApp.modalWindow == nil,
                  let id = self.focusedID, let view = self.terminalViews[id],
                  let window = view.window, window.attachedSheet == nil else { return }
            if let responder = window.firstResponder as? NSView, responder !== view {
                let editorOwner = (responder as? NSTextView)?.delegate as? NSView
                if responder.isDescendant(of: view) || editorOwner?.isDescendant(of: view) == true { return }
            }
            window.makeFirstResponder(view)
        }
    }

    func newTab(at directory: String) { perform { try $0.performAction(.newTab, cwd: directory) } }

    func split(_ axis: SplitAxis) {
        guard let tab = selectedTab else { newTab(); return }
        let cwd = currentDirectory
        perform { runtime in
            let session = try runtime.create(title: "Shell", cwd: cwd)
            do { try runtime.update { try $0.layout.split(tabID: tab.id, paneID: session.id, axis: axis) } }
            catch { try? runtime.terminate(session.id); throw error }
        }
    }

    func focus(_ id: String) {
        guard focusedID != id else { return }
        try? state.layout.focusPane(id)
        perform { try $0.update { try $0.layout.focusPane(id) } }
    }

    func selectTab(_ id: String) {
        zoomed = false
        perform { try $0.update { try $0.layout.selectTab(id) } }
    }

    func selectWorkspace(_ id: String) {
        picker = nil; zoomed = false
        perform { try $0.update { try $0.layout.selectWorkspace(id) } }
    }

    func attach(_ id: String) {
        picker = nil
        perform { try $0.update { state in
            guard state.sessions.contains(where: { $0.id == id }) else { throw TerminalError.invalid("Unknown session") }
            if state.layout.tabs.contains(where: { $0.panes.contains(id) }) {
                try state.layout.focusPane(id)
            } else { state.layout.addTab(paneID: id) }
        } }
    }

    func authorizeNotifications() {
        perform { runtime in
            let result = try APIClient(path: runtime.root.appendingPathComponent("api.sock").path).call(APIRequest(method: "notifications.authorize"))
            if let error = result.error { throw TerminalError.runtime(error) }
        }
    }

    func detach() {
        guard let id = focusedID else { return }
        perform { try $0.update { $0.layout.detach(id) } }
    }

    func terminate(_ id: String) {
        let alert = NSAlert()
        alert.messageText = "Terminate this session?"
        alert.informativeText = "The shell and its running jobs will stop. Close Pane keeps them running."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Terminate")
        if alert.runModal() == .alertSecondButtonReturn { perform { try $0.terminate(id) } }
    }

    func move(_ paneID: String, to tabID: String) {
        perform { try $0.update { try $0.layout.move(paneID: paneID, to: tabID) } }
    }

    func resizeSplit(_ id: String, ratio: Double) {
        perform { try $0.update { try $0.layout.resize(splitID: id, ratio: ratio) } }
    }

    func resizeFocused(_ direction: PaneResizeDirection) {
        guard let pane = focusedID, let target = selectedTab?.tree.resizeTarget(paneID: pane, direction: direction) else { return }
        resizeSplit(target.splitID, ratio: target.ratio)
    }

    func focusDirection(horizontal: Double, vertical: Double) {
        guard let id = focusedID, let current = terminalViews[id], let window = current.window else { return }
        let origin = current.convert(current.bounds, to: nil)
        let candidates = (selectedTab?.panes ?? []).compactMap { candidate -> (String, Double)? in
            guard candidate != id, let view = terminalViews[candidate], view.window === window else { return nil }
            let rect = view.convert(view.bounds, to: nil)
            let dx = rect.midX - origin.midX, dy = rect.midY - origin.midY
            guard dx * horizontal + dy * vertical > 1 else { return nil }
            return (candidate, hypot(dx, dy))
        }
        if let next = candidates.min(by: { $0.1 < $1.1 }) { focus(next.0) }
    }

    func find(_ action: NSFindPanelAction = .showFindPanel) {
        guard let id = focusedID else { return }
        let item = NSMenuItem()
        item.tag = Int(action.rawValue)
        terminalViews[id]?.performFindPanelAction(item)
    }

    func moveToNewTab() {
        guard let id = focusedID else { return }
        perform { try $0.update { $0.layout.detach(id); $0.layout.addTab(paneID: id) } }
    }

    func cyclePane(_ delta: Int) {
        guard let panes = selectedTab?.panes, !panes.isEmpty else { return }
        let current = panes.firstIndex(of: focusedID ?? "") ?? 0
        focus(panes[(current + delta + panes.count) % panes.count])
    }

    func cycleTab(_ delta: Int) { execute(delta > 0 ? .nextTab : .previousTab) }

    func fontSize(_ delta: Double) {
        var settings = state.settings
        settings.fontSize = delta == 0 ? 14 : min(40, max(9, settings.fontSize + delta))
        saveSettings(settings)
    }

    func saveSettings(_ settings: TerminalSettings, from baseline: TerminalSettings? = nil) {
        let baseline = baseline ?? state.settings
        perform { runtime in
            try runtime.update { $0.settings.merge(settings, from: baseline) }
            if settings.persistScrollback != baseline.persistScrollback { try runtime.setScrollbackPersistence(settings.persistScrollback) }
        }
        if settings.persistScrollback != baseline.persistScrollback {
            let hosts = state.remoteHosts, runtime = runtime
            queue.async {
                for host in hosts {
                    do { _ = try RemoteClient(host: host).call(APIRequest(method: "scrollback.settings", params: ["enabled": .bool(settings.persistScrollback)])) }
                    catch { DispatchQueue.main.async { self.message = "Scrollback preference could not reach " + host.name + ": " + error.localizedDescription } }
                }
            }
        }
    }

    var onNewWindow: (() -> Void)?
    var onCloseWindow: (() -> Void)?

    func execute(_ action: ActionID) {
        if action == .closePane && focusedID == nil || action == .closeTab && selectedTab == nil { onCloseWindow?(); return }
        defer { restoreTerminalFocus() }
        let view = focusedID.flatMap { terminalViews[$0] }
        switch action {
        case .newWindow: onNewWindow?()
        case .newSession: newSession()
        case .fullscreen: view?.window?.toggleFullScreen(nil)
        case .palette: picker = .commands
        case .switchSession: picker = .sessions
        case .goToAnything: picker = .anything
        case .movePaneTab: picker = .movePane
        case .settings: showSettings = true
        case .voice: showVoice = true
        case .resizeLeft: resizeFocused(.left)
        case .resizeRight: resizeFocused(.right)
        case .resizeUp: resizeFocused(.up)
        case .resizeDown: resizeFocused(.down)
        case .activity: showActivity.toggle()
        case .zoom: zoomed.toggle()
        case .focusLeft: focusDirection(horizontal: -1, vertical: 0)
        case .focusRight: focusDirection(horizontal: 1, vertical: 0)
        case .focusUp: focusDirection(horizontal: 0, vertical: 1)
        case .focusDown: focusDirection(horizontal: 0, vertical: -1)
        case .copy: view?.copy(self)
        case .paste: view?.paste(self)
        case .selectAll: view?.selectAll(self)
        case .clear: view?.clearScrollback()
        case .find: find()
        case .findNext: find(.next)
        case .findPrevious: find(.previous)
        case .copyPaneID:
            if let id = focusedID { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(id, forType: .string) }
        case .insertPath: pickPath(directoryOnly: false)
        case .goToDirectory: pickPath(directoryOnly: true)
        case .renameSession, .renameTab, .renamePane: rename(action)
        case .restoreSessions:
            perform(restoringContext: false, holdingTransaction: false) { _ = try $0.recoverSessions() }
        default:
            zoomed = false
            perform { try $0.performAction(action) }
        }
    }

    private func pickPath(directoryOnly: Bool) {
        guard let id = focusedID, terminalViews[id]?.window != nil else { return }
        if let pane = sessions.first(where: { $0.id == id }), let reference = pane.remote {
            remotePathRequest = RemotePathRequest(paneID: id, hostID: reference.hostID, path: pane.cwd, directoryOnly: directoryOnly)
            return
        }
        let runtime = runtime
        queue.async { [weak self] in
            let cwd = try? runtime.workingDirectory(id)
            DispatchQueue.main.async {
                guard let self, let view = self.terminalViews[id], let window = view.window else { return }
                let panel = NSOpenPanel()
                panel.title = directoryOnly ? "Go to Directory" : "Insert Path"
                panel.prompt = directoryOnly ? "Open in New Tab" : "Insert Path"
                panel.canChooseFiles = !directoryOnly
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = !directoryOnly
                panel.directoryURL = URL(fileURLWithPath: cwd ?? self.currentDirectory)
                panel.beginSheetModal(for: window) { result in
                    guard result == .OK else { return }
                    if directoryOnly, let path = panel.url?.path { self.newTab(at: path) }
                    else {
                        do { view.pasteText(try PathInsertion.text(paths: panel.urls.map(\.path))) }
                        catch { self.message = error.localizedDescription }
                    }
                }
            }
        }
    }

    func insertImage(_ data: Data, paneID: String) {
        let runtime = runtime
        queue.async { [weak self] in
            do {
                let path = try runtime.saveAttachment(data, paneID: paneID)
                DispatchQueue.main.async {
                    guard let self, let view = self.terminalViews[paneID], view.window != nil else { return }
                    view.pasteText(ShellQuote.quote(path) + " ")
                }
            } catch { DispatchQueue.main.async { self?.message = error.localizedDescription } }
        }
    }

    func toggleCollapse(_ id: String) {
        perform { try $0.update { state in
            if let index = state.layout.workspaces.firstIndex(where: { $0.id == id }) { state.layout.workspaces[index].collapsed.toggle() }
        } }
    }

    func rename(_ action: ActionID, target: String? = nil) {
        let workspaceID = action == .renameSession ? target ?? state.layout.selectedWorkspaceID : state.layout.selectedWorkspaceID
        let tabID = action == .renameTab ? target ?? state.layout.selectedTabID : state.layout.selectedTabID
        let paneID = action == .renamePane ? target ?? focusedID : focusedID
        let old: String
        switch action {
        case .renameSession: old = state.layout.workspaces.first { $0.id == workspaceID }?.title ?? ""
        case .renameTab: old = state.layout.tabs.first { $0.id == tabID }?.title ?? ""
        default: old = sessions.first { $0.id == paneID }?.title ?? ""
        }
        let alert = NSAlert()
        alert.messageText = ActionCatalog.all.first { $0.action == action }?.title ?? "Rename"
        let field = NSTextField(string: old)
        field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200 else { message = "Use a name between 1 and 200 characters."; return }
        perform { try $0.update { state in
            switch action {
            case .renameSession:
                if let index = state.layout.workspaces.firstIndex(where: { $0.id == workspaceID }) { state.layout.workspaces[index].title = name }
            case .renameTab:
                if let index = state.layout.tabs.firstIndex(where: { $0.id == tabID }) { state.layout.tabs[index].title = name }
            default:
                if let index = state.sessions.firstIndex(where: { $0.id == paneID }) { state.sessions[index].title = name }
            }
        } }
    }

    var commands: [(String, String, () -> Void)] {
        ActionCatalog.all.map { command in (command.title, command.shortcut, { self.execute(command.action) }) }
    }
}
