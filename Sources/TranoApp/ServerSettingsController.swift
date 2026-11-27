import AppKit
import Combine
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import TerminalCore

struct ServerSettingsReadSnapshot {
    let server: ServerPreferences
    let integrations: IntegrationsPreferences
    let runtime: ServerRuntimeSnapshot
    let tailscale: TailscaleSnapshot?
    let clients: [AuthorizedRemoteClient]
    let availableAgents: [AgentKind]
    var pairing: ServerPairingPresentation?
    var tailscaleError: String?
}
struct ServerPairingPresentation: Identifiable {
    let address: String
    let code: String
    let expiresAt: Date
    var id: String { code }
}
protocol ServerSettingsBackend: AnyObject, Sendable {
    func read() throws -> ServerSettingsReadSnapshot
    func perform(_ action: ServerSettingsNativeAction) throws
    func cancel()
    func saveServer(baseline: ServerPreferences, edited: ServerPreferences) throws
    func saveIntegrations(baseline: IntegrationsPreferences, edited: IntegrationsPreferences) throws
}

private final class TailscaleAuthenticationCapture {
    private let lock = NSLock()
    private var buffer = Data()
    private var seen: Set<URL> = []
    private var active = false
    private var callback: (URL) -> Void = { _ in }
    var onURL: (URL) -> Void {
        get { lock.lock(); defer { lock.unlock() }; return callback }
        set { lock.lock(); callback = newValue; lock.unlock() }
    }
    func reset() { lock.lock(); buffer = Data(); seen = []; active = true; lock.unlock() }
    func cancel() { lock.lock(); active = false; lock.unlock() }
    func receive(_ chunk: Data) {
        lock.lock()
        guard active else { lock.unlock(); return }
        buffer.append(chunk); buffer = Data(buffer.suffix(16384))
        guard let newline = buffer.lastIndex(of: 10) else { lock.unlock(); return }
        let complete = Data(buffer[...newline]); buffer = Data(buffer[buffer.index(after: newline)...])
        let urls = TailscaleStatusEvents.authenticationURLs(in: complete).filter { seen.insert($0).inserted }
        let callback = self.callback; lock.unlock()
        for url in urls { callback(url) }
    }
}

// Reads and writes run on the controller's serial queue; cancellation uses the executor's lock.
final class LiveServerSettingsBackend: ServerSettingsBackend, @unchecked Sendable {
    private let runtime: TerminalRuntime
    private let executor: TailscaleCommandExecuting?
    private let administration: TailscaleAdministration
    private let apiCall: (APIRequest) throws -> APIResponse
    private var pairing: ServerPairingPresentation?
    private let authentication: TailscaleAuthenticationCapture
    var onAuthenticationURL: (URL) -> Void {
        get { authentication.onURL }
        set { authentication.onURL = newValue }
    }
    convenience init(runtime: TerminalRuntime) throws {
        let capture = TailscaleAuthenticationCapture()
        let executor = BoundedTailscaleExecutor.installedExecutable().map { BoundedTailscaleExecutor(executable: $0, timeout: 120, progress: capture.receive) }
        let client = APIClient(path: runtime.root.appendingPathComponent("api.sock").path)
        try self.init(runtime: runtime, executor: executor, apiCall: client.call, authentication: capture)
    }
    convenience init(runtime: TerminalRuntime, executor: TailscaleCommandExecuting?, apiCall: @escaping (APIRequest) throws -> APIResponse) throws {
        try self.init(runtime: runtime, executor: executor, apiCall: apiCall, authentication: TailscaleAuthenticationCapture())
    }
    private init(runtime: TerminalRuntime, executor: TailscaleCommandExecuting?, apiCall: @escaping (APIRequest) throws -> APIResponse, authentication: TailscaleAuthenticationCapture) throws {
        self.runtime = runtime
        self.executor = executor; self.apiCall = apiCall; self.authentication = authentication
        administration = try TailscaleAdministration(root: runtime.root, executor: executor)
    }
    private func call(_ method: String, _ params: [String: JSONValue] = [:]) throws -> JSONValue? {
        let response = try apiCall(APIRequest(method: method, params: params))
        if let error = response.error { throw TerminalError.runtime(error) }; return response.result
    }
    func read() throws -> ServerSettingsReadSnapshot {
        let preferences = try runtime.serverPreferences()
        let response = try apiCall(APIRequest(method: "server.info"))
        var tailscale: TailscaleSnapshot?
        var tailscaleError: String?
        if executor != nil {
            do { tailscale = try administration.refresh() }
            catch {
                tailscaleError = error.localizedDescription
                _ = try? call("server.tailscale.observe", ["failed": .bool(true)])
            }
        }
        if let tailscale { _ = try? call("server.tailscale.observe", ["state": .string(tailscale.backendState), "failed": .bool(false)]) }
        let agents = [AgentKind.claude, .codex].filter { provider in
            let candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/" + provider.rawValue } + ["/opt/homebrew/bin/" + provider.rawValue, "/usr/local/bin/" + provider.rawValue, FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/" + provider.rawValue).path]
            return candidates.contains { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
        }
        let expected = (try? selectedHelper().identity) ?? .process
        return ServerSettingsReadSnapshot(server: preferences, integrations: try runtime.integrationsPreferences(), runtime: ServerRuntimeSnapshot(response: response, expected: expected, root: runtime.root, label: preferences.clientLabel), tailscale: tailscale, clients: try RemotePairingStore(root: runtime.root).clients(), availableAgents: agents, pairing: pairing, tailscaleError: tailscaleError)
    }
    func perform(_ action: ServerSettingsNativeAction) throws {
        do {
            switch action {
            case .refresh: break
            case .refreshServer:
                let selected = try selectedHelper()
                _ = try ServiceHandoff.ensure(runtime: runtime, executable: selected.executable, expected: selected.identity)
                guard case .object(let info)? = try call("server.info"), info["apiVersion"] == .number(1) else { throw TerminalError.invalid("The selected server has an incompatible API version") }
            case .signIn:
                authentication.reset()
                _ = try call("server.tailscale.observe", ["state": .string("NeedsLogin"), "failed": .bool(false)])
                _ = try administration.signIn()
            case .signOut: try administration.signOut()
            case .cancel: administration.cancel()
            case .pair:
                guard let address = try administration.refresh().remoteAddress?.absoluteString,
                      case .object(let result)? = try call("server.pairing.invite"),
                      case .string(let code)? = result["code"], case .number(let expiry)? = result["expiresAt"] else { throw TerminalError.runtime("Remote pairing is not ready") }
                pairing = ServerPairingPresentation(address: address, code: code, expiresAt: Date(timeIntervalSince1970: expiry))
            case .revokeClient(let id): _ = try call("server.clients.revoke", ["id": .string(id)])
            case .setClientRemoteControl(let id, let allowed): _ = try call("server.clients.remote-control", ["id": .string(id), "allowed": .bool(allowed)])
            case .copyAddress, .copyLocalAPI: break
            }
        } catch {
            if [.signIn, .signOut, .pair].contains(action) { _ = try? call("server.tailscale.observe", ["failed": .bool(true)]) }
            throw error
        }
    }
    private func selectedHelper() throws -> (executable: URL, identity: BuildIdentity) {
        let preferences = try DeveloperSettingsStore(root: runtime.root).load()
        let metadata: DeveloperInstallationMetadata
        if preferences.installationLocation == .sourceCheckout {
            metadata = try DeveloperInstallationInspector.sourceBundle(directory: URL(fileURLWithPath: preferences.sourceDirectory))
        } else {
            metadata = try DeveloperInstallationInspector.inspect(bundle: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Trano Service.app"))
        }
        let info = metadata.executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        return (metadata.executable, try BuildIdentity(metadataURL: info))
    }
    func cancel() { authentication.cancel(); administration.cancel() }
    func saveServer(baseline: ServerPreferences, edited: ServerPreferences) throws {
        try edited.validate()
        let store = try SecureSettingsSidecar<ServerPreferences>(root: runtime.root, filename: "server-settings.json")
        let previous = try store.load(), merged = try store.merge(baseline: baseline, edited: edited)
        do {
            if merged.serveOverTailscale && !previous.serveOverTailscale {
                authentication.reset()
                guard case .object(let response)? = try call("server.remote.start"), case .string(let target)? = response["target"], target == administration.target else { throw TerminalError.runtime("Private remote bridge did not start") }
                try administration.enable()
            } else if !merged.serveOverTailscale && previous.serveOverTailscale {
                try administration.disable(); _ = try call("server.remote.stop")
            }
            if merged.preferredHostname != previous.preferredHostname, !merged.preferredHostname.isEmpty { try administration.setHostname(merged.preferredHostname) }
        } catch {
            var restore = previous
            if previous.serveOverTailscale && !merged.serveOverTailscale { restore.serveOverTailscale = false; _ = try? call("server.remote.stop") }
            _ = try? store.update { if $0 == merged { $0 = restore } }
            if !previous.serveOverTailscale { _ = try? call("server.remote.stop") }
            _ = try? call("server.tailscale.observe", ["failed": .bool(true)])
            throw error
        }
    }
    func saveIntegrations(baseline: IntegrationsPreferences, edited: IntegrationsPreferences) throws {
        let store = try SecureSettingsSidecar<IntegrationsPreferences>(root: runtime.root, filename: "integrations-settings.json")
        let previous = try store.load(), merged = try store.merge(baseline: baseline, edited: edited)
        do {
            let installer = try ManagedAgentIntegration(root: runtime.root)
            for provider in [AgentKind.claude, .codex] { try installer.apply(installer.plan(provider: provider, preferences: merged)) }
            for account in try runtime.state().accounts {
                try runtime.applyExtensions(runtime.extensionPlan(accountID: account.id, extensionIDs: runtime.enabledExtensions(accountID: account.id)))
            }
        } catch { _ = try? store.update { if $0 == merged { $0 = previous } }; throw error }
    }
}

@MainActor final class ServerSettingsController: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var snapshot: ServerSettingsReadSnapshot?
    @Published var pairing: ServerPairingPresentation?
    @Published private(set) var authenticationURL: URL?
    private let backend: ServerSettingsBackend
    private let queue = DispatchQueue(label: "trano.server.settings", qos: .userInitiated)
    init(backend: ServerSettingsBackend) {
        self.backend = backend
        (backend as? LiveServerSettingsBackend)?.onAuthenticationURL = { [weak self] url in
            DispatchQueue.main.async {
                guard let self, self.busy else { return }
                self.authenticationURL = url
                NSWorkspace.shared.open(url)
            }
        }
    }
    func perform(_ action: ServerSettingsNativeAction) {
        if action == .cancel { backend.cancel(); return }
        if action == .copyLocalAPI, let value = snapshot?.runtime.localAPIURL { copy(value); return }
        if action == .copyAddress, snapshot?.runtime.remoteReady == true, let value = snapshot?.tailscale?.remoteAddress?.absoluteString { copy(value); return }
        let backend = self.backend
        dispatch({ try backend.perform(action) }, completion: { _ in })
    }
    @discardableResult func saveServer(baseline: ServerPreferences, edited: ServerPreferences, completion: @escaping (Bool) -> Void) -> Bool {
        do { try edited.validate() } catch { self.error = error.localizedDescription; return false }
        let backend = self.backend
        return dispatch({ try backend.saveServer(baseline: baseline, edited: edited) }, completion: completion)
    }
    @discardableResult func saveIntegrations(baseline: IntegrationsPreferences, edited: IntegrationsPreferences, completion: @escaping (Bool) -> Void) -> Bool {
        do { try edited.validate() } catch { self.error = error.localizedDescription; return false }
        let backend = self.backend
        return dispatch({ try backend.saveIntegrations(baseline: baseline, edited: edited) }, completion: completion)
    }
    @discardableResult private func dispatch(_ work: @escaping () throws -> Void, completion: @escaping (Bool) -> Void) -> Bool {
        guard !busy else { return false }; busy = true; error = nil
        let backend = self.backend
        queue.async {
            let result = Result { try work(); return try backend.read() }
            DispatchQueue.main.async {
                switch result {
                case .success(let snapshot): self.snapshot = snapshot; self.pairing = snapshot.pairing; self.error = snapshot.tailscaleError
                case .failure(let error): self.error = error.localizedDescription
                }
                self.busy = false
                completion((try? result.get()) != nil)
            }
        }
        return true
    }
    private func copy(_ string: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(string, forType: .string) }
}

struct ServerSettingsPage: View {
    @Binding var preferences: ServerPreferences
    @ObservedObject var controller: ServerSettingsController
    let root: URL
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let url = controller.authenticationURL { Link("Continue Tailscale Sign-In", destination: url) }
                ServerSettingsSurface(preferences: $preferences, controller: controller, root: root).frame(height: CGFloat(650 + (controller.snapshot?.clients.count ?? 0) * 34))
            }
        }
            .onAppear { controller.perform(.refresh) }
            .popover(item: $controller.pairing) { value in
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pair a Client").font(.headline)
                    if let image = pairingQR(value) { Image(nsImage: image).interpolation(.none).resizable().frame(width: 160, height: 160) }
                    Text(value.address).textSelection(.enabled)
                    Text(value.code).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Text("Expires at \(value.expiresAt.formatted(date: .omitted, time: .standard))").foregroundStyle(.secondary)
                    Button("Copy Pairing Details") {
                        let payload = String(decoding: (try? JSONEncoder().encode(["address": value.address, "code": value.code])) ?? Data(), as: UTF8.self)
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(payload, forType: .string)
                    }
                }.padding(20).frame(width: 420)
            }
    }
    private func pairingQR(_ value: ServerPairingPresentation) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = (try? JSONEncoder().encode(["address": value.address, "code": value.code])) ?? Data()
        guard let output = filter.outputImage, let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 160, height: 160))
    }
}
private struct ServerSettingsSurface: NSViewRepresentable {
    @Binding var preferences: ServerPreferences
    @ObservedObject var controller: ServerSettingsController
    let root: URL
    func makeNSView(context: Context) -> ServerSettingsNativeView { ServerSettingsNativeView(frame: .zero) }
    func updateNSView(_ view: ServerSettingsNativeView, context: Context) {
        view.onChange = { preferences = $0 }; view.onAction = controller.perform
        view.configure(preferences: preferences, snapshot: controller.snapshot?.runtime ?? ServerRuntimeSnapshot(response: nil, expected: .process, root: root, label: preferences.clientLabel), tailscale: controller.snapshot?.tailscale, clients: controller.snapshot?.clients ?? [], toolAvailable: BoundedTailscaleExecutor.installedExecutable() != nil, busy: controller.busy, error: controller.error)
    }
}
struct IntegrationsSettingsPage: NSViewRepresentable {
    @Binding var preferences: IntegrationsPreferences
    @ObservedObject var controller: ServerSettingsController
    func makeNSView(context: Context) -> IntegrationsSettingsNativeView { IntegrationsSettingsNativeView(frame: .zero) }
    func updateNSView(_ view: IntegrationsSettingsNativeView, context: Context) {
        view.onChange = { preferences = $0 }
        view.configure(preferences: preferences, available: controller.snapshot?.availableAgents ?? [], installed: [], busy: controller.busy)
    }
}
