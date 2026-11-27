import Foundation

public protocol SupervisorBootstrapTransport: AnyObject {
    func send(_ data: Data) throws
    func receive() throws -> Data
}

public struct SupervisorBootstrapEnvelope: Codable, Equatable {
    public let nonce: String
    public let binding: SupervisorBinding
    public let arguments: [String]
}

public enum SupervisorBootstrap {
    public static func arguments(gateName: String, nonce: String) throws -> [String] {
        guard gateName.utf8.count == 11, gateName.hasPrefix("sg-"),
              gateName.dropFirst(3).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              UUID(uuidString: nonce) != nil else { throw TerminalError.invalid("Invalid Supervisor bootstrap gate") }
        return ["supervisor-bootstrap", gateName, nonce]
    }

    public static func payload(for plan: SupervisorLaunchPlan, binding: SupervisorBinding, nonce: String) throws -> Data {
        guard UUID(uuidString: nonce) != nil else { throw TerminalError.invalid("Invalid Supervisor bootstrap nonce") }
        try validatePlan(plan, binding: binding, helperExecutable: plan.arguments.first ?? "")
        let data = try JSONEncoder().encode(SupervisorBootstrapEnvelope(nonce: nonce, binding: binding, arguments: plan.arguments))
        guard data.count <= 65_536 else { throw TerminalError.invalid("Supervisor bootstrap payload exceeds 64 KiB") }
        return data
    }

    public static func validate(_ data: Data, binding: SupervisorBinding, nonce: String,
                                helperExecutable: String) throws -> SupervisorLaunchPlan {
        guard data.count <= 65_536, UUID(uuidString: nonce) != nil else { throw TerminalError.invalid("Invalid Supervisor bootstrap payload") }
        let value = try JSONDecoder().decode(SupervisorBootstrapEnvelope.self, from: data)
        guard value.nonce == nonce, value.binding == binding else { throw TerminalError.invalid("Supervisor bootstrap binding changed") }
        let plan = SupervisorLaunchPlan(arguments: value.arguments)
        try validatePlan(plan, binding: binding, helperExecutable: helperExecutable)
        return plan
    }

    public static func prepareChild(paneID: String, backendPID: Int32, nonce: String, helperExecutable: String,
                                    transport: SupervisorBootstrapTransport,
                                    readPublishedBinding: () throws -> SupervisorBinding?,
                                    readIdentity: (Int32) -> SupervisorProcessIdentity?) throws -> SupervisorLaunchPlan {
        guard UUID(uuidString: paneID) != nil, backendPID > 1, UUID(uuidString: nonce) != nil else {
            throw TerminalError.invalid("Invalid Supervisor child identity")
        }
        try transport.send(ready(paneID: paneID, backendPID: backendPID, nonce: nonce))
        let data = try transport.receive()
        guard let binding = try readPublishedBinding(), binding.paneID == paneID, binding.backendPID == backendPID,
              let expected = binding.processIdentity, expected.pid == backendPID,
              readIdentity(backendPID) == expected else {
            throw TerminalError.invalid("Supervisor child identity changed before launch")
        }
        let plan = try validate(data, binding: binding, nonce: nonce, helperExecutable: helperExecutable)
        try transport.send(accepted(nonce: nonce))
        return plan
    }

    static func ready(paneID: String, backendPID: Int32, nonce: String) -> Data {
        Data("ready:\(nonce):\(paneID):\(backendPID)".utf8)
    }

    static func accepted(nonce: String) -> Data { Data("accepted:\(nonce)".utf8) }

    private static func validatePlan(_ plan: SupervisorLaunchPlan, binding: SupervisorBinding, helperExecutable: String) throws {
        guard helperExecutable.hasPrefix("/"), helperExecutable.utf8.count <= 4096,
              !helperExecutable.contains("\0"), binding.configuration.provider != .shell, binding.stoppedAt == nil,
              UUID(uuidString: binding.paneID) != nil, binding.backendPID > 1,
              let identity = binding.processIdentity, identity.pid == binding.backendPID,
              identity.startedAtSeconds > 0, identity.startedAtMicroseconds < 1_000_000,
              plan.arguments.allSatisfy({ !$0.contains("\0") }) else { throw TerminalError.invalid("Invalid Supervisor managed launch") }
        let expected: [String]
        if let account = binding.configuration.accountID {
            guard UUID(uuidString: account) != nil else { throw TerminalError.invalid("Invalid Supervisor account") }
            expected = [helperExecutable, "account", "exec", account, "--", SupervisorInstructions.prompt]
        } else {
            expected = [helperExecutable, "run", "--agent", binding.configuration.provider.rawValue, "--", SupervisorInstructions.prompt]
        }
        guard plan.arguments == expected else { throw TerminalError.invalid("Supervisor bootstrap requires its bundled managed instructions") }
    }
}
