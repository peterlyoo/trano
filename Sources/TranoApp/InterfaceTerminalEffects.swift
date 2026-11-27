import AppKit
import TerminalCore

extension TranoView {
    func applyInterfacePresentation(_ plan: InterfacePresentation) {
        let alpha = backgroundUsesImage ? 0 : CGFloat(plan.paneOpacity)
        if nativeBackgroundColor.alphaComponent != alpha {
            nativeBackgroundColor = nativeBackgroundColor.withAlphaComponent(alpha)
        }
        inactiveBackgroundMultiplier = CGFloat(plan.backgroundMultiplier)
        inactiveContentMultiplier = CGFloat(plan.contentOpacity)
    }
}

extension AppStore {
    func interfacePresentation(for paneID: String, in window: NSWindow?) -> InterfacePresentation {
        var context = InterfaceContext()
        context.backgroundOpacity = interfaceResolvedSettings(for: paneID).appearance.opacity
        context.isActivePane = focusedID == paneID
        context.isActiveWindow = window?.isKeyWindow == true
        context.systemIsDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        context.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        return interfacePreferences.resolve(context)
    }
}
