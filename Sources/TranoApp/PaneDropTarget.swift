import SwiftUI
import TerminalCore
import UniformTypeIdentifiers

extension UTType {
    static let tranoPane = UTType(exportedAs: "app.trano.pane")
}

enum PaneDrag {
    static func provider(_ id: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.tranoPane.identifier, visibility: .ownProcess) { completion in
            completion(Data(id.utf8), nil); return nil
        }
        return provider
    }
}

struct PaneDropTarget: ViewModifier {
    @ObservedObject var store: AppStore
    let tabID: String
    @State private var targeted = false
    func body(content: Content) -> some View {
        content.overlay { RoundedRectangle(cornerRadius: 4).stroke(targeted ? Color.mint.opacity(0.8) : .clear, lineWidth: 2).allowsHitTesting(false) }
            .onDrop(of: [.tranoPane], isTargeted: $targeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.tranoPane.identifier) { data, _ in
                    guard let data, data.count <= 64, let id = String(data: data, encoding: .utf8), UUID(uuidString: id) != nil else { return }
                    DispatchQueue.main.async {
                        guard store.sessions.contains(where: { $0.id == id }) else { return }
                        store.move(id, to: tabID)
                    }
                }
                return true
            }
            .onChange(of: targeted) { value in
                if value {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        if targeted { store.selectTab(tabID) }
                    }
                }
            }
    }
}
