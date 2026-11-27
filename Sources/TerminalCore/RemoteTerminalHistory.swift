import Foundation

protocol RemoteTerminalHistoryTransport {
    func sessions(host: RemoteHost) throws -> [TerminalSession]
    func call(host: RemoteHost, request: APIRequest) throws -> APIResponse
}

struct RemoteTerminalHistoryNativeTransport: RemoteTerminalHistoryTransport {
    func sessions(host: RemoteHost) throws -> [TerminalSession] {
        let response = try RemoteClient(host: host).call(APIRequest(method: "sessions.list"))
        guard response.apiVersion == 1, let result = response.result else { throw TerminalError.runtime("Invalid remote session discovery") }
        return try JSONDecoder().decode([TerminalSession].self, from: JSONEncoder().encode(result))
    }
    func call(host: RemoteHost, request: APIRequest) throws -> APIResponse {
        try RemoteClient(host: host).call(request)
    }
}

struct RemoteTerminalHistoryTarget: Equatable {
    let localID: String
    let localPID: Int32
    let reference: RemoteReference
    let host: RemoteHost
}

final class RemoteTerminalHistoryCoordinator: @unchecked Sendable {
    private final class Binding {
        let target: RemoteTerminalHistoryTarget
        let lock = NSLock()
        var remotePID: Int32?
        init(target: RemoteTerminalHistoryTarget) { self.target = target }
    }
    private struct Acknowledgment: Decodable {
        let historyProtocol: Int
        let id: String
        let pid: Int32
        let matched: Bool
        let inputReady: Bool
    }
    private let transport: any RemoteTerminalHistoryTransport
    private let capacity: Int
    private let index = NSLock()
    private var bindings: [String: Binding] = [:]

    init(transport: any RemoteTerminalHistoryTransport = RemoteTerminalHistoryNativeTransport(), capacity: Int = 256) {
        self.transport = transport
        self.capacity = max(1, capacity)
    }

    func discard(localID: String, expectedPID: Int32) {
        index.lock(); defer { index.unlock() }
        if bindings[localID]?.target.localPID == expectedPID { bindings.removeValue(forKey: localID) }
    }

    private func binding(for target: RemoteTerminalHistoryTarget, create: Bool) throws -> Binding? {
        index.lock(); defer { index.unlock() }
        if let existing = bindings[target.localID], existing.target == target { return existing }
        guard create else { return nil }
        guard bindings[target.localID] != nil || bindings.count < capacity else {
            throw TerminalError.runtime("Too many terminal history bindings; return an existing terminal to live input first")
        }
        let value = Binding(target: target)
        bindings[target.localID] = value
        return value
    }

    private func contains(_ binding: Binding) -> Bool {
        index.lock(); defer { index.unlock() }
        return bindings[binding.target.localID] === binding
    }

    private func remove(_ binding: Binding) {
        index.lock(); defer { index.unlock() }
        if bindings[binding.target.localID] === binding { bindings.removeValue(forKey: binding.target.localID) }
    }

    func update(_ target: RemoteTerminalHistoryTarget, lines: Int?, current: () throws -> Bool) throws -> Bool {
        guard UUID(uuidString: target.localID) != nil, target.localPID > 0,
              UUID(uuidString: target.reference.sessionID) != nil,
              target.reference.hostID == target.host.id,
              lines.map({ (-1000...1000).contains($0) }) ?? true else {
            throw TerminalError.invalid("Invalid remote terminal history target")
        }
        try target.host.validated()
        guard lines != 0, try current(), let binding = try binding(for: target, create: lines != nil) else { return false }
        binding.lock.lock(); defer { binding.lock.unlock() }
        guard contains(binding), try current() else { return false }
        if binding.remotePID == nil {
            guard lines != nil else { return false }
            let sessions = try transport.sessions(host: target.host).filter { $0.id == target.reference.sessionID }
            guard sessions.count == 1, let session = sessions.first, session.alive, session.pid > 0 else {
                throw TerminalError.runtime("Remote history requires one live owned session")
            }
            binding.remotePID = session.pid
        }
        guard contains(binding), try current(), let remotePID = binding.remotePID else { return false }
        var params: [String: JSONValue] = ["id": .string(target.reference.sessionID), "expectedPID": .number(Double(remotePID))]
        if let lines { params["lines"] = .number(Double(lines)) }
        let response: APIResponse
        do {
            response = try transport.call(host: target.host, request: APIRequest(
                method: lines == nil ? "panes.history.cancel" : "panes.history.scroll", params: params))
            if let error = response.error { throw TerminalError.runtime(error) }
        } catch {
            let description = String(describing: error)
            if description.contains("unknown API method") || description.contains("unsupported API version") {
                throw TerminalError.runtime("Update trano-server on this remote host to use terminal history")
            }
            throw error
        }
        guard response.apiVersion == 1, let result = response.result else {
            throw TerminalError.runtime("Invalid remote terminal history acknowledgment")
        }
        let acknowledgment: Acknowledgment
        do { acknowledgment = try JSONDecoder().decode(Acknowledgment.self, from: JSONEncoder().encode(result)) }
        catch { throw TerminalError.runtime("Invalid remote terminal history acknowledgment") }
        guard acknowledgment.historyProtocol == 1, acknowledgment.id == target.reference.sessionID,
              acknowledgment.pid >= 0, (!acknowledgment.matched || acknowledgment.pid == remotePID),
              (!acknowledgment.inputReady || acknowledgment.matched) else {
            throw TerminalError.runtime("Invalid remote terminal history acknowledgment")
        }
        guard contains(binding), try current() else { remove(binding); return false }
        if lines == nil { remove(binding) }
        return acknowledgment.matched && (lines != nil || acknowledgment.inputReady)
    }
}
