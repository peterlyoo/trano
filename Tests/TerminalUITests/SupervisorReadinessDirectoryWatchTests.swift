import Darwin
import Foundation
import XCTest
@testable import TranoApp

final class SupervisorReadinessDirectoryWatchTests: XCTestCase {
    // Implements: FR-SUP-7
    @MainActor func testAbsentDirectoryCanBeRegisteredAfterARootEventWithoutDuplicateWatchers() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let spy = WatchSpy()
        let watch = SupervisorReadinessDirectoryWatch(root: root, onChange: { spy.events += 1 }, makeWatch: spy.make)
        watch.reconcile()
        XCTAssertFalse(watch.isWatching)
        XCTAssertTrue(spy.tokens.isEmpty)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("input-state"), withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        watch.reconcile(); watch.reconcile()
        XCTAssertTrue(watch.isWatching)
        XCTAssertEqual(spy.tokens.count, 1)
        spy.tokens.first?.event(false)
        XCTAssertEqual(spy.events, 1)
        XCTAssertEqual(spy.tokens.count, 1)
        watch.stop()
    }

    // Implements: FR-SUP-7
    @MainActor func testStopAndDeinitCloseTheOwnedDescriptorExactlyOnce() throws {
        for explicitStop in [false, true] {
            let root = try directory(child: true); defer { try? FileManager.default.removeItem(at: root) }
            let spy = WatchSpy()
            var watch: SupervisorReadinessDirectoryWatch? = SupervisorReadinessDirectoryWatch(root: root, onChange: {}, makeWatch: spy.make)
            watch?.reconcile()
            let token = try XCTUnwrap(spy.tokens.first)
            XCTAssertNotEqual(fcntl(token.descriptor, F_GETFD), -1)
            if explicitStop { watch?.stop(); watch?.stop(); XCTAssertFalse(watch?.isWatching ?? true) }
            watch = nil
            XCTAssertEqual(token.cancels, 1)
            XCTAssertEqual(fcntl(token.descriptor, F_GETFD), -1)
        }
    }

    // Implements: FR-SUP-7
    @MainActor func testSymlinkPublicDirectoryAndRegularFileAreRejected() throws {
        for kind in 0..<3 {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let child = root.appendingPathComponent("input-state")
            if kind == 0 {
                let target = root.appendingPathComponent("owned")
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try FileManager.default.createSymbolicLink(at: child, withDestinationURL: target)
            } else if kind == 1 {
                try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
            } else { try Data().write(to: child) }
            let spy = WatchSpy()
            let watch = SupervisorReadinessDirectoryWatch(root: root, onChange: {}, makeWatch: spy.make)
            watch.reconcile()
            XCTAssertFalse(watch.isWatching)
            XCTAssertTrue(spy.tokens.isEmpty)
            watch.stop()
        }
    }

    // Implements: FR-SUP-7
    @MainActor func testDirectoryReplacementCancelsOldWatchAndReconcilesANewOne() throws {
        let root = try directory(child: true); defer { try? FileManager.default.removeItem(at: root) }
        let spy = WatchSpy()
        let watch = SupervisorReadinessDirectoryWatch(root: root, onChange: { spy.events += 1 }, makeWatch: spy.make)
        watch.reconcile()
        let first = try XCTUnwrap(spy.tokens.first)
        first.event(true)
        XCTAssertEqual(first.cancels, 1)
        XCTAssertEqual(spy.tokens.count, 2)
        XCTAssertEqual(spy.events, 1)
        XCTAssertTrue(watch.isWatching)
        watch.stop()
    }

    private func directory(child: Bool = false) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        if child { try FileManager.default.createDirectory(at: root.appendingPathComponent("input-state"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        return root
    }
}

@MainActor private final class WatchSpy {
    var tokens: [FakeToken] = []
    var events = 0
    func make(_ descriptor: Int32, _ event: @escaping @MainActor (Bool) -> Void, _ closed: @escaping @Sendable () -> Void) -> SupervisorReadinessWatchToken {
        let token = FakeToken(descriptor: descriptor, event: event, closed: closed)
        tokens.append(token); return token
    }
}
private final class FakeToken: SupervisorReadinessWatchToken, @unchecked Sendable {
    let descriptor: Int32
    let event: @MainActor (Bool) -> Void
    private let closed: @Sendable () -> Void
    private let lock = NSLock()
    private(set) var cancels = 0
    init(descriptor: Int32, event: @escaping @MainActor (Bool) -> Void, closed: @escaping @Sendable () -> Void) {
        self.descriptor = descriptor; self.event = event; self.closed = closed
    }
    func cancel() { lock.lock(); defer { lock.unlock() }; if cancels == 0 { cancels += 1; closed() } }
}
