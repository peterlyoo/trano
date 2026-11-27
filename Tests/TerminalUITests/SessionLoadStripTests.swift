import AppKit
import SwiftUI
import TerminalCore
import XCTest
@testable import TranoApp

final class SessionLoadStripTests: XCTestCase {
    // Implements: FR-LOAD-3, FR-LOAD-4
    @MainActor func testCachedStripHasCompactIntrinsicHeightAtActivityWidth() {
        let snapshot = SessionLoadSnapshot(paneID: "pane", backendPID: 10, status: .available,
            cpuPercent: 145, residentBytes: 64 * 1_048_576,
            hook: SessionHookLatency(p99Milliseconds: 17, sampleCount: 2, status: .available),
            history: (0..<60).map { SessionLoadPoint(observedAt: Date(timeIntervalSince1970: Double($0)),
                cpuPercent: Double($0 * 2), residentBytes: 1) })
        let host = NSHostingView(rootView: SessionLoadStrip(snapshot: snapshot, showHook: true).frame(width: 240))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 10)
        XCTAssertLessThanOrEqual(host.fittingSize.height, 36)
        XCTAssertLessThanOrEqual(host.fittingSize.width, 240)
    }

    // Implements: FR-LOAD-1, FR-LOAD-3, FR-LOAD-4
    @MainActor func testUnavailableStripKeepsAStableCompactLayout() {
        let host = NSHostingView(rootView: SessionLoadStrip(snapshot: nil, showHook: true).frame(width: 240))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 10)
        XCTAssertLessThanOrEqual(host.fittingSize.height, 36)
        XCTAssertLessThanOrEqual(host.fittingSize.width, 240)
    }
}
