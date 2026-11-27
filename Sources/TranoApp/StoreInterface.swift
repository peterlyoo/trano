import AppKit
import SwiftUI
import TerminalCore

extension AppStore {
    func setToolbarItem(_ item: InterfaceToolbarItem, visible: Bool) {
        let baseline = interfacePreferences
        var value = baseline
        if visible { value.hiddenToolbarItems.remove(item.rawValue) }
        else { value.hiddenToolbarItems.insert(item.rawValue) }
        saveInterfacePreferences(value, baseline: baseline) { [weak self] error in
            if let error { self?.message = error.localizedDescription }
        }
    }
    func reloadInterfacePreferences() {
        let runtime = runtime
        queue.async { [weak self] in
            do {
                let value = try runtime.interfacePreferences()
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.interfacePreferences.toolbarLayout != value.toolbarLayout && value.toolbarLayout != .above { self.showSessionsSidebar = true }
                    if self.interfacePreferences != value { self.interfacePreferences = value }
                }
            } catch { DispatchQueue.main.async { self?.message = error.localizedDescription } }
        }
    }
    func saveInterfacePreferences(_ value: InterfacePreferences, baseline: InterfacePreferences, completion: @escaping (Error?) -> Void = { _ in }) {
        let runtime = runtime
        queue.async { [weak self] in
            do {
                try runtime.saveInterfacePreferences(value, baseline: baseline)
                let saved = try runtime.interfacePreferences()
                DispatchQueue.main.async { self?.interfacePreferences = saved; completion(nil) }
            } catch { DispatchQueue.main.async { completion(error) } }
        }
    }
    func refreshInterfaceProgramColors() {
        guard interfacePreferences.paddingFill != .off || interfacePreferences.fadeInactivePanes != .neither else { return }
        var next: [String: String] = [:]
        var alternate: Set<String> = []
        for (id, view) in terminalViews {
            if let color = view.nativeBackgroundColor.usingColorSpace(.sRGB) {
                next[id] = String(format: "#%02X%02X%02X", Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
            }
            if view.terminalInputStateSnapshot()?.isAlternateBuffer == true { alternate.insert(id) }
        }
        if next != interfaceProgramBackgrounds { interfaceProgramBackgrounds = next }
        if alternate != interfaceAlternateScreens { interfaceAlternateScreens = alternate }
    }
    func handleInterfaceEvent(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard window.isKeyWindow, event.window === window else { return false }
        var context = InterfaceContext()
        context.isActiveWindow = window.isKeyWindow
        context.inputIsProtected = !safeInterfaceNavigation
        let pane = terminalViews.first { _, view in view.window === window && !view.isHidden && view.bounds.contains(view.convert(event.locationInWindow, from: nil)) }?.key
        if event.type == .mouseMoved, interfacePreferences.canFollowPointer(context), let pane, pane != focusedID {
            let workspace = state.layout.selectedWorkspaceID
            perform(restoringFocus: true, validateBeforeWork: { [weak self, weak window] in
                guard let self, window?.isKeyWindow == true, self.safeInterfaceNavigation,
                      self.interfacePreferences.focusFollowsMouse, self.state.layout.selectedWorkspaceID == workspace,
                      self.selectedTab?.panes.contains(pane) == true else { return false }
                return true
            }) { runtime in
                try runtime.update { state in
                    guard state.layout.selectedWorkspaceID == workspace, state.layout.currentTabs.contains(where: { $0.panes.contains(pane) }) else { return }
                    try state.layout.focusPane(pane)
                }
            }
            return false
        }
        let gesture: InterfaceGesture
        switch event.type {
        case .swipe: gesture = .swipe(delta: event.deltaX, option: event.modifierFlags.contains(.option))
        case .magnify:
            if event.phase.isEmpty || event.phase.contains(.began) || event.phase.contains(.cancelled) { interfaceMagnification = 0; interfaceMagnificationHandled = false }
            guard !context.inputIsProtected, interfacePreferences.trackpadGestures else { interfaceMagnification = 0; interfaceMagnificationHandled = false; return false }
            if interfaceMagnificationHandled { return true }
            interfaceMagnification += event.magnification
            gesture = .magnify(interfaceMagnification)
        default: return false
        }
        guard let action = interfacePreferences.gesture(gesture, context: context) else { return false }
        switch action {
        case .showSidebar: showSessionsSidebar = true
        case .hideSidebar: showSessionsSidebar = false
        case .zoomPane:
            guard let pane, selectedTab?.panes.contains(pane) == true else { return false }
            let workspace = state.layout.selectedWorkspaceID
            perform(restoringFocus: true, validateBeforeWork: { [weak self, weak window] in
                guard let self, window?.isKeyWindow == true, self.safeInterfaceNavigation,
                      self.interfacePreferences.trackpadGestures, self.state.layout.selectedWorkspaceID == workspace,
                      self.selectedTab?.panes.contains(pane) == true else { return false }
                try? self.state.layout.focusPane(pane)
                self.zoomed = true
                return true
            }) { runtime in
                try runtime.update { state in
                    guard state.layout.selectedWorkspaceID == workspace, state.layout.currentTabs.contains(where: { $0.panes.contains(pane) }) else { return }
                    try state.layout.focusPane(pane)
                }
            }
            interfaceMagnificationHandled = true
        case .restorePane: zoomed = false; interfaceMagnificationHandled = true
        }
        return true
    }
}
