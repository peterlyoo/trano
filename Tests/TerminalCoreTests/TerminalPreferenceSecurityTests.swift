import Darwin
import Foundation
import XCTest
@testable import TerminalCore

final class TerminalPreferenceSecurityTests: XCTestCase {
    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var captured: Error?
        func record(_ error: Error) { lock.lock(); defer { lock.unlock() }; captured = error }
        var failed: Bool { lock.lock(); defer { lock.unlock() }; return captured != nil }
    }

    // Implements: FR-SET-66
    func testNamedPipeIsRejectedBeforeWaitingForAWriter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trano-prefs-fifo-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TerminalPreferenceStore(root: root)
        XCTAssertEqual(mkfifo(store.url.path, 0o600), 0)
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let outcome = Outcome()
        DispatchQueue.global(qos: .userInitiated).async {
            started.signal()
            do { _ = try store.load() } catch { outcome.record(error) }
            finished.signal()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        let immediate = finished.wait(timeout: .now() + 0.5)
        if immediate == .timedOut {
            let unblock = open(store.url.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
            defer { if unblock >= 0 { close(unblock) } }
            XCTAssertGreaterThanOrEqual(unblock, 0)
            XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        }
        XCTAssertEqual(immediate, .success, "A preferences FIFO must not hold a configuration worker waiting for a writer")
        XCTAssertTrue(outcome.failed)
    }
}
