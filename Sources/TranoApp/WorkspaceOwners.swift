import Foundation
import TerminalCore

@MainActor enum WorkspaceOwners {
    private final class Reference {
        weak var store: AppStore?
        let root: URL
        init(_ store: AppStore) {
            self.store = store
            root = store.runtime.root.resolvingSymlinksInPath().standardizedFileURL
        }
    }
    private static var references: [Reference] = []

    static func register(_ store: AppStore) {
        guard store.externalPanePolicy == nil else { return }
        references.removeAll { $0.store == nil }
        references.append(Reference(store))
    }

    static func canonicalRoot(for store: AppStore) -> URL? {
        references.first { $0.store === store }?.root
    }

    static func hasFloatingPane(_ paneIDs: [String], canonicalRoot: URL) -> Bool {
        references.removeAll { $0.store == nil }
        let ids = Set(paneIDs)
        return references.contains { reference in
            reference.root == canonicalRoot && reference.store.map { !ids.isDisjoint(with: $0.floatingPaneIDs) } == true
        }
    }

    private static func stores(root: URL) -> [AppStore] {
        references.removeAll { $0.store == nil }
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        return references.compactMap(\.store).filter {
            $0.runtime.root.resolvingSymlinksInPath().standardizedFileURL == canonical
        }
    }

    static func hasFloatingPane(_ paneIDs: [String], root: URL) -> Bool {
        let ids = Set(paneIDs)
        return stores(root: root).contains { !ids.isDisjoint(with: $0.floatingPaneIDs) }
    }

    static func floatingOwner(paneID: String, root: URL) -> AppStore? {
        stores(root: root).first { $0.floatingPaneIDs.contains(paneID) }
    }

    static func finishTransfer(snapshot: RuntimeState, sessions: [TerminalSession], paneIDs: [String], destinationWorkspaceID: String, root: URL, destination: AppStore?) {
        for store in stores(root: root) where store !== destination && !store.loading {
            store.finishWorkspaceTransfer(snapshot: snapshot, sessions: sessions, paneIDs: paneIDs, destinationWorkspaceID: destinationWorkspaceID)
        }
    }
}
