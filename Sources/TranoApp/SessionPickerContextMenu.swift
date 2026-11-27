import AppKit
import TerminalCore

extension AppStore {
    private func workspacePickerAllowsActions(in window: NSWindow?) -> Bool {
        picker == .sessions && !loading && decisionPaneID == nil && followUpPaneID == nil && !showSettings &&
        !showVoice && !showRemoteHosts && !showAccounts && !showExtensions && remotePathRequest == nil && message == nil &&
        NSApp.modalWindow == nil && window?.attachedSheet == nil &&
        (window?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true
    }

    func workspacePickerContextMenu(workspaceID: String, sourceWindow: NSWindow? = nil) -> NSMenu {
        let target = state.layout.workspaces.first { $0.id == workspaceID }
        let open = state.layout.workspaces.filter { !$0.closed }.map(\.id)
        let position = open.firstIndex(of: workspaceID)
        let window = sourceWindow ?? focusedID.flatMap { terminalViews[$0]?.window }
        let ownsWindow = window != nil
        weak var owner = window
        let allowed = workspacePickerAllowsActions(in: window) && target != nil
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ id: String, _ title: String, image: String? = nil, enabled: Bool = true,
                  run: @escaping (AppStore, NSWindow?) -> Void) -> NSMenuItem {
            let value = WorkspacePickerMenuItem(title: title, action: #selector(WorkspacePickerMenuItem.invoke(_:)), keyEquivalent: "")
            value.identifier = NSUserInterfaceItemIdentifier(id)
            value.target = value
            value.isEnabled = allowed && enabled
            if let image { value.image = NSImage(systemSymbolName: image, accessibilityDescription: nil) }
            value.onInvoke = { [weak self] in
                guard let self, self.workspacePickerAllowsActions(in: owner),
                      !ownsWindow || owner?.isVisible == true,
                      self.state.layout.workspaces.contains(where: { $0.id == workspaceID }) else { return }
                run(self, owner)
            }
            return value
        }
        menu.addItem(item("picker-rename-session", "Rename Session…") { store, owner in
            store.rename(.renameSession, target: workspaceID, onCommit: { [weak store, weak owner] name in
                store?.commitPickerWorkspaceRename(workspaceID, name: name, sourceWindow: owner)
            })
        })
        menu.addItem(item("picker-close-session", "Close Session", enabled: target?.closed == false) { store, owner in
            store.performWorkspacePickerAction(workspaceID, sourceWindow: owner) { runtime in
                try runtime.update { $0.layout.closeWorkspace(workspaceID) }
            }
        })
        menu.addItem(.separator())
        for (delta, id, title, image) in [(-1, "picker-move-session-up", "Move Up", "arrow.up"), (1, "picker-move-session-down", "Move Down", "arrow.down")] {
            let enabled = position.map { (0..<open.count).contains($0 + delta) } ?? false
            menu.addItem(item(id, title, image: image, enabled: enabled) { store, owner in
                store.performWorkspacePickerAction(workspaceID, sourceWindow: owner) { runtime in
                    try runtime.update { try $0.layout.reorderWorkspace(workspaceID, delta: delta) }
                }
            })
        }
        return menu
    }

    func commitPickerWorkspaceRename(_ id: String, name: String, sourceWindow: NSWindow? = nil) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200, name.rangeOfCharacter(from: .controlCharacters) == nil else { return }
        performWorkspacePickerAction(id, allowClosed: true, sourceWindow: sourceWindow) { runtime in
            try runtime.update { state in
                if let index = state.layout.workspaces.firstIndex(where: { $0.id == id }) { state.layout.workspaces[index].title = name }
            }
        }
    }

    private func performWorkspacePickerAction(_ id: String, allowClosed: Bool = false, sourceWindow: NSWindow?,
                                              _ work: @escaping (TerminalRuntime) throws -> Void) {
        let window = sourceWindow ?? focusedID.flatMap { terminalViews[$0]?.window }
        guard workspacePickerAllowsActions(in: window) else { return }
        let ownsWindow = window != nil
        weak var owner = window
        commandKeyHints.cancel()
        perform(restoringContext: false, validateBeforeWork: { [weak self] in
            guard let self else { return false }
            return self.workspacePickerAllowsActions(in: owner) && (!ownsWindow || owner?.isVisible == true)
        }) { runtime in
            guard let target = try runtime.state().layout.workspaces.first(where: { $0.id == id }),
                  allowClosed || !target.closed else { return }
            try work(runtime)
        }
    }
}

private final class WorkspacePickerMenuItem: NSMenuItem {
    var onInvoke: (() -> Void)?
    @objc func invoke(_ sender: Any?) { if isEnabled { onInvoke?() } }
}
