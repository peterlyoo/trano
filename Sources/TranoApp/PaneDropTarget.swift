import SwiftUI
import TerminalCore
import UniformTypeIdentifiers

extension UTType {
    static let tranoPane = UTType(exportedAs: "app.trano.pane")
}

struct PaneDropTarget: ViewModifier {
    @ObservedObject var store: AppStore
    let tabID: String
    @State private var targeted = false
    func body(content: Content) -> some View {
        content.overlay { RoundedRectangle(cornerRadius: 4).stroke(targeted ? Color.mint.opacity(0.8) : .clear, lineWidth: 2).allowsHitTesting(false) }
            .onDrop(of: [.tranoTab, .tranoPane], delegate: WorkspaceDropDelegate(store: store, tabID: tabID, targeted: $targeted))
            .onChange(of: targeted) { value in
                if value {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        if targeted && store.state.layout.currentTabs.contains(where: { $0.id == tabID }) { store.selectTab(tabID) }
                    }
                }
            }
    }
}
