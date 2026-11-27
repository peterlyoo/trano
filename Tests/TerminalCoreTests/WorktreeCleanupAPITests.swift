import Foundation
import XCTest
@testable import TerminalCore

final class WorktreeCleanupAPITests: XCTestCase {
    // Implements: FR-WT-5
    func testMetadataStatusAndLocalPreferenceDoNotLaunchGitOrTerminalJobs() throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("trano-wt-api-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try TerminalRuntime(root: root)
        let service = APIService(runtime: runtime)
        let status = service.route(APIRequest(method: "worktrees.status"))
        XCTAssertNil(status.error)
        XCTAssertEqual(status.result?["enabled"], .bool(true))
        XCTAssertEqual(status.result?["records"], .array([]))
        let denied = service.route(APIRequest(method: "worktrees.configure", params: ["enabled": .bool(false)]))
        XCTAssertNotNil(denied.error)
        for method in ["worktrees.retry", "worktrees.keep", "worktrees.diagnostics"] {
            XCTAssertNotNil(service.route(APIRequest(method: method, params: ["id": .string("unknown")])).error)
        }
        let changed = service.route(APIRequest(method: "worktrees.configure", params: ["enabled": .bool(false)]), originPID: getpid())
        XCTAssertNil(changed.error)
        XCTAssertFalse(try runtime.integrationsPreferences().automaticallyCleanWorktrees)
        XCTAssertTrue(try runtime.state().sessions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("worktree-cleanup.json").path))
    }
}
