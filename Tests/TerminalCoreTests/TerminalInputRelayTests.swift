import XCTest
@testable import TerminalCore

private final class RelayProbe: @unchecked Sendable {
    let lock = NSLock()
    var deliveries: [[UInt8]] = []
    var segments: [[TerminalUserInputSegment]] = []
    var callbacks: [TerminalInputRelay.Completion] = []
    var wasMain: [Bool] = []
    var onDelivery: (() -> Void)?
    var onInvalidated: (() -> Void)?
    func deliver(_ bytes: [UInt8], segments value: [TerminalUserInputSegment], completion: @escaping TerminalInputRelay.Completion) {
        lock.lock(); deliveries.append(bytes); segments.append(value); callbacks.append(completion); wasMain.append(Thread.isMainThread); let onDelivery = onDelivery; lock.unlock(); onDelivery?()
    }
    func snapshot() -> ([[UInt8]], [[TerminalUserInputSegment]], [Bool]) { lock.lock(); defer { lock.unlock() }; return (deliveries, segments, wasMain) }
    func finish(_ index: Int, written: Int? = nil) { lock.lock(); let callback = callbacks[index]; let count = deliveries[index].count; lock.unlock(); callback(.success(written ?? count)) }
}

final class TerminalInputRelayTests: XCTestCase {
    private func relay(_ probe: RelayProbe, limit: Int = 1_114_112, batch: Int = 8192, delay: Int = 8) -> TerminalInputRelay {
        TerminalInputRelay(limitBytes: limit, batchBytes: batch, delayMilliseconds: delay, deliver: { bytes, segments, _, completion in
            probe.deliver(bytes, segments: segments, completion: completion)
        }, invalidated: { _ in probe.onInvalidated?() })
    }
    private let writer: TerminalInputRelay.Writer = { bytes, done in done(.success(bytes.count)) }
    // Implements: FR-INPUT-1
    func testIdleInteractiveInputDoesNotWaitForABatchTimer() {
        let delivered = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let relay = TerminalInputRelay(deliver: { bytes, _, write, finish in
            write(bytes) { result in finish(result); completed.signal() }
            delivered.signal()
        }, invalidated: { reason in XCTFail(reason) })
        var samples: [Double] = []
        for _ in 0..<24 {
            let start = DispatchTime.now().uptimeNanoseconds
            XCTAssertTrue(relay.send([97], user: true, write: writer))
            XCTAssertEqual(delivered.wait(timeout: .now() + 2), .success)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        }
        let mean = samples.reduce(0, +) / Double(samples.count)
        print("RELAY_IDLE_LATENCY_MS mean=\(mean) p50=\(samples.sorted()[12]) max=\(samples.max() ?? 0)")
        XCTAssertLessThan(mean, 6, "Idle typing must dispatch without the fixed 8ms coalescing wait")
    }
    // Implements: FR-INPUT-1
    func testDistinctAdmissionKeysKeepOrdinaryProtectedAndLaterOrdinaryWritersSeparate() {
        let probe = RelayProbe(), sent = expectation(description: "three authority batches")
        sent.expectedFulfillmentCount = 3; probe.onDelivery = { sent.fulfill() }
        let relay = TerminalInputRelay(delayMilliseconds: 20, deliver: { bytes, _, write, completion in
            write(bytes, completion)
        }, invalidated: { _ in XCTFail("Input unexpectedly invalidated") })
        let ordinary: TerminalInputRelay.Writer = { bytes, completion in
            XCTAssertTrue(bytes == [1] || bytes == [4])
            probe.deliver(bytes, segments: [], completion: completion); completion(.success(bytes.count))
        }
        let protected: TerminalInputRelay.Writer = { bytes, completion in
            XCTAssertEqual(bytes, [2, 3])
            probe.deliver(bytes, segments: [], completion: completion); completion(.success(bytes.count))
        }
        let key = UUID()
        relay.send([1], user: true, write: ordinary)
        relay.send([2], user: true, coalescingKey: key, write: protected)
        relay.send([3], user: true, coalescingKey: key, write: protected)
        relay.send([4], user: true, write: ordinary)
        wait(for: [sent], timeout: 1)
        XCTAssertEqual(probe.snapshot().0, [[1], [2, 3], [4]])
    }
    // Implements: FR-QUEUE-5
    func testNativeInputCoalescesOffMainAndSplitsSubmissionFromSuffix() {
        let probe = RelayProbe(); let sent = expectation(description: "batch"); sent.assertForOverFulfill = false; probe.onDelivery = { sent.fulfill() }
        let relay = relay(probe, delay: 20)
        XCTAssertTrue(relay.send(Array("prompt\r".utf8), user: true, write: writer))
        XCTAssertTrue(relay.send(Array("draft".utf8), user: true, write: writer))
        wait(for: [sent], timeout: 1)
        let result = probe.snapshot()
        XCTAssertEqual(result.0.map { String(decoding: $0, as: UTF8.self) }, ["prompt\rdraft"])
        XCTAssertEqual(result.1[0].map(\.submissionCandidate), [true, false])
        XCTAssertEqual(result.2, [false])
    }
    // Implements: FR-QUEUE-5
    func testSlowWriterKeepsSingleFlightAndBoundedPendingInput() {
        let probe = RelayProbe(); let first = expectation(description: "first"); probe.onDelivery = { first.fulfill() }
        let relay = relay(probe, limit: 8, batch: 4, delay: 0)
        relay.send([1, 2, 3, 4], user: true, write: writer)
        wait(for: [first], timeout: 1); probe.onDelivery = nil
        XCTAssertTrue(relay.send([5, 6, 7, 8], user: true, write: writer))
        XCTAssertFalse(relay.send([9], user: true, write: writer))
        XCTAssertEqual(probe.snapshot().0.count, 1)
        let second = expectation(description: "second"); probe.onDelivery = { second.fulfill() }; probe.finish(0)
        wait(for: [second], timeout: 1)
        XCTAssertEqual(probe.snapshot().0, [[1, 2, 3, 4], [5, 6, 7, 8]])
    }
    // Implements: FR-QUEUE-5
    func testImmediateDrainShortWriteCancelsPendingInputWithoutRetry() {
        let probe = RelayProbe(), first = expectation(description: "first write")
        let invalidated = expectation(description: "partial write invalidates relay")
        probe.onDelivery = { first.fulfill() }
        probe.onInvalidated = { invalidated.fulfill() }
        let relay = relay(probe, limit: 8, batch: 4, delay: 0)
        XCTAssertTrue(relay.send([1, 2, 3, 4], user: true, write: writer))
        wait(for: [first], timeout: 1)
        probe.onDelivery = nil
        XCTAssertTrue(relay.send([5, 6, 7, 8], user: true, write: writer))
        probe.finish(0, written: 2)
        wait(for: [invalidated], timeout: 1)
        XCTAssertEqual(probe.snapshot().0, [[1, 2, 3, 4]])
        XCTAssertFalse(relay.send([9], user: true, write: writer))
    }
    // Implements: FR-QUEUE-5
    func testCancelDropsPendingBytesAndReportsUncertainInput() {
        let probe = RelayProbe(); let invalidated = expectation(description: "cancel"); probe.onInvalidated = { invalidated.fulfill() }
        let relay = relay(probe, delay: 30)
        relay.send([1, 2], user: true, write: writer); relay.cancel()
        wait(for: [invalidated], timeout: 1)
        XCTAssertEqual(probe.snapshot().0.count, 0)
        XCTAssertFalse(relay.send([3], user: true, write: writer))
    }
    // Implements: FR-QUEUE-5
    func testProtocolRepliesDoNotCreateManualInputSegments() {
        let probe = RelayProbe(); let sent = expectation(description: "response"); probe.onDelivery = { sent.fulfill() }
        let relay = relay(probe)
        relay.send(Array("\u{1b}[1;2R".utf8), user: false, write: writer)
        wait(for: [sent], timeout: 1)
        XCTAssertEqual(probe.snapshot().1, [[]])
    }
}
