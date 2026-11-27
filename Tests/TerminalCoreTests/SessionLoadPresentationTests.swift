import Foundation
import XCTest
@testable import TerminalCore

final class SessionLoadPresentationTests: XCTestCase {
    // Implements: FR-LOAD-1, FR-LOAD-3, FR-LOAD-4
    func testConcreteMetricsKeepUnitsAndMulticorePercent() {
        let snapshot = SessionLoadSnapshot(paneID: "pane", backendPID: 10, status: .available,
            cpuPercent: 154.4, residentBytes: 64 * 1_048_576,
            hook: SessionHookLatency(p99Milliseconds: 12.25, sampleCount: 3, status: .available))
        let presentation = SessionLoadPresentation(snapshot: snapshot, showHook: true)
        XCTAssertEqual(presentation.cpu, "CPU 154%")
        XCTAssertEqual(presentation.memory, "64 MiB")
        XCTAssertEqual(presentation.hook, "p99 12.3 ms")
        XCTAssertEqual(presentation.cpuFraction, 1)
        XCTAssertNil(presentation.status)
        XCTAssertTrue(presentation.accessibilityLabel.contains("154 percent CPU"))
        XCTAssertTrue(presentation.accessibilityLabel.contains("64 MiB resident memory"))
        XCTAssertTrue(presentation.accessibilityLabel.contains("3 individual Stop hooks"))
    }

    // Implements: FR-LOAD-1, FR-LOAD-3, FR-LOAD-4
    func testIdleZeroRemainsDifferentFromUnknownAndStale() {
        let idle = SessionLoadSnapshot(paneID: "pane", backendPID: 10, status: .available, cpuPercent: 0, residentBytes: 0)
        XCTAssertEqual(SessionLoadPresentation(snapshot: idle).cpu, "CPU 0%")
        XCTAssertEqual(SessionLoadPresentation(snapshot: idle).memory, "0 MiB")
        let missing = SessionLoadPresentation(snapshot: nil, showHook: true)
        XCTAssertEqual(missing.cpu, "CPU —")
        XCTAssertEqual(missing.memory, "— MiB")
        XCTAssertNil(missing.cpuFraction)
        XCTAssertEqual(missing.status, "Unavailable")
        XCTAssertEqual(missing.hook, "p99 —")
        var stale = idle
        stale.status = .stale
        stale.hook = SessionHookLatency(p99Milliseconds: 17, sampleCount: 3, status: .stale)
        let presentation = SessionLoadPresentation(snapshot: stale, showHook: true)
        XCTAssertEqual(presentation.cpu, "CPU —")
        XCTAssertEqual(presentation.memory, "— MiB")
        XCTAssertEqual(presentation.status, "Stale")
        XCTAssertEqual(presentation.hook, "p99 stale")
    }

    // Implements: FR-LOAD-1, FR-LOAD-3, FR-LOAD-4
    func testHistoryPreservesUnknownGapsAndBoundsRendering() {
        let history = (0..<80).map { index in
            SessionLoadPoint(observedAt: Date(timeIntervalSince1970: Double(index)),
                cpuPercent: index == 30 ? nil : Double(index * 2), residentBytes: 10)
        }
        let snapshot = SessionLoadSnapshot(paneID: "pane", backendPID: 10, status: .available,
            cpuPercent: 158, residentBytes: 10, history: history)
        let presentation = SessionLoadPresentation(snapshot: snapshot)
        XCTAssertEqual(presentation.historyFractions.count, 60)
        guard presentation.historyFractions.count == 60 else { return }
        XCTAssertNil(presentation.historyFractions[10])
        XCTAssertEqual(presentation.historyFractions[59], 1)
        XCTAssertTrue(presentation.historyFractions.compactMap { $0 }.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    // Implements: FR-LOAD-1, FR-LOAD-3, FR-LOAD-4
    func testInvalidNumbersAndNonClaudeHookAreNotRendered() {
        let snapshot = SessionLoadSnapshot(paneID: "pane", backendPID: 10, status: .available,
            cpuPercent: .infinity, residentBytes: UInt64.max,
            hook: SessionHookLatency(p99Milliseconds: .nan, sampleCount: 4, status: .available),
            history: [SessionLoadPoint(observedAt: Date(), cpuPercent: -.infinity, residentBytes: nil)])
        let presentation = SessionLoadPresentation(snapshot: snapshot)
        XCTAssertEqual(presentation.cpu, "CPU —")
        XCTAssertNil(presentation.cpuFraction)
        XCTAssertNil(presentation.hook)
        XCTAssertEqual(presentation.historyFractions.count, 1)
        guard presentation.historyFractions.count == 1 else { return }
        XCTAssertNil(presentation.historyFractions[0])
        XCTAssertFalse(presentation.memory.lowercased().contains("inf"))
        XCTAssertEqual(SessionLoadPresentation(snapshot: snapshot, showHook: true).hook, "p99 —")
        let extreme = SessionLoadSnapshot(paneID: "pane", backendPID: 10, status: .available, cpuPercent: 1,
            hook: SessionHookLatency(p99Milliseconds: 1e308, sampleCount: 1, status: .available))
        XCTAssertFalse(SessionLoadPresentation(snapshot: extreme, showHook: true).hook?.contains("inf") == true)
        XCTAssertFalse(SessionLoadPresentation(snapshot: extreme, showHook: true).hook?.contains("∞") == true)
        XCTAssertEqual(SessionLoadPresentation(snapshot: extreme, showHook: true).hook?.lowercased(), "p99 1.0e+308 ms")
    }
}
