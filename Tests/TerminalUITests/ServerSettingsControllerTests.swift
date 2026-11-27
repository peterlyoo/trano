import AppKit
import Combine
import XCTest
import TerminalCore
@testable import TranoApp

final class ServerSettingsControllerTests: XCTestCase {
    // Implements: FR-SET-18, FR-SET-27, FR-SET-29
    func testClientAdministrationErrorsDoNotProduceTailscaleAlertsButDaemonFailuresDo() throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("trano-alert-" + String(UUID().uuidString.prefix(12)))
        let runtime = try TerminalRuntime(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        var requests: [APIRequest] = []
        let backend = try LiveServerSettingsBackend(runtime: runtime, executor: UnavailableTailscale(), apiCall: { request in
            requests.append(request)
            if request.method == "server.clients.revoke" { throw TerminalError.invalid("Fixture client changed") }
            return try JSONDecoder().decode(APIResponse.self, from: Data(#"{"apiVersion":1,"result":{"apiVersion":1,"version":"development","buildNumber":"0","buildID":"unbundled","pid":100}}"#.utf8))
        })
        XCTAssertThrowsError(try backend.perform(.revokeClient("fixture")))
        XCTAssertFalse(requests.contains { $0.method == "server.tailscale.observe" })
        requests = []
        let snapshot = try backend.read()
        XCTAssertNotNil(snapshot.tailscaleError)
        XCTAssertTrue(requests.contains { $0.method == "server.tailscale.observe" && $0.params["failed"] == .bool(true) })
    }
    // Implements: FR-SET-22, FR-SET-29
    func testDisableFailureStillClosesGatewayAndKeepsRemoteAccessDisabled() throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("trano-off-" + String(UUID().uuidString.prefix(12)))
        let runtime = try TerminalRuntime(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SecureSettingsSidecar<ServerPreferences>(root: root, filename: "server-settings.json")
        let baseline = try store.load(); var enabled = baseline; enabled.serveOverTailscale = true
        _ = try store.merge(baseline: baseline, edited: enabled)
        var calls: [String] = []
        let backend = try LiveServerSettingsBackend(runtime: runtime, executor: UnavailableTailscale(), apiCall: { request in
            calls.append(request.method)
            return try JSONDecoder().decode(APIResponse.self, from: Data(#"{"apiVersion":1,"result":{"ok":true}}"#.utf8))
        })
        var off = enabled; off.serveOverTailscale = false
        XCTAssertThrowsError(try backend.saveServer(baseline: enabled, edited: off))
        XCTAssertFalse(try store.load().serveOverTailscale)
        XCTAssertTrue(calls.contains("server.remote.stop"))
    }
    // Implements: FR-SET-19, FR-SET-27
    @MainActor func testActionMarksBusySynchronouslyAndBlocksDuplicateDispatch() async throws {
        let backend = FakeSettingsBackend(), controller = ServerSettingsController(backend: backend)
        let finished = expectation(description: "background refresh finished")
        var becameBusy = false
        let subscription = controller.$busy.sink { value in
            if value { becameBusy = true }
            if !value && becameBusy { finished.fulfill() }
        }
        controller.perform(.refresh)
        XCTAssertTrue(controller.busy)
        controller.perform(.refresh)
        backend.release.signal()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(backend.actions, [.refresh]); XCTAssertNotNil(controller.snapshot); XCTAssertNil(controller.error)
        withExtendedLifetime(subscription) {}
    }
    // Implements: FR-SET-1, FR-SET-22, FR-SET-28, FR-SET-29
    @MainActor func testInvalidDraftNeverReachesBackendAndFailedSaveRetainsError() async throws {
        let backend = FakeSettingsBackend(), controller = ServerSettingsController(backend: backend)
        var invalid = ServerPreferences(); invalid.clientLabel = "bad\nlabel"
        XCTAssertFalse(controller.saveServer(baseline: ServerPreferences(), edited: invalid, completion: { _ in XCTFail("Invalid draft completed asynchronously") }))
        XCTAssertNotNil(controller.error); XCTAssertEqual(backend.saves, 0)
        let completed = expectation(description: "save failed")
        backend.failure = true; backend.release.signal()
        var valid = ServerPreferences(); valid.clientLabel = "Desktop"
        XCTAssertTrue(controller.saveServer(baseline: ServerPreferences(), edited: valid) { success in XCTAssertFalse(success); completed.fulfill() })
        XCTAssertTrue(controller.busy)
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertFalse(controller.busy); XCTAssertNotNil(controller.error); XCTAssertEqual(backend.saves, 1)
    }
}
private final class UnavailableTailscale: TailscaleCommandExecuting {
    func run(arguments: [String]) throws -> TailscaleCommandResult { throw TerminalError.runtime("Fixture daemon unavailable") }
    func cancel() {}
}
private final class FakeSettingsBackend: ServerSettingsBackend, @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    var actions: [ServerSettingsNativeAction] = []
    var saves = 0
    var failure = false
    func perform(_ action: ServerSettingsNativeAction) throws { actions.append(action); _ = release.wait(timeout: .now() + 1) }
    func cancel() { release.signal() }
    func read() throws -> ServerSettingsReadSnapshot { ServerSettingsReadSnapshot(server: ServerPreferences(), integrations: IntegrationsPreferences(), runtime: ServerRuntimeSnapshot(response: nil, expected: .process, root: URL(fileURLWithPath: "/tmp/fixture"), label: "Desktop"), tailscale: nil, clients: [], availableAgents: []) }
    func saveServer(baseline: ServerPreferences, edited: ServerPreferences) throws { saves += 1; _ = release.wait(timeout: .now() + 1); if failure { throw TerminalError.invalid("Fixture failure") } }
    func saveIntegrations(baseline: IntegrationsPreferences, edited: IntegrationsPreferences) throws {}
}
