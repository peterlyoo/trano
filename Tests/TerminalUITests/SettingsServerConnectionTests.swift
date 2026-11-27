import AppKit
import SwiftUI
import XCTest
import TerminalCore
@testable import TranoApp

@MainActor final class SettingsServerConnectionTests: XCTestCase {
    func testTailscaleAvailabilityProbeRunsOffMainWithoutCreatingOrReadingBackend() async {
        let completed = expectation(description: "capability")
        let connection = SettingsServerConnection(makeBackend: {
            XCTFail("Availability check created backend"); return FakeSettingsBackend()
        }, discoverAgents: { XCTFail("Availability check discovered agents"); return [] }, discoverTailscale: {
            XCTAssertFalse(Thread.isMainThread); return true
        })
        XCTAssertFalse(connection.tailscaleAvailable)
        connection.refreshCapabilities { completed.fulfill() }
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertTrue(connection.tailscaleAvailable)
        XCTAssertNil(connection.controller)
    }
    func testBackendCreationIsLazyOffMainAndCoalescesWaitersWithoutStatusRead() async {
        let backend = FakeSettingsBackend()
        let connection = SettingsServerConnection(makeBackend: {
            XCTAssertFalse(Thread.isMainThread); backend.incrementFactory(); return backend
        }, discoverAgents: { XCTAssertFalse(Thread.isMainThread); return [.claude] })
        XCTAssertEqual(backend.factoryCalls, 0)
        let first = expectation(description: "first"); let second = expectation(description: "second")
        connection.prepare { result in XCTAssertNotNil(try? result.get()); first.fulfill() }
        connection.prepare { result in XCTAssertNotNil(try? result.get()); second.fulfill() }
        await fulfillment(of: [first, second], timeout: 2)
        XCTAssertEqual(backend.factoryCalls, 1)
        XCTAssertEqual(backend.readCalls, 0)
        XCTAssertEqual(connection.availableAgents, [.claude])
        XCTAssertNotNil(connection.controller)
    }

    func testFactoryFailureReleasesWaitersAndAllowsRetry() async {
        let backend = FakeSettingsBackend()
        let connection = SettingsServerConnection(makeBackend: {
            if backend.incrementFactory() == 1 { throw TerminalError.invalid("Factory fixture failure") }
            return backend
        })
        let failed = expectation(description: "failed")
        connection.prepare { result in
            if case .success = result { XCTFail("Factory failure was reported as success") }
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertNil(connection.controller); XCTAssertNotNil(connection.error)
        let retried = expectation(description: "retried")
        connection.prepare { result in XCTAssertNotNil(try? result.get()); retried.fulfill() }
        await fulfillment(of: [retried], timeout: 2)
        XCTAssertNotNil(connection.controller); XCTAssertNil(connection.error)
        XCTAssertEqual(backend.factoryCalls, 2)
    }

    func testExternalAdaptersUseControllerDriversAndPropagateFailure() async {
        let backend = FakeSettingsBackend(); backend.failServer = true
        let connection = SettingsServerConnection(makeBackend: { backend })
        let failed = expectation(description: "server failed")
        var server = ServerPreferences(); server.remoteControl = true
        connection.saveServer(baseline: .init(), edited: server) { error in XCTAssertNotNil(error); failed.fulfill() }
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(backend.serverCalls, 1); XCTAssertEqual(backend.readCalls, 0)
        let saved = expectation(description: "integrations saved")
        var integrations = IntegrationsPreferences(); integrations.letAgentsNameSessions = true
        connection.saveIntegrations(baseline: .init(), edited: integrations) { error in XCTAssertNil(error); saved.fulfill() }
        await fulfillment(of: [saved], timeout: 2)
        XCTAssertEqual(backend.integrationCalls, 1); XCTAssertEqual(backend.readCalls, 1)
    }

    func testDeveloperAndServerControlsFitThe683PointSettingsContentColumn() {
        let root = URL(fileURLWithPath: "/tmp/trano-settings-native-component")
        let server = ServerSettingsNativeView(frame: NSRect(x: 0, y: 0, width: 647, height: 800))
        server.configure(preferences: .init(), snapshot: ServerRuntimeSnapshot(response: nil, expected: .process, root: root, label: "Fixture"), tailscale: nil, clients: [], toolAvailable: false, busy: false, error: nil)
        var preferences = DeveloperPreferences(); preferences.enabled = true
        let developer = DeveloperSettingsNativeView(frame: NSRect(x: 0, y: 0, width: 647, height: 1000))
        developer.configure(preferences: preferences, readiness: DeveloperUpdateReadiness(available: false, reason: "Fixture unavailable", automaticDownloads: false, immediateInstallation: false, channels: []), metadata: nil, installationStatus: "Fixture", localAPIURL: "http://127.0.0.1:0", origins: ["https://example.com"])
        for view in [server, developer] {
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 683, height: 1100))
            view.setFrameOrigin(NSPoint(x: 18, y: 18)); content.addSubview(view)
            view.layoutSubtreeIfNeeded()
            let controls = descendants(view).compactMap { $0 as? NSControl }.filter { !$0.isHiddenOrHasHiddenAncestor }
            XCTAssertGreaterThan(controls.count, 5)
            for control in controls {
                let frame = control.convert(control.bounds, to: content)
                XCTAssertGreaterThanOrEqual(frame.minX, -1, control.identifier?.rawValue ?? "control")
                XCTAssertLessThanOrEqual(frame.maxX, content.bounds.maxX + 1, control.identifier?.rawValue ?? "control")
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

private final class FakeSettingsBackend: ServerSettingsBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var counts = [0, 0, 0, 0]
    var failServer = false
    var factoryCalls: Int { count(0) }
    var readCalls: Int { count(1) }
    var serverCalls: Int { count(2) }
    var integrationCalls: Int { count(3) }
    private func count(_ index: Int) -> Int { lock.lock(); defer { lock.unlock() }; return counts[index] }
    @discardableResult func incrementFactory() -> Int { lock.lock(); defer { lock.unlock() }; counts[0] += 1; return counts[0] }
    func read() throws -> ServerSettingsReadSnapshot {
        XCTAssertFalse(Thread.isMainThread); lock.lock(); counts[1] += 1; lock.unlock()
        return ServerSettingsReadSnapshot(server: .init(), integrations: .init(), runtime: ServerRuntimeSnapshot(response: nil, expected: .process, root: URL(fileURLWithPath: "/tmp/trano-fake-settings"), label: "Fixture"), tailscale: nil, clients: [], availableAgents: [])
    }
    func perform(_ action: ServerSettingsNativeAction) throws { XCTFail("No explicit Server action expected") }
    func cancel() {}
    func saveServer(baseline: ServerPreferences, edited: ServerPreferences) throws {
        XCTAssertFalse(Thread.isMainThread); lock.lock(); counts[2] += 1; let fail = failServer; lock.unlock()
        if fail { throw TerminalError.invalid("Server fixture failure") }
    }
    func saveIntegrations(baseline: IntegrationsPreferences, edited: IntegrationsPreferences) throws {
        XCTAssertFalse(Thread.isMainThread); lock.lock(); counts[3] += 1; lock.unlock()
    }
}
