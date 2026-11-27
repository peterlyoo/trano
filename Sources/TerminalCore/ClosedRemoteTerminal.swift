import Foundation

public struct RemoteClosedTerminal: Codable, Equatable {
    public var closeProtocol: Int
    public var operationID: String
    public var sessionID: String
    public var expectedPID: Int32
    public var generation: String
    public var phase: String
    public var historyProvenance: String

    public init(closeProtocol: Int, operationID: String, sessionID: String, expectedPID: Int32,
                generation: String, phase: String, historyProvenance: String) {
        self.closeProtocol = closeProtocol
        self.operationID = operationID
        self.sessionID = sessionID
        self.expectedPID = expectedPID
        self.generation = generation
        self.phase = phase
        self.historyProvenance = historyProvenance
    }
}

protocol ClosedRemoteTerminalTransport {
    func call(host: RemoteHost, request: APIRequest) throws -> APIResponse
}

struct NativeClosedRemoteTerminalTransport: ClosedRemoteTerminalTransport {
    func call(host: RemoteHost, request: APIRequest) throws -> APIResponse {
        try RemoteClient(host: host).call(request)
    }
}

struct ClosedRemoteTerminalAdapter {
    let host: RemoteHost
    var transport: any ClosedRemoteTerminalTransport = NativeClosedRemoteTerminalTransport()

    private struct Acknowledgment: Decodable {
        let token: RemoteClosedTerminal
        let session: TerminalSession?

        private enum CodingKeys: String, CodingKey { case session }

        init(from decoder: any Decoder) throws {
            token = try RemoteClosedTerminal(from: decoder)
            session = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(TerminalSession.self, forKey: .session)
        }
    }

    func prepare(pane: TerminalSession, operationID: String) throws -> RemoteClosedTerminal {
        let reference = try target(pane, operationID: operationID)
        try capability()
        let response = try request("sessions.list", params: [:])
        let sessions = try JSONDecoder().decode([TerminalSession].self, from: JSONEncoder().encode(response))
            .filter { $0.id == reference.sessionID }
        guard sessions.count == 1, let remote = sessions.first, remote.alive, remote.pid > 0,
              let generation = remote.inputBackendIdentity, !generation.isEmpty, generation.utf8.count <= 256 else {
            throw TerminalError.runtime("Remote close needs a verified live terminal generation; refresh the remote connection and retry")
        }
        let expected = RemoteClosedTerminal(closeProtocol: 1, operationID: operationID, sessionID: reference.sessionID,
            expectedPID: remote.pid, generation: generation, phase: "prepared", historyProvenance: "unavailable")
        let acknowledgment = try acknowledgment("close.prepare", pane: pane, expected: expected)
        guard ["prepared", "committing", "closed", "reopening", "reopened"].contains(acknowledgment.token.phase) else {
            throw TerminalError.runtime("Remote close preparation was not acknowledged")
        }
        return acknowledgment.token
    }

    func commit(pane: TerminalSession, snapshot: RemoteClosedTerminal) throws -> RemoteClosedTerminal {
        _ = try validate(snapshot, pane: pane)
        try capability()
        let result = try reconciled("close.commit", pane: pane, snapshot: snapshot)
        guard result.token.phase == "closed" else {
            throw TerminalError.runtime("Remote close has not confirmed stopped processes; refresh its status before retrying")
        }
        return result.token
    }

    func cancel(pane: TerminalSession, snapshot: RemoteClosedTerminal) throws {
        _ = try validate(snapshot, pane: pane)
        guard snapshot.phase == "prepared" else { throw TerminalError.invalid("Only a prepared remote close can be discarded") }
        try capability()
        let result = try acknowledgment("close.cancel", pane: pane, expected: snapshot)
        guard result.token.phase == "cancelled" else { throw TerminalError.runtime("Remote close preparation was not discarded") }
    }

    func status(pane: TerminalSession, operationID: String) throws -> RemoteClosedTerminal {
        let reference = try target(pane, operationID: operationID)
        try capability()
        let value = try request("close.status", params: ["id": .string(reference.sessionID), "operationID": .string(operationID)])
        let acknowledgment = try decode(value)
        guard acknowledgment.token.operationID == operationID else {
            throw TerminalError.runtime("Remote close returned another operation")
        }
        _ = try validate(acknowledgment.token, pane: pane)
        return acknowledgment.token
    }

    func reopen(pane: TerminalSession, snapshot: RemoteClosedTerminal) throws -> TerminalSession {
        _ = try validate(snapshot, pane: pane)
        try capability()
        let result = try reconciled("close.reopen", pane: pane, snapshot: snapshot)
        guard result.token.phase == "reopened", let session = result.session,
              session.id == snapshot.sessionID, session.alive, session.pid > 0 else {
            throw TerminalError.runtime("Remote reopen has not confirmed a fresh shell; retry this reopen operation")
        }
        return session
    }

    private func target(_ pane: TerminalSession, operationID: String) throws -> RemoteReference {
        guard UUID(uuidString: pane.id) != nil, UUID(uuidString: operationID) != nil,
              let reference = pane.remote, reference.hostID == host.id, UUID(uuidString: reference.sessionID) != nil else {
            throw TerminalError.invalid("Invalid remote terminal close target")
        }
        try host.validated()
        return reference
    }

    private func validate(_ snapshot: RemoteClosedTerminal, pane: TerminalSession, allowCancelled: Bool = false) throws -> RemoteReference {
        let reference = try target(pane, operationID: snapshot.operationID)
        guard snapshot.closeProtocol == 1, snapshot.sessionID == reference.sessionID,
              snapshot.expectedPID > 0, !snapshot.generation.isEmpty, snapshot.generation.utf8.count <= 256,
              (["prepared", "committing", "closed", "reopening", "reopened"].contains(snapshot.phase) || allowCancelled && snapshot.phase == "cancelled"),
              ["journal", "persistedFallback", "unavailable"].contains(snapshot.historyProvenance) else {
            throw TerminalError.runtime("Invalid remote terminal close acknowledgment")
        }
        return reference
    }

    private func capability() throws {
        let result = try request("server.info", params: [:])
        guard result["closedTerminalProtocol"] == .number(1) else {
            throw TerminalError.runtime("Update trano-server on this remote host before closing terminals with saved history; the remote terminal remains running")
        }
    }

    private func request(_ method: String, params: [String: JSONValue]) throws -> JSONValue {
        let response = try transport.call(host: host, request: APIRequest(method: method, params: params))
        if let error = response.error { throw TerminalError.runtime(error) }
        guard response.apiVersion == 1, let result = response.result else {
            throw TerminalError.runtime("Invalid remote terminal close response")
        }
        return result
    }

    private func decode(_ value: JSONValue) throws -> Acknowledgment {
        do { return try JSONDecoder().decode(Acknowledgment.self, from: JSONEncoder().encode(value)) }
        catch { throw TerminalError.runtime("Invalid remote terminal close acknowledgment") }
    }

    private func acknowledgment(_ method: String, pane: TerminalSession, expected: RemoteClosedTerminal) throws -> Acknowledgment {
        let reference = try validate(expected, pane: pane)
        let value = try request(method, params: ["id": .string(reference.sessionID), "operationID": .string(expected.operationID),
            "expectedPID": .number(Double(expected.expectedPID)), "expectedGeneration": .string(expected.generation)])
        let result = try decode(value)
        _ = try validate(result.token, pane: pane, allowCancelled: method == "close.cancel")
        guard result.token.operationID == expected.operationID, result.token.expectedPID == expected.expectedPID,
              result.token.generation == expected.generation else {
            throw TerminalError.runtime("Remote close acknowledgment belongs to another process generation")
        }
        return result
    }

    private func reconciled(_ method: String, pane: TerminalSession, snapshot: RemoteClosedTerminal) throws -> Acknowledgment {
        do { return try acknowledgment(method, pane: pane, expected: snapshot) }
        catch {
            let original = error
            if let status = try? acknowledgment("close.status", pane: pane, expected: snapshot) {
                if method == "close.commit", status.token.phase == "closed" { return status }
                if method == "close.reopen", status.token.phase == "reopened" { return status }
            }
            throw original
        }
    }
}

extension TerminalRuntime {
    public func prepareRemoteTerminalClose(pane: TerminalSession, operationID: String) throws -> RemoteClosedTerminal {
        try closedRemoteAdapter(pane).prepare(pane: pane, operationID: operationID)
    }

    public func commitRemoteTerminalClose(pane: TerminalSession, snapshot: RemoteClosedTerminal) throws -> RemoteClosedTerminal {
        try closedRemoteAdapter(pane).commit(pane: pane, snapshot: snapshot)
    }

    public func discardRemotePreparedTerminal(pane: TerminalSession, snapshot: RemoteClosedTerminal) throws {
        try closedRemoteAdapter(pane).cancel(pane: pane, snapshot: snapshot)
    }

    public func remoteTerminalCloseStatus(pane: TerminalSession, operationID: String) throws -> RemoteClosedTerminal {
        try closedRemoteAdapter(pane).status(pane: pane, operationID: operationID)
    }

    public func reopenRemoteClosedTerminal(pane: TerminalSession, snapshot: RemoteClosedTerminal) throws -> TerminalSession {
        try closedRemoteAdapter(pane).reopen(pane: pane, snapshot: snapshot)
    }

    private func closedRemoteAdapter(_ pane: TerminalSession) throws -> ClosedRemoteTerminalAdapter {
        guard let reference = pane.remote else { throw TerminalError.invalid("Terminal is not remote") }
        return ClosedRemoteTerminalAdapter(host: try remoteHost(reference.hostID), transport: closedRemoteTransport)
    }
}
