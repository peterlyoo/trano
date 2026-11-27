import AppKit
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class SupervisorLoadAccessoryTests: XCTestCase {
    // Implements: FR-LOAD-3, FR-LOAD-4
    @MainActor func testInjectedCachedAccessoryFitsAndRetainsTheTerminalRenderer() throws {
        _ = NSApplication.shared
        let binding = SupervisorBinding(paneID: "00000000-0000-4000-8000-000000000010", backendPID: 4711,
            configuration: SupervisorConfiguration(provider: .claude, cwd: "/tmp"), createdAt: Date(timeIntervalSince1970: 1))
        let state = SupervisorState(phase: .running, binding: binding, targets: [], cursor: SupervisorWatchCursor(), message: nil)
        let renderer = NSView()
        let accessory = NSView()
        var accessoryCount = 0
        var rendererCount = 0
        let scheduler = Scheduler()
        let services = SupervisorPanelServices(readState: { state }, start: { _ in state }, stop: { _, _ in state },
            makeRenderer: { _ in rendererCount += 1; return renderer }, synchronizeRenderer: { _, _ in },
            performRendererAction: { _, _ in false }, cachedAccounts: { [] }, cachedKeyBindings: { [:] })
        let model = SupervisorPanelModel(services: services, configuration: binding.configuration, scheduler: scheduler)
        let controller = SupervisorWindowController(model: model, makeWindow: { _ in
            let panel = NSPanel(contentRect: NSRect(x: -12000, y: -12000, width: 360, height: 420),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            return panel
        }, presentWindow: { _ in }, makeLoadAccessory: { _ in accessoryCount += 1; return accessory })
        defer { controller.window?.delegate = nil; controller.window?.close() }
        controller.show()
        scheduler.run()
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let host = try XCTUnwrap(region("supervisor-load", in: content))
        XCTAssertGreaterThan(host.bounds.height, 10)
        XCTAssertLessThanOrEqual(host.bounds.height, 28)
        XCTAssertTrue(content.bounds.contains(host.convert(host.bounds, to: content)))
        XCTAssertTrue(accessory.superview === host)
        model.refresh()
        scheduler.run()
        XCTAssertTrue(controller.renderer === renderer)
        XCTAssertEqual(accessoryCount, 1)
        XCTAssertEqual(rendererCount, 1)
    }

    @MainActor private func region(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        for child in view.subviews { if let found = region(id, in: child) { return found } }
        return nil
    }

    private final class Scheduler: SupervisorPanelScheduling, @unchecked Sendable {
        private var work: [@Sendable () -> Void] = []
        private var deliveries: [@MainActor @Sendable () -> Void] = []
        func schedule(_ action: @escaping @Sendable () -> Void) { work.append(action) }
        func deliver(_ action: @escaping @MainActor @Sendable () -> Void) { deliveries.append(action) }
        @MainActor func run() {
            let pending = work; work = []; pending.forEach { $0() }
            let callbacks = deliveries; deliveries = []; callbacks.forEach { $0() }
        }
    }
}
