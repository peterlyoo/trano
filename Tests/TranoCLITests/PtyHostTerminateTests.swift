import XCTest
@testable import TerminalCore
@testable import TranoCLI

final class PtyHostTerminateTests: XCTestCase {
    // Implements: FR-CLOSE-2
    func testTerminateOnHostQueueReturnsWhenTheChildIgnoresHangupAndItsOutputIsUnread() throws {
        let pane = HostedPane(id: UUID().uuidString.lowercased(), cols: 80, rows: 24)
        let finished = DispatchSemaphore(value: 0)
        let child = Locked<pid_t>(0)
        hostQueue.async {
            do {
                try pane.spawn(argv: ["/bin/sh", "-c", "trap '' HUP; exec /usr/bin/yes"], environment: ["PATH=/usr/bin:/bin"], cwd: nil)
            } catch { finished.signal(); return }
            child.set(pane.pid)
            // The host queue stays busy, so nothing reads the PTY while the child fills its output buffer.
            usleep(300_000)
            pane.terminate(waitForExit: true)
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 20), .success, "terminate must not block the host queue on a child stuck draining its TTY")
        let pid = child.get()
        XCTAssertGreaterThan(pid, 1)
        let deadline = Date().addingTimeInterval(5)
        while Darwin.kill(pid, 0) == 0, Date() < deadline { usleep(20_000) }
        XCTAssertNotEqual(Darwin.kill(pid, 0), 0, "The child must be gone after terminate")
        let responsive = DispatchSemaphore(value: 0)
        hostQueue.async { XCTAssertFalse(pane.alive); responsive.signal() }
        XCTAssertEqual(responsive.wait(timeout: .now() + 5), .success, "The host queue must keep serving requests")
    }

    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func set(_ next: Value) { lock.lock(); value = next; lock.unlock() }
        func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    }
}
