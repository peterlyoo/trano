import AppKit
import TerminalCore

@MainActor enum TerminalContextCommand: Equatable {
    case action(ActionID)
    case reset
}

@MainActor enum TerminalContextMenu {
    static func make(hasSelection: Bool, canPaste: Bool, supports: @escaping (TerminalContextCommand) -> Bool = { _ in true }, canAct: @escaping () -> Bool,
                     perform: @escaping (TerminalContextCommand) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ id: String, _ title: String, _ command: TerminalContextCommand, enabled: Bool = true) {
            let item = TerminalContextMenuItem(title: title, action: #selector(TerminalContextMenuItem.invoke(_:)), keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(id)
            item.target = item
            item.isEnabled = enabled && supports(command) && canAct()
            item.invokeCommand = { if canAct() && supports(command) { perform(command) } }
            menu.addItem(item)
        }
        add("terminal-copy", "Copy", .action(.copy), enabled: hasSelection)
        add("terminal-paste", "Paste", .action(.paste), enabled: canPaste)
        add("terminal-select-all", "Select All", .action(.selectAll))
        menu.addItem(.separator())
        add("terminal-zoom", "Zoom Pane", .action(.zoom))
        add("terminal-split-right", "Split Right", .action(.splitRight))
        add("terminal-split-down", "Split Down", .action(.splitDown))
        menu.addItem(.separator())
        add("terminal-increase-font", "Zoom In", .action(.increaseFont))
        add("terminal-decrease-font", "Zoom Out", .action(.decreaseFont))
        add("terminal-reset-font", "Reset Font Size", .action(.resetFont))
        add("terminal-reset", "Reset Terminal", .reset)
        menu.addItem(.separator())
        add("terminal-close", "Close Pane", .action(.closePane))
        return menu
    }
}

@MainActor private final class TerminalContextMenuItem: NSMenuItem {
    var invokeCommand: (() -> Void)?
    @objc func invoke(_ sender: Any?) { if isEnabled { invokeCommand?() } }
}

struct TerminalHistoryWheelAccumulator {
    private var remainder = 0.0
    mutating func take(delta: Double, precise: Bool, cellHeight: Double) -> Int {
        guard delta.isFinite, cellHeight.isFinite, cellHeight > 0, delta != 0 else { return 0 }
        if !precise {
            remainder = 0
            let scaled = max(-1000, min(1000, delta.rounded()))
            return scaled == 0 ? (delta > 0 ? 1 : -1) : Int(scaled)
        }
        remainder = max(-1000, min(1000, remainder + delta / cellHeight))
        let whole = Int(remainder.rounded(.towardZero))
        remainder -= Double(whole)
        return whole
    }
    mutating func reset() { remainder = 0 }
}

@MainActor enum TerminalPointerInput {
    static func historyWheelTarget(in window: NSWindow, location: NSPoint, store: AppStore) -> TranoView? {
        guard let hit = hit(in: window, location: location) else { return nil }
        return renderer(under: hit, in: window, store: store)
    }

    static func primaryClickTarget(in window: NSWindow, location: NSPoint, store: AppStore) -> TranoView? {
        guard let hit = hit(in: window, location: location),
              let terminal = renderer(under: hit, in: window, store: store) else { return nil }
        var child: NSView? = hit
        while let view = child, view !== terminal {
            if view is NSControl || view is NSTextView { return nil }
            child = view.superview
        }
        return terminal
    }

    private static func hit(in window: NSWindow, location: NSPoint) -> NSView? {
        guard let content = window.contentView else { return nil }
        return content.hitTest(content.superview?.convert(location, from: nil) ?? location)
    }

    private static func renderer(under hit: NSView, in window: NSWindow, store: AppStore) -> TranoView? {
        store.terminalViews.values.first { view in
            view.window === window && view.store === store && (hit === view || hit.isDescendant(of: view))
        }
    }
}

@MainActor enum TerminalHistoryReplayFocus {
    static func ownsInput(_ terminal: NSView, in window: NSWindow) -> Bool {
        terminal.window === window && window.isKeyWindow && window.firstResponder === terminal
    }
}
