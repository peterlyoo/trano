import Foundation
import XCTest
@testable import TerminalCore

final class SupervisorInstructionsTests: XCTestCase {
    // Implements: FR-SUP-2, FR-SUP-4
    func testPublicInstructionsContainConcreteNativeCommandsAndFailClosedContinuation() {
        let text = SupervisorInstructions.prompt
        XCTAssertFalse(text.isEmpty)
        XCTAssertLessThanOrEqual(text.utf8.count, 32_768)
        for required in ["supervisor state", "supervisor watch", "sessions.list", "input_review_required", "decisions.list", "TRANO_CLI_PATH"] {
            XCTAssertTrue(text.contains(required), required)
        }
        for forbidden in ["/Users/", "sendbird", "slack.com", "rex ", "panes.send", "sleep 30", "password"] {
            XCTAssertFalse(text.lowercased().contains(forbidden.lowercased()), forbidden)
        }
    }

    // Implements: FR-SUP-2, FR-SUP-5
    func testDefaultInstructionsExceedSmallCanonicalLinesAndStayOffTerminalInput() throws {
        let bytes = SupervisorInstructions.prompt.utf8.count
        print("Supervisor default instruction bytes: \(bytes)")
        XCTAssertGreaterThan(bytes, 1024)
        let arguments = try SupervisorBootstrap.arguments(gateName: "sg-12ab34cd", nonce: UUID().uuidString.lowercased())
        XCTAssertEqual(arguments.count, 3)
        XCTAssertEqual(arguments.first, "supervisor-bootstrap")
        XCTAssertLessThan(arguments.joined(separator: " ").utf8.count, 128)
        XCTAssertFalse(arguments.contains(SupervisorInstructions.prompt))
    }
}
