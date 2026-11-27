import XCTest
@testable import TerminalCore
@testable import TranoCLI

final class MonitorIdentityTests: XCTestCase {
    private let paneID = "22222222-2222-4222-8222-222222222222"

    // Implements: FR-CLOSE-2, FR-CLOSE-7
    func testMonitorPreservesThePIDCapturedWhenItsPipeWasCreated() throws {
        let invocation = try MonitorCLI.parse([paneID, "4321"])
        XCTAssertEqual(invocation.paneID, paneID)
        XCTAssertEqual(invocation.expectedPID, 4321)
        XCTAssertEqual(try MonitorCLI.parse([paneID, String(Int32.max)]).expectedPID, Int32.max)
    }

    // Implements: FR-CLOSE-2, FR-CLOSE-7
    func testMonitorRefusesLegacyInvocationWithoutAProcessIdentity() {
        for arguments in [[], [paneID], [paneID, "4321", "extra"]] {
            XCTAssertThrowsError(try MonitorCLI.parse(arguments), "Arguments: \(arguments)")
        }
    }

    // Implements: FR-CLOSE-2, FR-CLOSE-7
    func testMonitorRefusesInvalidPaneAndProcessIdentities() {
        for arguments in [["not-a-pane", "4321"], [paneID, "0"], [paneID, "-1"],
                          [paneID, "2147483648"], [paneID, ""], [paneID, "newest"],
                          [paneID, "4.5"], [paneID, " 4321"]] {
            XCTAssertThrowsError(try MonitorCLI.parse(arguments), "Arguments: \(arguments)")
        }
    }

    // Implements: FR-CLOSE-2, FR-CLOSE-7
    func testDelayedMonitorDoesNotAdoptAReopenedPanesPIDOrChangeItsState() throws {
        let root = URL(fileURLWithPath: "/tmp/trano-monitor-" + UUID().uuidString.prefix(12))
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try TerminalRuntime(root: root)
        let invocation = try MonitorCLI.parse([paneID, "4321"])
        try runtime.update { state in
            state.sessions = [TerminalSession(id: paneID, title: "Fresh shell", cwd: root.path, pid: 4322)]
        }
        let before = try runtime.state()

        try monitorPane(invocation.paneID, expectedPID: invocation.expectedPID, runtime: runtime)

        let after = try runtime.state()
        XCTAssertEqual(after.revision, before.revision)
        XCTAssertEqual(after.sessions, before.sessions)
        XCTAssertTrue(after.followUpPasteStates.isEmpty)
        XCTAssertEqual(invocation.expectedPID, 4321)
    }
}
