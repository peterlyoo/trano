import SwiftUI
import TerminalCore

struct RemotePathRequest: Identifiable {
    let id = UUID()
    let paneID: String
    let hostID: String
    let path: String
    let directoryOnly: Bool
    let owner: TerminalInteractionOwner
}

struct RemotePathsView: View {
    @ObservedObject var store: AppStore
    let request: RemotePathRequest
    @State private var path = ""
    @State private var listing: RemotePathListing?
    @State private var selected: String?
    @State private var query = ""
    @State private var busy = false
    @State private var error: String?
    @State private var recentPaths: [TerminalRecentPath] = []

    var body: some View {
        VStack(spacing: 0) {
            ToolPanelHeader(request.directoryOnly ? "Open Remote Directory" : "Insert Remote Path", closeLabel: "Cancel", onClose: cancelRemotePath)
            VStack(alignment: .leading, spacing: ToolPanelMetrics.sectionSpacing) {
                TerminalRecentPathsPicker(entries: recentPaths, hostID: request.hostID,
                    enabled: store.terminalPreferences.showRecentPaths,
                    owner: { store.terminalViews[request.paneID]?.interactionOwner() },
                    onChoose: { entry in load(entry.path) })
                HStack {
                    Button { if let parent = listing?.parent { load(parent) } } label: { Image(systemName: "arrow.up") }.disabled(busy || listing == nil)
                    TextField("Remote path", text: $path).onSubmit { load(path) }
                    Button("Go") { load(path) }.disabled(busy)
                }
                TextField("Filter files", text: $query)
                List(selection: $selected) {
                    ForEach(listing?.entries.filter { (!request.directoryOnly || $0.directory) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) } ?? []) { entry in
                        HStack {
                            Image(systemName: entry.directory ? "folder" : "doc").foregroundStyle(.secondary)
                            Text(entry.name)
                            Spacer()
                            if entry.directory { Button { load(entry.path) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless).help("Open folder") }
                        }.tag(entry.path).padding(.vertical, 3)
                    }
                }.frame(height: 300)
                if listing?.truncated == true { Text("Showing the first 2,000 entries.").font(.caption).foregroundStyle(.secondary) }
                if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                HStack {
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Cancel", action: cancelRemotePath).keyboardShortcut(.cancelAction)
                    Button(request.directoryOnly ? "Open in New Tab" : "Insert Path", action: choose).disabled(busy || listing == nil).keyboardShortcut(.defaultAction)
                }
            }.padding(ToolPanelMetrics.contentInset)
        }.frame(width: 620).toolPanelSurface(store.toolPanelTheme)
            .dismissOnOutsideClick("remote-paths-sheet-" + request.id.uuidString, perform: cancelRemotePath)
            .onAppear {
            load(request.path)
            store.loadTerminalRecentPaths(hostID: request.hostID, owner: request.owner) { result in
                guard store.remotePathRequest?.id == request.id,
                      store.terminalViews[request.paneID]?.interactionOwner() == request.owner else { return }
                if case .success(let entries) = result { recentPaths = entries }
            }
        }
    }

    private func cancelRemotePath() { store.remotePathRequest = nil }

    private func load(_ directory: String) {
        guard !busy, store.remotePathRequest?.id == request.id,
              store.terminalViews[request.paneID]?.interactionOwner() == request.owner,
              let lease = store.terminalViews[request.paneID]?.interactionLease(for: request.owner) else { return }
        let runtime = store.runtime
        busy = true; error = nil; selected = nil
        store.queue.async {
            let result = Result {
                guard lease.isValid else { throw TerminalError.invalid("Terminal owner changed") }
                return try runtime.remotePaths(hostID: request.hostID, path: directory)
            }
            DispatchQueue.main.async {
                busy = false
                guard store.remotePathRequest?.id == request.id,
                      store.terminalViews[request.paneID]?.interactionOwner() == request.owner else { return }
                switch result {
                case .success(let value): listing = value; path = value.path; query = ""
                case .failure(let failure): error = failure.localizedDescription
                }
            }
        }
    }

    private func choose() {
        guard store.remotePathRequest?.id == request.id,
              store.terminalViews[request.paneID]?.interactionOwner() == request.owner,
              let lease = store.terminalViews[request.paneID]?.interactionLease(for: request.owner),
              let path = selected ?? listing?.path else { return }
        do {
            let text = try PathInsertion.text(paths: [path])
            if request.directoryOnly {
                store.perform(validateBeforeWork: { lease.isValid }) { runtime in
                    guard lease.isValid, try runtime.state().sessions.contains(where: { $0.id == request.paneID && $0.pid == lease.sessionPID && $0.remote?.hostID == request.hostID }) else { throw TerminalError.invalid("Terminal session changed") }
                    try runtime.performAction(.newTab, cwd: path, paneID: request.paneID)
                    try runtime.recordTerminalPath(path, hostID: request.hostID)
                }
            } else {
                store.terminalViews[request.paneID]?.pasteText(text)
                store.recordTerminalPaths([path], hostID: request.hostID, owner: request.owner)
            }
            store.remotePathRequest = nil
        } catch { self.error = error.localizedDescription }
    }
}
