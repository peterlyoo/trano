import AppKit
import SwiftUI
import TerminalCore

@MainActor private final class TerminalRecentPathChoice: NSObject {
    private let choose: () -> Void
    init(choose: @escaping () -> Void) { self.choose = choose }
    @objc func invoke(_ sender: Any?) { choose() }
}

@MainActor final class TerminalRecentPathAccessory: NSView {
    let popupButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private var owner: () -> TerminalInteractionOwner?
    private var onChoose: (TerminalRecentPath) -> Void
    private var hostID: String?
    private var enabled = false
    private weak var panel: NSOpenPanel?

    init(owner: @escaping () -> TerminalInteractionOwner?, onChoose: @escaping (TerminalRecentPath) -> Void) {
        self.owner = owner
        self.onChoose = onChoose
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 32))
        popupButton.frame = NSRect(x: 0, y: 2, width: 420, height: 28)
        popupButton.autoresizingMask = [.width]
        popupButton.setAccessibilityLabel("Recent paths")
        addSubview(popupButton)
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: 420, height: isHidden ? 0 : 32) }

    func update(history: TerminalPathHistory, hostID: String?, enabled: Bool) {
        update(entries: history.recent(hostID: hostID, enabled: enabled), hostID: hostID, enabled: enabled)
    }

    func update(entries: [TerminalRecentPath], hostID: String?, enabled: Bool) {
        self.hostID = hostID
        self.enabled = enabled
        popupButton.removeAllItems()
        popupButton.addItem(withTitle: "Recent Paths")
        let capturedOwner = owner()
        for entry in enabled ? Array(entries.filter { $0.hostID == hostID }.prefix(20)) : [] {
            let item = NSMenuItem(title: entry.path, action: nil, keyEquivalent: "")
            let choice = TerminalRecentPathChoice { [weak self] in
                guard let self, self.enabled, self.hostID == entry.hostID,
                      let capturedOwner, self.owner() == capturedOwner else { return }
                self.onChoose(entry)
            }
            item.target = choice
            item.action = #selector(TerminalRecentPathChoice.invoke(_:))
            // NSMenuItem's target is weak; retaining it with the item survives redraw.
            item.representedObject = choice
            popupButton.menu?.addItem(item)
        }
        isHidden = !enabled || popupButton.numberOfItems <= 1
        invalidateIntrinsicContentSize()
        refreshAttachment()
    }

    func attach(to panel: NSOpenPanel) {
        if let previous = self.panel, previous !== panel, previous.accessoryView === self { previous.accessoryView = nil }
        self.panel = panel
        refreshAttachment()
    }

    func updateCallbacks(owner: @escaping () -> TerminalInteractionOwner?, onChoose: @escaping (TerminalRecentPath) -> Void) {
        self.owner = owner
        self.onChoose = onChoose
    }

    private func refreshAttachment() {
        guard let panel else { return }
        if isHidden {
            if panel.accessoryView === self { panel.accessoryView = nil }
        } else { panel.accessoryView = self }
    }
}

struct TerminalRecentPathsPicker: NSViewRepresentable {
    let entries: [TerminalRecentPath]
    let hostID: String?
    let enabled: Bool
    let owner: () -> TerminalInteractionOwner?
    let onChoose: (TerminalRecentPath) -> Void

    init(history: TerminalPathHistory, hostID: String?, enabled: Bool, owner: @escaping () -> TerminalInteractionOwner?, onChoose: @escaping (TerminalRecentPath) -> Void) {
        self.init(entries: history.recent(hostID: hostID, enabled: enabled), hostID: hostID, enabled: enabled, owner: owner, onChoose: onChoose)
    }

    init(entries: [TerminalRecentPath], hostID: String?, enabled: Bool, owner: @escaping () -> TerminalInteractionOwner?, onChoose: @escaping (TerminalRecentPath) -> Void) {
        self.entries = entries; self.hostID = hostID; self.enabled = enabled
        self.owner = owner; self.onChoose = onChoose
    }

    func makeNSView(context: Context) -> TerminalRecentPathAccessory {
        let view = TerminalRecentPathAccessory(owner: owner, onChoose: onChoose)
        view.update(entries: entries, hostID: hostID, enabled: enabled)
        return view
    }

    func updateNSView(_ view: TerminalRecentPathAccessory, context: Context) {
        view.updateCallbacks(owner: owner, onChoose: onChoose)
        view.update(entries: entries, hostID: hostID, enabled: enabled)
    }
}
