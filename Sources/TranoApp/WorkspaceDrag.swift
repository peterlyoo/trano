import AppKit
import SwiftUI
import TerminalCore
import UniformTypeIdentifiers

extension UTType {
    static let tranoTab = UTType(exportedAs: "app.trano.tab")
}

@MainActor final class WorkspaceDrag {
    static let shared = WorkspaceDrag()
    private struct Record {
        weak var source: AppStore?
        let root: URL
        let workspaceID: String
        let tabID: String
        let paneID: String?
        let expires: TimeInterval
    }
    private var records: [UUID: Record] = [:]

    func provider(tabID: String, store: AppStore) -> NSItemProvider {
        provider(tabID: tabID, paneID: nil, store: store, type: .tranoTab)
    }

    func provider(paneID: String, store: AppStore) -> NSItemProvider {
        guard let tab = store.state.layout.currentTabs.first(where: { $0.panes.contains(paneID) }) else { return NSItemProvider() }
        return provider(tabID: tab.id, paneID: paneID, store: store, type: .tranoPane)
    }

    func panePayload(paneID: String, store: AppStore) -> Data? {
        guard let tab = store.state.layout.currentTabs.first(where: { $0.panes.contains(paneID) }) else { return nil }
        return payload(tabID: tab.id, paneID: paneID, store: store)
    }

    func tabPayload(tabID: String, store: AppStore) -> Data? {
        payload(tabID: tabID, paneID: nil, store: store)
    }

    func hasActivePayload(in store: AppStore) -> Bool {
        guard canTransfer(store), store.canDragWorkspace, let root = WorkspaceOwners.canonicalRoot(for: store) else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        return records.values.contains { record in
            guard record.root == root, record.expires > now, let source = record.source,
                  canTransfer(source), source.canDragWorkspace, source.preferredWorkspaceID == record.workspaceID,
                  let tab = source.state.layout.tabs.first(where: { $0.id == record.tabID && $0.workspaceID == record.workspaceID }),
                  record.paneID.map(tab.panes.contains) ?? true else { return false }
            return !WorkspaceOwners.hasFloatingPane(tab.panes, canonicalRoot: root)
        }
    }

    private func retire(_ data: Data) {
        guard data.count == 36, let text = String(data: data, encoding: .utf8), let token = UUID(uuidString: text) else { return }
        records.removeValue(forKey: token)
    }

    private func provider(tabID: String, paneID: String?, store: AppStore, type: UTType) -> NSItemProvider {
        let provider = NSItemProvider()
        guard let data = payload(tabID: tabID, paneID: paneID, store: store) else { return provider }
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(data, nil); return nil
        }
        return provider
    }

    private func payload(tabID: String, paneID: String?, store: AppStore) -> Data? {
        let now = ProcessInfo.processInfo.systemUptime
        records = records.filter { $0.value.source != nil && $0.value.expires > now }
        guard canTransfer(store), let workspaceID = store.preferredWorkspaceID,
              let tab = store.state.layout.currentTabs.first(where: { $0.id == tabID }),
              !WorkspaceOwners.hasFloatingPane(tab.panes, root: store.runtime.root), records.count < 128 else { return nil }
        let token = UUID()
        records[token] = Record(source: store, root: store.runtime.root.resolvingSymlinksInPath().standardizedFileURL,
                                workspaceID: workspaceID, tabID: tabID, paneID: paneID, expires: now + 180)
        return Data(token.uuidString.utf8)
    }

    func finishPaneDrag(_ data: Data, from originWindow: NSWindow, at point: NSPoint, operation: NSDragOperation, cancelled: Bool, released: Bool) -> Bool {
        guard operation.isEmpty else { return false }
        guard data.count == 36, let text = String(data: data, encoding: .utf8), let token = UUID(uuidString: text),
              let record = records[token], let paneID = record.paneID else { return false }
        records.removeValue(forKey: token)
        guard !cancelled, released, originWindow.isVisible, !originWindow.frame.contains(point),
              record.expires > ProcessInfo.processInfo.systemUptime,
              let source = record.source, canTransfer(source), source.canDragWorkspace,
              source.preferredWorkspaceID == record.workspaceID,
              source.runtime.root.resolvingSymlinksInPath().standardizedFileURL == record.root,
              let tab = source.state.layout.currentTabs.first(where: { $0.id == record.tabID && $0.panes.contains(paneID) }),
              !WorkspaceOwners.hasFloatingPane(tab.panes, root: record.root),
              let openWindow = source.onPaneDetachedWindow else { return false }
        source.commandKeyHints.cancel()
        let workspaceID = record.workspaceID, tabID = record.tabID, root = record.root
        source.perform(restoringContext: false, validateBeforeWork: { [weak source, weak originWindow] in
            guard let source, let originWindow else { return false }
            return originWindow.isVisible && originWindow.attachedSheet == nil && self.canTransfer(source) && source.canDragWorkspace && source.preferredWorkspaceID == workspaceID &&
                !WorkspaceOwners.hasFloatingPane([paneID], root: root)
        }) { runtime in
            var destination = ""
            try runtime.update { state in
                guard state.layout.workspaces.contains(where: { $0.id == workspaceID && !$0.closed }),
                      state.layout.tabs.contains(where: { $0.id == tabID && $0.workspaceID == workspaceID && $0.panes.contains(paneID) }),
                      state.sessions.contains(where: { $0.id == paneID }) else {
                    throw TerminalError.invalid("The dragged pane is no longer available")
                }
                let title = state.layout.randomWorkspaceTitle()
                destination = state.layout.addWorkspace(title: title)
                try state.layout.transferPane(paneID, from: tabID, sourceWorkspaceID: workspaceID, to: destination, tabID: nil)
            }
            let snapshot = try runtime.state(), sessions = try runtime.list()
            let target = destination
            DispatchQueue.main.async {
                WorkspaceOwners.finishTransfer(snapshot: snapshot, sessions: sessions, paneIDs: [paneID], destinationWorkspaceID: target, root: root, destination: nil)
                openWindow(target, point)
            }
        }
        return true
    }

    func finishTabDrag(_ data: Data, from originWindow: NSWindow, at point: NSPoint, operation: NSDragOperation, cancelled: Bool, released: Bool) -> Bool {
        guard operation.isEmpty else { return false }
        guard data.count == 36, let text = String(data: data, encoding: .utf8), let token = UUID(uuidString: text),
              let record = records[token], record.paneID == nil else { return false }
        records.removeValue(forKey: token)
        guard !cancelled, released, originWindow.isVisible, !originWindow.frame.contains(point),
              record.expires > ProcessInfo.processInfo.systemUptime,
              let source = record.source, canTransfer(source), source.canDragWorkspace,
              source.preferredWorkspaceID == record.workspaceID,
              source.runtime.root.resolvingSymlinksInPath().standardizedFileURL == record.root,
              let tab = source.state.layout.currentTabs.first(where: { $0.id == record.tabID }),
              !WorkspaceOwners.hasFloatingPane(tab.panes, root: record.root),
              let openWindow = source.onPaneDetachedWindow else { return false }
        source.commandKeyHints.cancel()
        let workspaceID = record.workspaceID, tabID = record.tabID, root = record.root
        source.perform(restoringContext: false, validateBeforeWork: { [weak source, weak originWindow] in
            guard let source, let originWindow,
                  let current = source.state.layout.tabs.first(where: { $0.id == tabID && $0.workspaceID == workspaceID }) else { return false }
            return originWindow.isVisible && originWindow.attachedSheet == nil && self.canTransfer(source) && source.canDragWorkspace &&
                source.preferredWorkspaceID == workspaceID && !WorkspaceOwners.hasFloatingPane(current.panes, root: root)
        }) { runtime in
            var destination = "", paneIDs: [String] = []
            try runtime.update { state in
                guard state.layout.workspaces.contains(where: { $0.id == workspaceID && !$0.closed }),
                      let current = state.layout.tabs.first(where: { $0.id == tabID && $0.workspaceID == workspaceID }),
                      current.panes.allSatisfy({ id in state.sessions.contains { $0.id == id } }) else {
                    throw TerminalError.invalid("The dragged tab is no longer available")
                }
                paneIDs = current.panes
                destination = state.layout.addWorkspace(title: state.layout.randomWorkspaceTitle())
                try state.layout.transferTab(tabID, from: workspaceID, to: destination)
            }
            let snapshot = try runtime.state(), sessions = try runtime.list()
            let target = destination, transferred = paneIDs
            DispatchQueue.main.async {
                WorkspaceOwners.finishTransfer(snapshot: snapshot, sessions: sessions, paneIDs: transferred, destinationWorkspaceID: target, root: root, destination: nil)
                openWindow(target, point)
            }
        }
        return true
    }

    func receive(_ data: Data, in destination: AppStore, tabID targetTabID: String?, workspaceID explicitWorkspaceID: String? = nil,
                 expectedWorkspaceID: String? = nil) -> Bool {
        guard data.count == 36, let text = String(data: data, encoding: .utf8), let token = UUID(uuidString: text),
              let record = records[token], record.expires > ProcessInfo.processInfo.systemUptime,
              let source = record.source, canTransfer(source), canTransfer(destination),
              source.preferredWorkspaceID == record.workspaceID,
              source.runtime.root.resolvingSymlinksInPath().standardizedFileURL == record.root,
              destination.runtime.root.resolvingSymlinksInPath().standardizedFileURL == record.root,
              let targetWorkspaceID = targetTabID.flatMap({ id in destination.state.layout.tabs.first { $0.id == id }?.workspaceID }) ?? explicitWorkspaceID ?? destination.preferredWorkspaceID,
              explicitWorkspaceID == nil || explicitWorkspaceID == targetWorkspaceID,
              destination.state.layout.workspaces.contains(where: { $0.id == targetWorkspaceID && !$0.closed }),
              expectedWorkspaceID == nil || expectedWorkspaceID == destination.preferredWorkspaceID,
              let sourceTab = source.state.layout.currentTabs.first(where: { $0.id == record.tabID }),
              record.paneID.map(sourceTab.panes.contains) ?? true,
              !WorkspaceOwners.hasFloatingPane(sourceTab.panes, root: source.runtime.root),
              canTarget(targetTabID, in: destination) else { return false }
        records.removeValue(forKey: token)
        source.commandKeyHints.cancel()
        destination.commandKeyHints.cancel()
        destination.zoomed = false
        let paneIDs = record.paneID.map { [$0] } ?? sourceTab.panes
        let destinationContext = destination.preferredWorkspaceID
        destination.perform(validateBeforeWork: { [weak source, weak destination] in
            if let source, (!self.canTransfer(source) || !source.canDragWorkspace || source.preferredWorkspaceID != record.workspaceID) { return false }
            if let destination, (!self.canTransfer(destination) || !destination.canDragWorkspace || destination.preferredWorkspaceID != destinationContext) { return false }
            return !WorkspaceOwners.hasFloatingPane(paneIDs, root: record.root)
        }) { [weak destination] runtime in
            try runtime.update { state in
                if let paneID = record.paneID {
                    try state.layout.transferPane(paneID, from: record.tabID, sourceWorkspaceID: record.workspaceID,
                                                  to: targetWorkspaceID, tabID: targetTabID)
                } else {
                    try state.layout.transferTab(record.tabID, from: record.workspaceID, to: targetWorkspaceID, before: targetTabID)
                }
            }
            let snapshot = try runtime.state()
            let sessions = try runtime.list()
            DispatchQueue.main.async {
                WorkspaceOwners.finishTransfer(snapshot: snapshot, sessions: sessions, paneIDs: paneIDs, destinationWorkspaceID: targetWorkspaceID, root: record.root, destination: destination)
            }
        }
        return true
    }

    func receive(_ providers: [NSItemProvider], in store: AppStore, tabID: String?, workspaceID targetWorkspaceID: String? = nil) -> Bool {
        guard canTransfer(store), hasActivePayload(in: store), let workspaceID = store.preferredWorkspaceID,
              targetWorkspaceID == nil || store.state.layout.workspaces.contains(where: { $0.id == targetWorkspaceID && !$0.closed }),
              canTarget(tabID, in: store),
              let provider = providers.first(where: {
                  $0.hasItemConformingToTypeIdentifier(UTType.tranoTab.identifier) || $0.hasItemConformingToTypeIdentifier(UTType.tranoPane.identifier)
              }) else { return false }
        let type = provider.hasItemConformingToTypeIdentifier(UTType.tranoTab.identifier) ? UTType.tranoTab : .tranoPane
        _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { [store] data, _ in
            guard let data, data.count == 36 else { return }
            DispatchQueue.main.async {
                if !self.receive(data, in: store, tabID: tabID, workspaceID: targetWorkspaceID, expectedWorkspaceID: workspaceID) {
                    self.retire(data)
                }
            }
        }
        return true
    }

    private func canTransfer(_ store: AppStore) -> Bool {
        !store.loading && store.decisionPaneID == nil && store.followUpPaneID == nil && store.picker == nil &&
        !store.showSettings && !store.showVoice && !store.showRemoteHosts && !store.showAccounts &&
        !store.showExtensions && store.remotePathRequest == nil
    }

    private func canTarget(_ tabID: String?, in store: AppStore) -> Bool {
        guard let tabID else { return true }
        guard let tab = store.state.layout.tabs.first(where: { $0.id == tabID }) else { return false }
        return !WorkspaceOwners.hasFloatingPane(tab.panes, root: store.runtime.root)
    }
}

struct TabStripDropTarget: ViewModifier {
    @ObservedObject var store: AppStore
    @State private var targeted = false
    func body(content: Content) -> some View {
        content.contentShape(Rectangle())
            .overlay { RoundedRectangle(cornerRadius: 4).stroke(targeted ? Color.mint.opacity(0.8) : .clear, lineWidth: 2).allowsHitTesting(false) }
            .onDrop(of: [.tranoTab, .tranoPane], delegate: WorkspaceDropDelegate(store: store, tabID: nil, targeted: $targeted))
    }
}

struct WorkspaceDropDelegate: DropDelegate {
    let store: AppStore
    let tabID: String?
    @Binding var targeted: Bool

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.tranoTab, .tranoPane]) }
    func dropEntered(info: DropInfo) { targeted = true }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        info.hasItemsConforming(to: [.tranoTab, .tranoPane]) ? DropProposal(operation: .move) : nil
    }
    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        return WorkspaceDrag.shared.receive(info.itemProviders(for: [.tranoTab, .tranoPane]), in: store, tabID: tabID)
    }
}
