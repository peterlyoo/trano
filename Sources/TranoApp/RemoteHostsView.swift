import AppKit
import SwiftUI
import TerminalCore

struct RemoteHostsView: View {
    @ObservedObject var store: AppStore
    @State private var name = ""
    @State private var address = ""
    @State private var hostID: String?
    @State private var sessions: [TerminalSession] = []
    @State private var directory = ""
    @State private var busy = false
    @State private var error: String?
    @State private var installation: RemoteInstallationStatus?
    @State private var recovery: [RemoteRecoveryResult] = []
    @State private var replaceConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            ToolPanelHeader("Remote hosts", symbol: "network", onClose: closeRemoteHosts)
            VStack(alignment: .leading, spacing: ToolPanelMetrics.sectionSpacing) {
                Text("Connect using an SSH alias or user@hostname. Remote jobs keep running when you disconnect.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    List(selection: $hostID) {
                        ForEach(store.state.remoteHosts) { host in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(host.name).fontWeight(.medium)
                                Text(host.address).font(.caption).foregroundStyle(.secondary)
                            }.tag(host.id)
                        }
                    }.frame(width: 190).disabled(busy)
                    VStack(alignment: .leading, spacing: 12) {
                        if let hostID {
                            HStack {
                                Text("Remote sessions").fontWeight(.medium)
                                Spacer()
                                Button("Refresh") { load(hostID) }.disabled(busy)
                            }
                            if let installation {
                                HStack(spacing: 8) {
                                    Image(systemName: installation.state == .ready ? "checkmark.circle.fill" : "shippingbox").foregroundStyle(installation.state == .ready ? Color.mint : Color.orange)
                                    Text(installation.message).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    if installation.state == .missing || installation.state == .ready {
                                        Button(installation.state == .ready ? "Update helper" : "Install helper") { install(hostID) }.disabled(busy)
                                    } else if installation.state == .conflict {
                                        Button("Replace with backup…") { replaceConfirmation = true }.disabled(busy)
                                    }
                                }
                            }
                            List(sessions) { session in
                                Button { attach(hostID, session: session) } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(session.title)
                                            Text(session.cwd).font(.caption).foregroundStyle(.secondary)
                                            if let result = recovery.first(where: { $0.sessionID == session.id }), result.status == "needs_attention" || result.status == "failed" {
                                                Text(result.message).font(.caption2).foregroundStyle(.orange)
                                            }
                                        }
                                        Spacer()
                                        Text(session.alive ? session.activity.state.rawValue : "offline").font(.caption).foregroundStyle(session.alive ? activityColor(session.activity.state) : Color.secondary)
                                    }.padding(.vertical, 4)
                                }.buttonStyle(.plain).disabled(busy)
                            }
                            HStack {
                                TextField("Directory (blank for home)", text: $directory)
                                Button("Restore sessions") { restore(hostID) }.disabled(busy || installation?.state != .ready)
                                Button("New terminal") { create(hostID) }.disabled(busy || installation?.state != .ready)
                            }
                        } else {
                            ContentUnavailableView("Select a host", systemImage: "server.rack", description: Text("Add a Linux host, then install its helper directly over SSH."))
                        }
                    }
                }.frame(height: 270)
                Divider()
                HStack {
                    TextField("Name (optional)", text: $name).frame(width: 160)
                    TextField("SSH alias or user@hostname", text: $address)
                    Button("Add Remote Host", action: addHost)
                        .disabled(busy || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if busy { HStack { ProgressView().controlSize(.small); Text("Connecting…").font(.caption).foregroundStyle(.secondary) } }
                if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled).lineLimit(4) }
            }.padding(ToolPanelMetrics.contentInset)
        }.frame(width: 760).toolPanelSurface(store.toolPanelTheme)
            .dismissOnOutsideClick("remote-hosts-sheet", perform: closeRemoteHosts)
            .onChange(of: hostID) { _, value in sessions = []; recovery = []; installation = nil; if let value { load(value) } }
            .confirmationDialog("Replace the existing remote helper?", isPresented: $replaceConfirmation) {
                Button("Replace and keep a backup") { if let hostID { install(hostID, force: true) } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Trano will save a backup before replacing the unmanaged executable. Existing terminal jobs stay running.") }
    }

    private func closeRemoteHosts() { store.showRemoteHosts = false }

    private func addHost() {
        let ssh = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true; error = nil
        store.queue.async {
            do {
                let host = try store.runtime.addRemoteHost(name: label.isEmpty ? ssh : label, address: ssh)
                DispatchQueue.main.async {
                    busy = false; name = ""; address = ""; store.refresh(); hostID = host.id
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { busy = false; self.error = message }
            }
        }
    }

    private func load(_ id: String) {
        guard !busy else { return }
        busy = true; error = nil
        let runtime = store.runtime
        store.queue.async {
            do {
                let status = try runtime.checkRemoteInstallation(hostID: id)
                let result = status.state == .ready ? try runtime.remoteSessions(hostID: id) : []
                let restored = status.state == .ready ? (try? RemoteClient(host: runtime.remoteHost(id)).recoveryResults()) ?? [] : []
                DispatchQueue.main.async { if hostID == id { installation = status; sessions = result; recovery = restored }; busy = false }
            } catch { let message = error.localizedDescription; DispatchQueue.main.async { self.error = message; busy = false } }
        }
    }

    private func install(_ id: String, force: Bool = false) {
        guard !busy else { return }
        busy = true; error = nil
        let runtime = store.runtime
        store.queue.async {
            do {
                let status = try runtime.installRemoteHelper(hostID: id, force: force)
                let result = try runtime.remoteSessions(hostID: id)
                DispatchQueue.main.async { if hostID == id { installation = status; sessions = result }; busy = false }
            } catch { let message = error.localizedDescription; DispatchQueue.main.async { self.error = message; busy = false } }
        }
    }

    private func restore(_ id: String) {
        guard !busy else { return }
        busy = true; error = nil
        let runtime = store.runtime
        store.queue.async {
            do {
                let results = try runtime.recoverRemoteSessions(hostID: id)
                let listed = try runtime.remoteSessions(hostID: id)
                DispatchQueue.main.async { if hostID == id { recovery = results; sessions = listed }; busy = false }
            } catch { let message = error.localizedDescription; DispatchQueue.main.async { self.error = message; busy = false } }
        }
    }

    private func attach(_ host: String, session: TerminalSession? = nil) {
        guard !busy else { return }
        busy = true; error = nil
        let runtime = store.runtime, cwd = directory
        store.queue.async {
            do {
                if let session, !session.alive { _ = try runtime.recoverRemoteSessions(hostID: host, sessionID: session.id) }
                let pane = try session.map { try runtime.attachRemoteSession(hostID: host, remote: $0) } ?? runtime.createRemoteSession(hostID: host, cwd: cwd)
                DispatchQueue.main.async { store.attach(pane.id); store.showRemoteHosts = false; busy = false }
            } catch { let message = error.localizedDescription; DispatchQueue.main.async { self.error = message; busy = false } }
        }
    }
    private func create(_ id: String) { attach(id) }
}
