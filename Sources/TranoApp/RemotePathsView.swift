import SwiftUI
import TerminalCore

struct RemotePathRequest: Identifiable {
    let id = UUID()
    let paneID: String
    let hostID: String
    let path: String
    let directoryOnly: Bool
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.directoryOnly ? "Open Remote Directory" : "Insert Remote Path").font(.title2.weight(.semibold))
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
                Button("Cancel") { store.remotePathRequest = nil }.keyboardShortcut(.cancelAction)
                Button(request.directoryOnly ? "Open in New Tab" : "Insert Path", action: choose).disabled(busy || listing == nil).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 620).preferredColorScheme(.dark).onAppear { load(request.path) }
    }

    private func load(_ directory: String) {
        guard !busy else { return }
        let runtime = store.runtime
        busy = true; error = nil; selected = nil
        store.queue.async {
            let result = Result { try runtime.remotePaths(hostID: request.hostID, path: directory) }
            DispatchQueue.main.async {
                busy = false
                switch result {
                case .success(let value): listing = value; path = value.path; query = ""
                case .failure(let failure): error = failure.localizedDescription
                }
            }
        }
    }

    private func choose() {
        guard let path = selected ?? listing?.path else { return }
        do {
            let text = try PathInsertion.text(paths: [path])
            if request.directoryOnly { store.perform { try $0.performAction(.newTab, cwd: path, paneID: request.paneID) } }
            else { store.terminalViews[request.paneID]?.pasteText(text) }
            store.remotePathRequest = nil
        } catch { self.error = error.localizedDescription }
    }
}
