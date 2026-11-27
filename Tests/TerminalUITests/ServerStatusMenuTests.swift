import AppKit
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class ServerStatusMenuTests: XCTestCase {
    // Implements: FR-SERVER-1, FR-SERVER-3
    @MainActor func testMenuBarBrandContainsOnlyWhiteWordmarkInkAtBothScales() throws {
        _ = NSApplication.shared
        let image = try XCTUnwrap(ServerStatusController.menuBarImage)
        XCTAssertEqual(image.size, NSSize(width: 44, height: 16))
        XCTAssertTrue(image.isTemplate)
        for scale in [1, 2, 8] {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: 44 * scale, pixelsHigh: 16 * scale, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = image.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            image.draw(in: CGRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
            var solid = 0, transparent = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    if color.alphaComponent > 0.5 {
                        solid += 1
                        XCTAssertGreaterThan(color.redComponent, 0.98)
                        XCTAssertGreaterThan(color.greenComponent, 0.98)
                        XCTAssertGreaterThan(color.blueComponent, 0.98)
                    } else if color.alphaComponent < 0.01 { transparent += 1 }
                }
            }
            XCTAssertGreaterThan(solid, 100 * scale * scale)
            XCTAssertGreaterThan(transparent, 220 * scale * scale, "The Dock tile must not remain behind the mark")
            if let directory = ProcessInfo.processInfo.environment["TRANO_RENDER_CAPTURE_DIR"] {
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                    URL(fileURLWithPath: directory).appendingPathComponent("menu-bar-mark-\(scale)x.png"))
            }
        }
    }

    // Implements: FR-SERVER-1, FR-SERVER-3, FR-SERVER-4, FR-SERVER-5
    @MainActor func testMenuOwnsNativeActionTargetsAndShowsOperationalState() throws {
        _ = NSApplication.shared
        var opened = 0, retried = 0, restarted = 0, copied = 0, quit = 0
        let presenter = ServerStatusMenu(open: { opened += 1 }, retry: { retried += 1 }, restart: { restarted += 1 }, copy: { copied += 1 }, quit: { quit += 1 })
        var state = ServerStatusState(pid: 42, buildID: "build")
        let generation = state.beginStart(restarting: false)
        state.finishStart(generation, error: "Unavailable")
        presenter.update(state.snapshot)
        XCTAssertEqual(presenter.menu.items.first?.title, "Trano Server Error")
        for title in ["Open Trano", "Retry Connection", "Restart Server", "Copy Diagnostics", "Quit Server"] {
            let index = presenter.menu.indexOfItem(withTitle: title)
            XCTAssertGreaterThanOrEqual(index, 0)
            XCTAssertTrue(presenter.menu.items[index].target === presenter)
            presenter.menu.performActionForItem(at: index)
        }
        XCTAssertEqual([opened, retried, restarted, copied, quit], [1, 1, 1, 1, 1])
        XCTAssertFalse(presenter.menu.autoenablesItems)
    }

    @MainActor func testStartingAndRunningHaveClearActionAvailability() throws {
        _ = NSApplication.shared
        let presenter = ServerStatusMenu(open: {}, retry: {}, restart: {}, copy: {})
        var state = ServerStatusState(pid: 42, buildID: "build")
        let generation = state.beginStart(restarting: false)
        presenter.update(state.snapshot)
        XCTAssertFalse(try XCTUnwrap(presenter.menu.item(withTitle: "Restart Server")).isEnabled)
        XCTAssertFalse(try XCTUnwrap(presenter.menu.item(withTitle: "Retry Connection")).isEnabled)
        state.finishStart(generation, error: nil)
        let lease = try XCTUnwrap(state.beginProbe())
        let response = try JSONDecoder().decode(APIResponse.self, from: Data("{\"apiVersion\":1,\"result\":{\"apiVersion\":1,\"pid\":42,\"buildID\":\"build\",\"serviceKind\":\"background\"}}".utf8))
        state.finishProbe(lease, result: .success(response), now: Date())
        presenter.update(state.snapshot)
        XCTAssertEqual(presenter.menu.items.first?.title, "Trano Server Running")
        XCTAssertTrue(try XCTUnwrap(presenter.menu.item(withTitle: "Restart Server")).isEnabled)
        XCTAssertFalse(try XCTUnwrap(presenter.menu.item(withTitle: "Retry Connection")).isEnabled)
        XCTAssertFalse(presenter.menu.items.contains { $0.title == "Quit Trano" })
    }
    @MainActor func testControllerRetainsStartupErrorRetriesOnceAndRestartsOffMain() async throws {
        _ = NSApplication.shared
        let cache = ServerStatusCache(ServerStatusState(pid: 42, buildID: "build").snapshot)
        let operations = ServerStatusFakeOperations()
        let response = try JSONDecoder().decode(APIResponse.self, from: Data("{\"apiVersion\":1,\"result\":{\"apiVersion\":1,\"pid\":42,\"buildID\":\"build\",\"serviceKind\":\"background\"}}".utf8))
        let controller = ServerStatusController(cache: cache, registerItem: false, start: {
            operations.recordStart()
            if operations.starts == 1 { throw TerminalError.runtime("Missing runtime") }
        }, restart: { operations.recordRestart() }, probe: { response }, open: {})
        defer { controller.stop() }
        controller.start()
        try await waitFor(cache, .startupError)
        XCTAssertEqual(cache.snapshot().error, "Missing runtime")
        controller.retry(); controller.retry()
        try await waitFor(cache, .running)
        XCTAssertEqual(operations.starts, 2)
        controller.restart(); controller.restart()
        try await waitFor(cache, .running)
        XCTAssertEqual(operations.restarts, 1)
        XCTAssertFalse(operations.ranOnMain)
        controller.stop()
        XCTAssertEqual(cache.snapshot().phase, .stopped)
        XCTAssertFalse(cache.snapshot().itemRegistered)
    }

    @MainActor func testShutdownQueuesAfterStartAndRejectsLateReadinessAndRepeatedExit() async throws {
        _ = NSApplication.shared
        let cache = ServerStatusCache(ServerStatusState(pid: 42, buildID: "build").snapshot)
        let started = expectation(description: "Fake start entered")
        let stopped = expectation(description: "Fake server stopped")
        let gate = DispatchSemaphore(value: 0)
        let controller = ServerStatusController(cache: cache, registerItem: false, start: {
            started.fulfill()
            guard gate.wait(timeout: .now() + 2) == .success else { throw TerminalError.runtime("Fixture timed out") }
        }, restart: {}, probe: { XCTFail("Shutdown must revoke health work"); throw TerminalError.runtime("Unexpected probe") }, open: {})
        controller.start()
        await fulfillment(of: [started], timeout: 2)
        var completionCount = 0
        controller.shutdown({ stopped.fulfill() }, completion: { completionCount += 1 })
        controller.shutdown({ XCTFail("Shutdown must be single-flight") }, completion: { XCTFail("Duplicate exit") })
        gate.signal()
        await fulfillment(of: [stopped], timeout: 2)
        for _ in 0..<100 where completionCount == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(completionCount, 1)
        XCTAssertEqual(cache.snapshot().phase, .stopped)
    }

    @MainActor private func waitFor(_ cache: ServerStatusCache, _ phase: ServerStatusPhase) async throws {
        for _ in 0..<200 {
            if cache.snapshot().phase == phase { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Status did not reach \(phase); got \(cache.snapshot().phase)")
    }

}

private final class ServerStatusFakeOperations {
    private let lock = NSLock()
    private var startCount = 0, restartCount = 0
    private var onMain = false
    var starts: Int { lock.lock(); defer { lock.unlock() }; return startCount }
    var restarts: Int { lock.lock(); defer { lock.unlock() }; return restartCount }
    var ranOnMain: Bool { lock.lock(); defer { lock.unlock() }; return onMain }
    func recordStart() { lock.lock(); defer { lock.unlock() }; startCount += 1; onMain = onMain || Thread.isMainThread }
    func recordRestart() { lock.lock(); defer { lock.unlock() }; restartCount += 1; onMain = onMain || Thread.isMainThread }
}
