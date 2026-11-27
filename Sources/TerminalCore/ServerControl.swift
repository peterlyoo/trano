import Foundation

public enum ServerCompatibilityState: String, Equatable { case compatible, restartRequired, unsupported, unavailable }
public struct ServerRuntimeSnapshot: Equatable {
    public let running: Bool
    public let compatibility: ServerCompatibilityState
    public let identity: BuildIdentity?
    public let pid: Int32?
    public let uptime: TimeInterval?
    public let localAPIURL: String
    public let label: String
    public let remoteReady: Bool
    public init(response: APIResponse?, expected: BuildIdentity, root: URL, label: String) {
        self.label = label
        var endpoint = URLComponents(); endpoint.scheme = "unix"; endpoint.host = ""; endpoint.path = root.appendingPathComponent("api.sock").path
        localAPIURL = endpoint.string ?? "unix://" + root.appendingPathComponent("api.sock").path
        guard let response, response.error == nil, case .object(let info)? = response.result,
              let version = info["version"]?.text, let number = info["buildNumber"]?.text,
              let buildID = info["buildID"]?.text, case .number(let rawPID)? = info["pid"],
              rawPID >= 2, rawPID <= Double(Int32.max), rawPID.rounded() == rawPID else {
            running = false; compatibility = .unavailable; identity = nil; pid = nil; uptime = nil; remoteReady = false
            return
        }
        running = true; pid = Int32(rawPID)
        remoteReady = info["remoteReady"] == .bool(true)
        identity = BuildIdentity(info: ["CFBundleShortVersionString": version, "CFBundleVersion": number, "TranoBuildID": buildID])
        if case .number(let seconds)? = info["uptime"], seconds.isFinite, seconds >= 0 { uptime = seconds } else { uptime = nil }
        if info["apiVersion"] != .number(1) { compatibility = .unsupported }
        else if identity == expected { compatibility = .compatible }
        else { compatibility = .restartRequired }
    }
}

public struct TailscaleCommandResult {
    public let exitCode: Int32
    public let output: Data
    public init(exitCode: Int32, output: Data) { self.exitCode = exitCode; self.output = output }
}
public protocol TailscaleCommandExecuting {
    func run(arguments: [String]) throws -> TailscaleCommandResult
    func cancel()
}

private struct TailscaleServeReceipt: SettingsPreferences {
    var target: String?
    init() {}
    func validate() throws {
        guard target == nil || target!.hasPrefix("unix:/") && !target!.contains("\0") && !target!.contains("\n") && target!.utf8.count <= 512 else { throw TerminalError.invalid("Invalid Tailscale Serve ownership receipt") }
    }
}

public final class TailscaleAdministration {
    private let executor: TailscaleCommandExecuting?
    private let receipt: SecureSettingsSidecar<TailscaleServeReceipt>
    private let lock = NSLock()
    public let target: String
    public init(root: URL, executor: TailscaleCommandExecuting?) throws {
        self.executor = executor
        target = "unix:" + root.appendingPathComponent("r.sock").path
        receipt = try SecureSettingsSidecar(root: root, filename: "tailscale-serve.json")
    }
    public func refresh() throws -> TailscaleSnapshot { try TailscaleSnapshot(data: invoke(TailscaleCommand.status.arguments).output) }

    public func enable() throws {
        lock.lock(); defer { lock.unlock() }
        let previous = try receipt.load().target
        let config = try configuration()
        let current = try target(config)
        guard current == nil || current == previous else { throw TerminalError.invalid("The /trano Tailscale Serve path is already owned by another service") }
        let expected = target
        _ = try receipt.update { $0.target = expected }
        _ = try invoke(TailscaleCommand.serve(target: expected).arguments)
        guard try target(configuration()) == expected else { throw TerminalError.runtime("Tailscale has not published the remote endpoint. Complete HTTPS or device approval, then retry.") }
        _ = try receipt.update { $0.target = expected }
    }

    public func disable() throws {
        lock.lock(); defer { lock.unlock() }
        let previous = try receipt.load().target
        let current = try target(configuration())
        guard current == nil || current == previous else { throw TerminalError.invalid("Refusing to change an unmanaged Tailscale Serve path") }
        if current != nil {
            _ = try invoke(TailscaleCommand.stopServing.arguments)
            guard try target(configuration()) == nil else { throw TerminalError.runtime("Tailscale did not remove the owned remote endpoint") }
        }
        _ = try receipt.update { $0.target = nil }
    }

    public func signIn() throws -> TailscaleCommandResult { try invoke(TailscaleCommand.signIn.arguments) }
    public func signOut() throws { _ = try invoke(TailscaleCommand.signOut.arguments) }
    public func setHostname(_ value: String) throws {
        var preferences = ServerPreferences(); preferences.preferredHostname = value
        try preferences.validate()
        guard !value.isEmpty else { throw TerminalError.invalid("Choose a preferred hostname") }
        _ = try invoke(TailscaleCommand.setHostname(value).arguments)
    }
    public func cancel() { executor?.cancel() }

    private func invoke(_ arguments: [String]) throws -> TailscaleCommandResult {
        guard let executor else { throw TerminalError.runtime("Install the Tailscale CLI to enable remote serving") }
        let result = try executor.run(arguments: arguments)
        guard result.output.count <= 1_048_576 else { throw TerminalError.runtime("Tailscale output exceeded its limit") }
        guard result.exitCode == 0 else { throw TerminalError.runtime("Tailscale command failed (exit \(result.exitCode)): " + String(decoding: result.output.prefix(4096), as: UTF8.self)) }
        return result
    }
    private func configuration() throws -> JSONValue {
        let data = try invoke(["serve", "status", "--json"]).output
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else { throw TerminalError.invalid("Tailscale returned an invalid Serve configuration") }
        return .object(object)
    }
    private func target(_ config: JSONValue) throws -> String? {
        if case .object(let funnel)? = config["AllowFunnel"], funnel.contains(where: { $0.key.hasSuffix(":443") && $0.value == .bool(true) }) {
            throw TerminalError.invalid("HTTPS port 443 is used by Tailscale Funnel; Trano requires a private Serve endpoint")
        }
        if case .object(let tcp)? = config["TCP"], let entry = tcp["443"], entry["HTTPS"] != .bool(true) {
            throw TerminalError.invalid("Tailscale port 443 is already used by a different protocol")
        }
        if case .object(let foreground)? = config["Foreground"], !foreground.isEmpty {
            throw TerminalError.invalid("A foreground Tailscale Serve configuration is active. Stop it before enabling Trano remote access.")
        }
        var result: String?
        if case .object(let servers)? = config["Web"] {
            for (host, server) in servers where host.hasSuffix(":443") {
                guard case .object(let handlers)? = server["Handlers"] else { throw TerminalError.invalid("Tailscale returned invalid web handlers") }
                guard !handlers.keys.contains(where: {
                    let decoded = $0.removingPercentEncoding ?? $0
                    return decoded.hasPrefix("/trano/") && decoded != "/trano/" || decoded != $0 && (decoded == "/trano" || decoded == "/trano/")
                }) else { throw TerminalError.invalid("A more specific Tailscale handler overlaps Trano's reserved path") }
                for path in ["/trano", "/trano/"] {
                    if let handler = handlers[path] {
                        guard result == nil, let proxy = handler["Proxy"]?.text,
                              ["Redirect", "Path", "Text"].allSatisfy({ handler[$0] == nil || handler[$0] == .string("") }) else { throw TerminalError.invalid("The /trano path is used by another Tailscale handler") }
                        result = proxy
                    }
                }
            }
        }
        return result
    }
}

public final class RemoteHTTPGateway {
    private let pairing: RemotePairingStore
    private let preferences: () throws -> ServerPreferences
    private let ownLogin: () -> String?
    private let route: (APIRequest) -> APIResponse
    public init(pairing: RemotePairingStore, preferences: @escaping () throws -> ServerPreferences, ownLogin: @escaping () -> String?, route: @escaping (APIRequest) -> APIResponse) {
        self.pairing = pairing; self.preferences = preferences; self.ownLogin = ownLogin; self.route = route
    }

    public func respond(_ request: RemoteHTTPRequest, proxy: TrustedTailscaleProxy? = nil) -> (status: Int, headers: [String: String], body: Data) {
        var headers = ["Cache-Control": "no-store", "Content-Type": "application/json", "X-Content-Type-Options": "nosniff"]
        func reject(_ status: Int) -> (status: Int, headers: [String: String], body: Data) {
            (status, headers, Data("{\"error\":\"Remote request rejected\"}\n".utf8))
        }
        guard proxy != nil else { return reject(403) }
        do {
            let preferences = try self.preferences(); try preferences.validate()
            guard preferences.serveOverTailscale else { return reject(503) }
            if let origin = request.headers["origin"] {
                guard try preferences.allowedOrigins.contains(where: { try RemoteOriginPattern($0).matches(origin) }) else { return reject(403) }
                headers["Access-Control-Allow-Origin"] = origin; headers["Vary"] = "Origin"
            }
            if request.method == "OPTIONS" {
                let requested = (request.headers["access-control-request-headers"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                guard request.headers["origin"] != nil, request.headers["access-control-request-method"] == "POST",
                      requested.allSatisfy({ ["authorization", "content-type"].contains($0) }) else { return reject(403) }
                headers["Access-Control-Allow-Methods"] = "POST"
                headers["Access-Control-Allow-Headers"] = "Authorization, Content-Type"
                return (204, headers, Data())
            }
            guard request.method == "POST" else { return reject(405) }
            if request.path == "/pair" {
                guard isJSON(request.headers["content-type"]) else { return reject(415) }
                let object = try JSONDecoder().decode([String: String].self, from: request.body)
                guard let code = object["code"], let label = object["label"] else { return reject(400) }
                let result = try pairing.pair(code: code, label: label, login: request.headers["tailscale-user-login"], ownLogin: ownLogin(), preferences: preferences)
                let payload: [String: JSONValue] = ["token": .string(result.token), "client": try .encoded(result.client)]
                return (200, headers, try JSONEncoder().encode(payload))
            }
            guard request.path == "/api" else { return reject(404) }
            guard let authorization = request.headers["authorization"], authorization.hasPrefix("Bearer ") else { return reject(401) }
            guard isJSON(request.headers["content-type"]) else { return reject(415) }
            let message = try JSONDecoder().decode(APIRequest.self, from: request.body)
            guard message.apiVersion == 1 else { return reject(400) }
            do {
                _ = try pairing.authorize(token: String(authorization.dropFirst(7)), origin: request.headers["origin"], login: request.headers["tailscale-user-login"], ownLogin: ownLogin(), method: message.method, preferences: preferences)
            } catch { return reject(403) }
            let response = route(message)
            return (response.error == nil ? 200 : 400, headers, try JSONEncoder().encode(response))
        } catch { return reject(400) }
    }
    private func isJSON(_ value: String?) -> Bool {
        value?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json"
    }
}

extension TerminalRuntime {
    public func serverPreferences() throws -> ServerPreferences { try SecureSettingsSidecar<ServerPreferences>(root: root, filename: "server-settings.json").load() }
    public func integrationsPreferences() throws -> IntegrationsPreferences { try SecureSettingsSidecar<IntegrationsPreferences>(root: root, filename: "integrations-settings.json").load() }

    public func nameAgentSession(paneID: String, generation: String, expectedTitle: String, title: String, originPID: Int32?, verifyAncestry: ((Int32, Int32, AgentKind) -> Bool)? = nil) throws {
        guard let title = try WorkspaceLayout.normalizedSessionTitle(title), let originPID else { throw TerminalError.invalid("Agent session naming requires a verified caller and a title") }
        try transaction {
            guard try integrationsPreferences().permitsSessionNaming else { throw TerminalError.invalid("Agent session naming is disabled") }
            let state = try state()
            guard let launch = state.agentLaunches.first(where: { $0.paneID == paneID && $0.id == generation && $0.lifecycle == .active }),
                  let providerPID = launch.providerPID, providerPID > 1,
                  let pane = state.sessions.first(where: { $0.id == paneID }), pane.alive, pane.remote == nil,
                  let workspaceID = state.layout.tabs.first(where: { $0.panes.contains(paneID) })?.workspaceID,
                  let workspace = state.layout.workspaces.first(where: { $0.id == workspaceID && !$0.closed }), workspace.title == expectedTitle else {
                throw TerminalError.invalid("Agent session identity or title changed")
            }
            let verified = verifyAncestry?(originPID, providerPID, launch.provider) ?? ProcessIdentity.isRootHook(originPID: originPID, providerPID: providerPID, provider: launch.provider)
            guard verified else { throw TerminalError.invalid("Agent caller ancestry could not be verified") }
            try update { current in
                guard let index = current.layout.workspaces.firstIndex(where: { $0.id == workspaceID && !$0.closed && $0.title == expectedTitle }) else { throw TerminalError.invalid("Workspace changed") }
                current.layout.workspaces[index].title = title
            }
        }
    }
}
