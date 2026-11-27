import XCTest
@testable import TerminalCore
@testable import TranoCLI

final class PtyHostInputBackpressureTests: XCTestCase {
    // Implements: FR-INPUT-1
    func testInputLargerThanThePTYQueueReachesTheChildInFullAndLaterInputFollows() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("trano-input-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: output) }
        let paste = [UInt8](repeating: 0x61, count: 20_000), typed = Array("typed".utf8)
        let total = paste.count + typed.count
        let pane = HostedPane(id: UUID().uuidString.lowercased(), cols: 80, rows: 24)
        let spawned = DispatchSemaphore(value: 0)
        hostQueue.async {
            // The child sleeps before reading, so the first write fills the PTY input queue and leaves a remainder.
            try? pane.spawn(argv: ["/bin/sh", "-c", "stty raw -echo; sleep 1; exec head -c \(total) > '\(output.path)'"],
                            environment: ["PATH=/usr/bin:/bin"], cwd: nil)
            spawned.signal()
        }
        XCTAssertEqual(spawned.wait(timeout: .now() + 10), .success)
        usleep(400_000)
        hostQueue.async { pane.enqueue(paste); pane.enqueue(typed) }
        let deadline = Date().addingTimeInterval(15)
        var received = Data()
        while received.count < total, Date() < deadline {
            usleep(50_000)
            received = (try? Data(contentsOf: output)) ?? Data()
        }
        let finished = DispatchSemaphore(value: 0)
        hostQueue.async { pane.terminate(waitForExit: true); finished.signal() }
        XCTAssertEqual(finished.wait(timeout: .now() + 20), .success)
        XCTAssertEqual(received.count, total, "Input beyond the PTY queue must not be stranded")
        XCTAssertEqual(Array(received.suffix(typed.count)), typed, "Input sent after a large paste must arrive after it")
    }
}
