import XCTest
@testable import TerminalCore

final class PessimisticTwinPrivateReadTests: XCTestCase {
    // Implements: FR-TWIN-3, FR-TWIN-4, FR-TWIN-10
    func testNativeCodexPolicyDeniesSiblingProfilesAndKeepsOnlyOwnedWorkspaceWritable() throws {
        let policy = try TwinProviderSandbox.profile(worktree: "/runtime/twins/own/worktree", privateProfileRoot: "/runtime/twins/own/profile",
            apiSocketPath: "/runtime/twin.sock", sourceConfigurationRoot: "/source/profile")
        XCTAssertTrue(policy.contains("\"/runtime\" = \"deny\""))
        XCTAssertTrue(policy.contains("\"/runtime/twins/own/worktree\" = true"))
        XCTAssertTrue(policy.contains("\":workspace_roots\" = \"write\""))
        XCTAssertTrue(policy.contains("\"/runtime/twins/own/profile\" = \"deny\""))
        XCTAssertFalse(policy.contains("\"/runtime/twins/own\" = \"write\""))
    }
    func testRootOrCheckoutSocketCannotOverrideThePrivateReadBoundary() {
        for socket in ["/twin.sock", "/checkout/twin.sock", "/profile/twin.sock"] {
            XCTAssertThrowsError(try TwinProviderSandbox.profile(worktree: "/checkout", privateProfileRoot: "/profile", apiSocketPath: socket))
        }
    }
}
