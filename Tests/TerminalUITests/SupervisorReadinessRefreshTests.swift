import AppKit
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class SupervisorReadinessRefreshTests: XCTestCase {
    // Implements: FR-SUP-7
    @MainActor func testInputOnlyBurstsUseBoundedLedgerReadsAndNeverFullStateOrProcessScans() {
        let f = fixture()
        f.model.refresh(); f.scheduler.drain()
        f.spy.full = 0; f.spy.processScans = 0
        for _ in 0..<100 { f.model.refreshReadiness() }
        XCTAssertEqual(f.scheduler.work.count, 1)
        XCTAssertEqual(f.spy.ledger, 0)
        f.scheduler.drain()
        XCTAssertEqual(f.spy.full, 0)
        XCTAssertEqual(f.spy.processScans, 0)
        XCTAssertGreaterThan(f.spy.ledger, 0)
        XCTAssertLessThanOrEqual(f.spy.ledger, 2)
    }

    // Implements: FR-SUP-7
    @MainActor func testAFullPendingRefreshDominatesInputOnlyEventsWithoutAThirdRead() {
        let f = fixture()
        f.model.refresh(); f.scheduler.drain(); f.spy.full = 0; f.spy.processScans = 0
        f.model.refreshReadiness()
        f.model.refreshReadiness()
        f.model.refresh()
        f.model.refreshReadiness()
        f.scheduler.drain()
        XCTAssertEqual(f.spy.ledger, 1)
        XCTAssertEqual(f.spy.full, 1)
        XCTAssertEqual(f.spy.processScans, 1)
    }

    // Implements: FR-SUP-7
    @MainActor func testMissingCachedStateDoesNotFallBackToAFullRead() {
        let f = fixture()
        f.model.refreshReadiness()
        XCTAssertTrue(f.scheduler.work.isEmpty)
        XCTAssertEqual(f.spy.full, 0)
        XCTAssertEqual(f.spy.ledger, 0)
    }

    // Implements: FR-SUP-7
    @MainActor func testInputOnlyUpdatesNeverNotifyTheFullRendererPath() {
        let f = fixture()
        var fullRenders = 0, readinessRenders = 0
        f.model.onChange = { fullRenders += 1 }
        f.model.onReadinessChange = { readinessRenders += 1 }
        f.model.refresh(); f.scheduler.drain()
        XCTAssertGreaterThan(fullRenders, 0)
        fullRenders = 0
        for _ in 0..<100 { f.model.refreshReadiness() }
        f.scheduler.drain()
        XCTAssertEqual(fullRenders, 0)
        XCTAssertGreaterThan(readinessRenders, 0)
        XCTAssertLessThanOrEqual(readinessRenders, 4)
    }

    @MainActor private func fixture() -> (model: SupervisorPanelModel, scheduler: RefreshScheduler, spy: RefreshSpy) {
        let spy = RefreshSpy(), scheduler = RefreshScheduler()
        var services = SupervisorPanelServices(readState: { spy.full += 1; spy.processScans += 1; return emptyState() },
            start: { _ in emptyState() }, stop: { _, _ in emptyState() }, makeRenderer: { _ in NSView() },
            synchronizeRenderer: { _, _ in }, performRendererAction: { _, _ in false }, cachedAccounts: { [] }, cachedKeyBindings: { [:] })
        services.readReadiness = { state in spy.ledger += 1; return state }
        return (SupervisorPanelModel(services: services, configuration: SupervisorConfiguration(provider: .claude, cwd: "/tmp"), scheduler: scheduler), scheduler, spy)
    }
}
private func emptyState() -> SupervisorState {
    let data = Data("{\"phase\":\"not_started\",\"targets\":[],\"cursor\":{\"targets\":[]}}".utf8)
    return try! JSONDecoder().decode(SupervisorState.self, from: data)
}
private final class RefreshSpy: @unchecked Sendable { var full = 0, ledger = 0, processScans = 0 }
private final class RefreshScheduler: SupervisorPanelScheduling, @unchecked Sendable {
    var work: [@Sendable () -> Void] = []
    var delivery: [@MainActor @Sendable () -> Void] = []
    func schedule(_ action: @escaping @Sendable () -> Void) { work.append(action) }
    func deliver(_ action: @escaping @MainActor @Sendable () -> Void) { delivery.append(action) }
    @MainActor func drain() {
        for _ in 0..<10 {
            if work.isEmpty && delivery.isEmpty { return }
            let pending = work; work = []; pending.forEach { $0() }
            let callbacks = delivery; delivery = []; callbacks.forEach { $0() }
        }
        XCTFail("Refresh fixture did not settle")
    }
}
