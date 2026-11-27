import AppKit
import SwiftUI
import TerminalCore

struct InterfaceWorkspaceLayout<Header: View, VerticalHeader: View, Sidebar: View, Content: View>: View {
    let plan: InterfacePresentation
    let sidebarVisible: Bool
    @ViewBuilder var header: () -> Header
    @ViewBuilder var verticalHeader: () -> VerticalHeader
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var content: () -> Content
    var body: some View {
        Group {
            if plan.toolbarLayout == .above {
                VStack(spacing: 0) {
                    if plan.reservedHeaderHeight > 0 {
                        header().frame(height: plan.headerHeight)
                        separator.frame(height: 1)
                    }
                    HStack(spacing: 0) {
                        if sidebarVisible { sidebar().frame(width: plan.sidebarWidth); separator.frame(width: 1) }
                        content()
                    }
                }
                .overlay(alignment: .top) {
                    if plan.toolbarOverlaysContent && plan.toolbarVisible { header().frame(height: plan.headerHeight).shadow(radius: 8).zIndex(5) }
                }
            } else {
                HStack(spacing: 0) {
                    if plan.toolbarLayout == .left && sidebarVisible { verticalSidebar; separator.frame(width: 1) }
                    content()
                    if plan.toolbarLayout == .right && sidebarVisible { separator.frame(width: 1); verticalSidebar }
                }
            }
        }
        .animation(plan.swiftUIAnimation, value: sidebarVisible)
    }
    private var verticalSidebar: some View {
        VStack(spacing: 0) {
            if plan.reservedHeaderHeight > 0 { verticalHeader() }
            sidebar()
        }
        .overlay(alignment: .top) {
            if plan.toolbarOverlaysContent && plan.toolbarVisible { verticalHeader().shadow(radius: 8) }
        }
        .frame(width: plan.sidebarWidth)
    }
    private var separator: some View {
        Color(nsColor: NSColor(hex: plan.chromeBackground)).overlay(Color.primary.opacity(0.08)).compositingGroup().opacity(plan.chromeOpacity)
    }
}

struct InterfaceSidebarResize: ViewModifier {
    @ObservedObject var store: AppStore
    let window: NSWindow?
    @State private var original: InterfacePreferences?
    func body(content: Content) -> some View {
        content.overlay(alignment: store.interfacePreferences.toolbarLayout == .right ? .leading : .trailing) {
            Color.clear.frame(width: 5).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                    guard store.safeInterfaceNavigation else { return }
                    if original == nil { original = store.interfacePreferences }
                    guard let original else { return }
                    let direction: Double = store.interfacePreferences.toolbarLayout == .right ? -1 : 1
                    let previous = store.interfacePreferences.sidebarWidth
                    let next = min(480, max(140, original.sidebarWidth + value.translation.width * direction))
                    store.interfacePreferences.sidebarWidth = next
                    if let window { InterfaceWindowEffects.resizeSidebar(window, preferences: store.interfacePreferences, previous: previous, next: next) }
                }.onEnded { _ in
                    guard let baseline = original else { return }
                    original = nil
                    store.saveInterfacePreferences(store.interfacePreferences, baseline: baseline)
                })
                .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
        }
    }
}
