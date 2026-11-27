import Foundation
import XCTest
@testable import TerminalCore

final class SupervisorBootstrapTests: XCTestCase {
    // Implements: FR-SUP-2, FR-SUP-5
    func testSocketPayloadPreservesExactManagedArgvAndNeverUsesPTYText() throws {
        let f = fixture()
        let data = try SupervisorBootstrap.payload(for: f.plan, binding: f.binding, nonce: f.nonce)
        print("Supervisor socket payload bytes: \(data.count)")
        XCTAssertLessThanOrEqual(data.count, 65_536)
        let envelope = try JSONDecoder().decode(SupervisorBootstrapEnvelope.self, from: data)
        XCTAssertEqual(envelope.arguments, f.plan.arguments)
        XCTAssertEqual(envelope.arguments.last?.utf8.map { $0 }, Array(SupervisorInstructions.prompt.utf8))
        XCTAssertEqual(try SupervisorBootstrap.validate(data, binding: f.binding, nonce: f.nonce, helperExecutable: f.plan.arguments[0]), f.plan)
    }

    // Implements: FR-SUP-2, FR-SUP-5
    func testOtherwiseValidOversizedFrameIsRejectedBeforeDecodingIgnoredFields() throws {
        let f = fixture()
        let data = try SupervisorBootstrap.payload(for: f.plan, binding: f.binding, nonce: f.nonce)
        var object = try JSONDecoder().decode([String: JSONValue].self, from: data)
        object["ignoredPadding"] = .string(String(repeating: "a", count: 65_536))
        let padded = try JSONEncoder().encode(object)
        XCTAssertGreaterThan(padded.count, 65_536)
        XCTAssertThrowsError(try SupervisorBootstrap.validate(padded, binding: f.binding, nonce: f.nonce, helperExecutable: f.plan.arguments[0]))
    }

    // Implements: FR-SUP-2, FR-SUP-5
    func testInvalidGateAndOversizedOrUntrustedPayloadFailBeforeDispatch() throws {
        let f = fixture()
        for name in ["../api.sock", "api.sock", "sg-123456789", "/tmp/socket"] {
            XCTAssertThrowsError(try SupervisorBootstrap.arguments(gateName: name, nonce: f.nonce))
        }
        XCTAssertThrowsError(try SupervisorBootstrap.arguments(gateName: "sg-12ab34cd", nonce: "bad"))
        for arguments in [[], ["relative"], ["/tmp/tool", "bad\0value"], ["/tmp/tool", String(repeating: "a", count: 65_536)]] {
            XCTAssertThrowsError(try SupervisorBootstrap.payload(for: SupervisorLaunchPlan(arguments: arguments), binding: f.binding, nonce: f.nonce))
        }
        let data = try SupervisorBootstrap.payload(for: f.plan, binding: f.binding, nonce: f.nonce)
        XCTAssertThrowsError(try SupervisorBootstrap.validate(data, binding: f.binding, nonce: UUID().uuidString, helperExecutable: f.plan.arguments[0]))
        XCTAssertThrowsError(try SupervisorBootstrap.validate(data, binding: f.binding, nonce: f.nonce, helperExecutable: "/tmp/other"))
        let injected = SupervisorBootstrapEnvelope(nonce: f.nonce, binding: f.binding, arguments: [f.plan.arguments[0], "run", "--agent", "claude", "--", "Untrusted prompt"])
        XCTAssertThrowsError(try SupervisorBootstrap.validate(JSONEncoder().encode(injected), binding: f.binding, nonce: f.nonce, helperExecutable: f.plan.arguments[0]))
    }

    // Implements: FR-SUP-2, FR-SUP-5
    func testChildAcknowledgesWithoutAcquiringEitherHeldParentLock() throws {
        let f = fixture()
        let heldLocks: Set<String> = ["runtime.state.lock", "supervisor.lock"]
        var events: [String] = []
        let transport = Transport(payload: try SupervisorBootstrap.payload(for: f.plan, binding: f.binding, nonce: f.nonce))
        transport.onSend = { data in events.append(String(decoding: data, as: UTF8.self).hasPrefix("ready:") ? "ready" : "accepted") }
        transport.onReceive = { events.append("receive") }
        let plan = try SupervisorBootstrap.prepareChild(paneID: f.binding.paneID, backendPID: f.binding.backendPID,
            nonce: f.nonce, helperExecutable: f.plan.arguments[0], transport: transport,
            readPublishedBinding: {
                XCTAssertEqual(heldLocks, ["runtime.state.lock", "supervisor.lock"])
                events.append("atomic-published-read-without-locks")
                return f.binding
            }, readIdentity: { pid in
                XCTAssertEqual(pid, f.binding.backendPID)
                events.append("identity")
                return f.binding.processIdentity
            })
        XCTAssertEqual(plan, f.plan)
        XCTAssertEqual(events, ["ready", "receive", "atomic-published-read-without-locks", "identity", "accepted"])
    }

    // Implements: FR-SUP-2, FR-SUP-5
    func testPIDReuseOrWrongPublishedBindingCannotBeAcknowledged() throws {
        let f = fixture()
        let payload = try SupervisorBootstrap.payload(for: f.plan, binding: f.binding, nonce: f.nonce)
        let transport = Transport(payload: payload)
        let reused = SupervisorProcessIdentity(pid: f.binding.backendPID, ownerUID: 501, startedAtSeconds: 2, startedAtMicroseconds: 1)
        XCTAssertThrowsError(try SupervisorBootstrap.prepareChild(paneID: f.binding.paneID, backendPID: f.binding.backendPID,
            nonce: f.nonce, helperExecutable: f.plan.arguments[0], transport: transport,
            readPublishedBinding: { f.binding }, readIdentity: { _ in reused }))
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertFalse(transport.sent.contains { String(decoding: $0, as: UTF8.self).hasPrefix("accepted:") })
    }

    private func fixture() -> (binding: SupervisorBinding, plan: SupervisorLaunchPlan, nonce: String) {
        let identity = SupervisorProcessIdentity(pid: 1234, ownerUID: 501, startedAtSeconds: 1, startedAtMicroseconds: 1)
        let binding = SupervisorBinding(paneID: UUID().uuidString.lowercased(), backendPID: identity.pid,
            configuration: SupervisorConfiguration(provider: .claude, cwd: "/tmp/한글 folder"), processIdentity: identity)
        return (binding, SupervisorLaunchPlan(arguments: ["/tmp/한글 a trano", "run", "--agent", "claude", "--", SupervisorInstructions.prompt]), UUID().uuidString.lowercased())
    }

    private final class Transport: SupervisorBootstrapTransport {
        let payload: Data
        var sent: [Data] = []
        var onSend: ((Data) -> Void)?
        var onReceive: (() -> Void)?
        init(payload: Data) { self.payload = payload }
        func send(_ data: Data) { sent.append(data); onSend?(data) }
        func receive() -> Data { onReceive?(); return payload }
    }
}
