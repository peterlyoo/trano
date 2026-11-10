import XCTest
@testable import TerminalCore

final class CompletionIntegrationTests: XCTestCase {
    // Implements: FR-RECOVERY-1
    func testInteractiveDetectionDoesNotInterpretOptionValuesAsCommands() {
        XCTAssertTrue(AgentInvocation.isInteractive(["claude", "--model", "auth", "review"], provider: .claude))
        XCTAssertTrue(AgentInvocation.isInteractive(["codex", "--profile", "review", "resume", "abc"], provider: .codex))
        XCTAssertTrue(AgentInvocation.isInteractive(["codex", "--", "--help"], provider: .codex))
        XCTAssertFalse(AgentInvocation.isInteractive(["codex", "--profile", "work", "review"], provider: .codex))
        XCTAssertFalse(AgentInvocation.isInteractive(["claude", "--settings", "work.json", "auth", "login"], provider: .claude))
        XCTAssertFalse(AgentInvocation.isInteractive(["claude", "-p", "hello"], provider: .claude))
    }

    // Implements: U10, U11
    func testDirectionalResizeFindsMatchingAncestorAndSharedBoundary() {
        let tree = PaneTree.split(id: "outer", axis: .horizontal, ratio: 0.5,
            first: .pane("a"), second: .split(id: "inner", axis: .vertical, ratio: 0.5, first: .pane("b"), second: .pane("c")))
        XCTAssertEqual(tree.resizeTarget(paneID: "c", direction: .left)?.splitID, "outer")
        XCTAssertEqual(tree.resizeTarget(paneID: "c", direction: .left)?.ratio, 0.45)
        XCTAssertEqual(tree.resizeTarget(paneID: "c", direction: .up)?.splitID, "inner")
        XCTAssertEqual(tree.resizeTarget(paneID: "c", direction: .up)?.ratio, 0.45)
        XCTAssertEqual(tree.resizeTarget(paneID: "b", direction: .down)?.ratio, 0.55)
        XCTAssertNil(tree.resizeTarget(paneID: "a", direction: .down))
    }

    // Implements: U18, U19
    func testSupervisionRejectsSwitchWhileToolsAreActiveAndRequiresTurnBoundary() {
        var supervision = AgentSupervision(generation: "launch")
        supervision.observe(event: "SessionStart", toolID: nil)
        XCTAssertTrue(supervision.safeToSwitch)
        supervision.observe(event: "UserPromptSubmit", toolID: nil)
        XCTAssertFalse(supervision.safeToSwitch)
        supervision.observe(event: "PreToolUse", toolID: "one")
        supervision.observe(event: "PreToolUse", toolID: "two")
        supervision.observe(event: "PostToolUse", toolID: "one")
        supervision.observe(event: "StopFailure", toolID: nil)
        XCTAssertFalse(supervision.safeToSwitch)
        supervision.observe(event: "PostToolUseFailure", toolID: "two")
        XCTAssertTrue(supervision.safeToSwitch)
        supervision.observe(event: "UserPromptSubmit", toolID: nil)
        supervision.observe(event: "PreToolUse", toolID: nil)
        supervision.observe(event: "Stop", toolID: nil)
        XCTAssertFalse(supervision.safeToSwitch)
    }
}
