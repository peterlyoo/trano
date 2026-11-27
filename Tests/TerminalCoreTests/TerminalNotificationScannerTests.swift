import Foundation
import XCTest
@testable import TerminalCore

final class TerminalNotificationScannerTests: XCTestCase {
    // Implements: FR-NOTIFY-2
    func testOSC9And777ParseAcrossChunksWithBellAndSTTerminators() {
        var scanner = TerminalNotificationScanner()
        XCTAssertTrue(scanner.feed(Data("text\u{1b}]777;not".utf8)).isEmpty)
        XCTAssertTrue(scanner.feed(Data("ify;Build;Complete\u{1b}".utf8)).isEmpty)
        XCTAssertEqual(scanner.feed(Data("\\more\u{1b}]9;Task completed\u{7}".utf8)), [TerminalProgramNotice(title: "Build", body: "Complete"), TerminalProgramNotice(title: "Terminal", body: "Task completed")])
        XCTAssertEqual(scanner.retainedByteCount, 0)
    }

    // Implements: FR-NOTIFY-2
    func testOversizedInvalidAndProgressSequencesAreIgnoredAndScannerRecovers() {
        var scanner = TerminalNotificationScanner()
        let oversized = Data(("\u{1b}]9;" + String(repeating: "x", count: 100_000)).utf8)
        XCTAssertTrue(scanner.feed(oversized).isEmpty)
        XCTAssertLessThanOrEqual(scanner.retainedByteCount, 4096)
        XCTAssertTrue(scanner.feed(Data("\u{7}\u{1b}]9;4;3\u{7}\u{1b}]777;other;Title;Body\u{7}".utf8)).isEmpty)
        XCTAssertEqual(scanner.feed(Data("\u{1b}]9;복구 완료\u{7}".utf8)), [TerminalProgramNotice(title: "Terminal", body: "복구 완료")])
    }

    // Implements: FR-NOTIFY-2
    func testNoticeTextIsBoundedAndControlCharactersAreRemoved() {
        var scanner = TerminalNotificationScanner()
        let title = String(repeating: "T", count: 200)
        let body = "hello\n" + String(repeating: "b", count: 1000)
        let notices = scanner.feed(Data(("\u{1b}]777;notify;" + title + ";" + body + "\u{7}").utf8))
        XCTAssertEqual(notices.first?.title.count, 100)
        XCTAssertEqual(notices.first?.body.count, 500)
        XCTAssertFalse(notices.first?.body.contains("\n") ?? true)
    }

    // Implements: FR-NOTIFY-2
    func testProgramNoticeGateHasBoundedRateAndIndependentEnableSwitch() {
        var gate = TerminalNotificationGate()
        XCTAssertFalse(gate.allow(now: 100, enabled: false))
        XCTAssertTrue(gate.allow(now: 100, enabled: true))
        XCTAssertFalse(gate.allow(now: 100.1, enabled: true))
        XCTAssertTrue(gate.allow(now: 105, enabled: true))
        XCTAssertFalse(gate.allow(now: .nan, enabled: true))
        XCTAssertFalse(gate.allow(now: 99, enabled: true))
    }
}
