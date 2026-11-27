import AppKit
import Darwin
import XCTest
@testable import TerminalCore
@testable import TranoApp

@MainActor final class AppStoreObservationLockTests: XCTestCase {
    // Implements: FR-QUEUE-5, FR-NAV-9
    func testOrdinaryActionPresentationProbeAllowsSameAndOtherRuntimeInput() async throws {
        try await assertPresentationAllowsInput(header: false)
    }

    // Implements: FR-QUEUE-5, FR-NAV-9
    func testHeaderActionPresentationProbeAllowsSameAndOtherRuntimeInput() async throws {
        try await assertPresentationAllowsInput(header: true)
    }

    // Implements: FR-QUEUE-5, FR-NAV-9
    func testOrdinaryActionKeepsInputSerializedDuringItsWork() async throws {
        try await assertWorkRetainsTransaction(header: false)
    }

    // Implements: FR-QUEUE-5, FR-NAV-9
    func testHeaderActionKeepsInputSerializedDuringItsWork() async throws {
        try await assertWorkRetainsTransaction(header: true)
    }

    private func assertPresentationAllowsInput(header: Bool) async throws {
        let f = try Fixture()
        defer { f.releaseAll(); f.cleanup() }
        f.perform(header: header) { try $0.update { $0.settings.fontSize += 1 } }
        guard await waitUntil({ f.probeReady }) else { XCTFail("Fake presentation metadata was never requested"); return }
        let input = f.beginInput()
        let completedBeforeRelease = await waitUntil({ input.same.get() != nil && input.other.get() != nil }, seconds: 1)
        XCTAssertTrue(completedBeforeRelease, "Post-action presentation discovery must release both the runtime mutex and shared state flock before native input")
        f.releaseAll()
        await f.drainStore()
        guard await waitUntil({ input.same.get() != nil && input.other.get() != nil }) else { XCTFail("Input did not finish after probe release"); return }
        XCTAssertEqual(try XCTUnwrap(input.same.get()).get(), 1)
        XCTAssertEqual(try XCTUnwrap(input.other.get()).get(), 1)
        XCTAssertEqual(input.reservations.get(), 2, "Each fake byte dispatch must see its durable input reservation")
        XCTAssertEqual(try f.runtime.state().settings.fontSize, f.originalFontSize + 1)
        XCTAssertNil(f.store.message)
        XCTAssertEqual(f.store.sessions.first?.terminalTitle, "Fake observed title")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.runtime.host.socketPath), "This fixture must never launch real terminal jobs")
    }

    private func assertWorkRetainsTransaction(header: Bool) async throws {
        let f = try Fixture()
        defer { f.releaseAll(); f.cleanup() }
        let entered = Locked(false), releaseWork = f.releaseWork
        f.perform(header: header) { runtime in
            entered.set(true)
            guard releaseWork.wait(timeout: .now() + 6) == .success else { throw TerminalError.runtime("Fake action was never released") }
            try runtime.update { $0.settings.fontSize += 1 }
        }
        guard await waitUntil({ entered.get() }) else { XCTFail("Action work never entered"); return }
        let input = f.beginInput()
        guard await waitUntil({ input.started.get() == 2 }) else { XCTFail("Input workers never attempted delivery"); return }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(input.same.get(), "Same-runtime input must remain serialized with the action mutation")
        XCTAssertNil(input.other.get(), "Cross-runtime input must remain serialized with the action mutation")
        XCTAssertEqual(input.reservations.get(), 0)
        f.releaseAll()
        await f.drainStore()
        guard await waitUntil({ input.same.get() != nil && input.other.get() != nil }) else { XCTFail("Input did not resume after action work"); return }
        XCTAssertEqual(try XCTUnwrap(input.same.get()).get(), 1)
        XCTAssertEqual(try XCTUnwrap(input.other.get()).get(), 1)
        XCTAssertEqual(try f.runtime.state().settings.fontSize, f.originalFontSize + 1)
        XCTAssertNil(f.store.message)
    }

    private func waitUntil(_ predicate: () -> Bool, seconds: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return predicate()
    }

    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func set(_ value: Value) { lock.lock(); defer { lock.unlock() }; self.value = value }
        func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
        func mutate(_ work: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; work(&value) }
    }

    private struct InputResults {
        let same = Locked<Result<Int, Error>?>(nil)
        let other = Locked<Result<Int, Error>?>(nil)
        let reservations = Locked(0)
        let started = Locked(0)
    }

    @MainActor private final class Fixture {
        let root = URL(fileURLWithPath: "/tmp/t-store-observe-" + UUID().uuidString.prefix(8))
        let backend: FakePaneBackend
        let runtime: TerminalRuntime
        let otherRuntime: TerminalRuntime
        let store: AppStore
        let binding: TerminalInputBinding
        let originalFontSize: Double
        let releaseWork = DispatchSemaphore(value: 0)
        private var ready: URL { root.appendingPathComponent("probe-ready") }
        private var release: URL { root.appendingPathComponent("probe-release") }
        var probeReady: Bool { FileManager.default.fileExists(atPath: ready.path) }

        init() throws {
            _ = NSApplication.shared
            let paneID = UUID().uuidString.lowercased()
            backend = FakePaneBackend(panes: [FakePaneBackend.pane(id: paneID, pid: 900001, title: "Fake observed title")])
            let ready = root.appendingPathComponent("probe-ready"), release = root.appendingPathComponent("probe-release")
            backend.listHook = {
                _ = FileManager.default.createFile(atPath: ready.path, contents: Data())
                let deadline = Date().addingTimeInterval(6)
                while !FileManager.default.fileExists(atPath: release.path) {
                    guard Date() < deadline else { throw TerminalError.runtime("Fake pane listing was never released") }
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
            runtime = try TerminalRuntime(root: root)
            runtime.host = backend
            otherRuntime = try TerminalRuntime(root: root)
            otherRuntime.host = backend
            binding = TerminalInputBinding(paneID: paneID, backendPID: 900001, generation: "terminal:900001", providerPID: nil)
            try runtime.update { state in
                state.settings.automaticRestore = false
                state.sessions = [TerminalSession(id: paneID, title: "Stored title", cwd: "/tmp", pid: 900001)]
                state.layout.addWorkspace(title: "observation-fixture")
                state.layout.addTab(paneID: paneID)
            }
            originalFontSize = try runtime.state().settings.fontSize
            store = AppStore(runtime: runtime, startServices: false)
            store.state = try runtime.state(); store.sessions = store.state.sessions
        }

        func perform(header: Bool, work: @escaping (TerminalRuntime) throws -> Void) {
            if header {
                let context = HeaderMenuContext(workspaceID: store.state.layout.selectedWorkspaceID,
                    tabID: store.state.layout.selectedTabID, paneID: binding.paneID)
                store.performHeaderAction(context: context, takeSelection: false, work)
            } else { store.perform(work) }
        }

        func beginInput() -> InputResults {
            let result = InputResults(), binding = binding, root = root
            for (runtime, completion) in [(runtime, result.same), (otherRuntime, result.other)] {
                DispatchQueue.global().async {
                    result.started.mutate { $0 += 1 }
                    runtime.deliverTerminalInput(paneID: binding.paneID, expectedPID: binding.backendPID,
                        expectedBinding: binding, bytes: [120], segments: [TerminalUserInputSegment(bytes: [120], submissionCandidate: false)],
                        write: { bytes, done in
                            if (try? TerminalInputLedgerStore(root: root).load().readiness(binding: binding)) == .inputInFlight {
                                result.reservations.mutate { $0 += 1 }
                            }
                            done(.success(bytes.count))
                        }, completion: { completion.set($0) })
                }
            }
            return result
        }

        func releaseAll() {
            releaseWork.signal()
            _ = FileManager.default.createFile(atPath: release.path, contents: Data())
        }

        func drainStore() async {
            await withCheckedContinuation { continuation in
                store.queue.async { DispatchQueue.main.async { continuation.resume() } }
            }
        }

        func cleanup() {
            XCTAssertFalse(backend.calls.contains { $0.hasPrefix("create") || $0.hasPrefix("respawn") })
            try? FileManager.default.removeItem(at: root)
        }
    }
}
