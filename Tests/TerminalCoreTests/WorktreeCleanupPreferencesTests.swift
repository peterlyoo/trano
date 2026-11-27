import Foundation
import XCTest
@testable import TerminalCore

final class WorktreeCleanupPreferencesTests: XCTestCase {
    // Implements: FR-WT-5
    func testLegacyPreferencesEnableCleanupForFutureOwnedWorktreesOnly() throws {
        let legacy = try JSONDecoder().decode(IntegrationsPreferences.self, from: Data("{\"integrateWithAvailableAgents\":false,\"letAgentsNameSessions\":true}".utf8))
        XCTAssertTrue(legacy.automaticallyCleanWorktrees)
        XCTAssertFalse(legacy.integrateWithAvailableAgents)
        XCTAssertTrue(legacy.letAgentsNameSessions)
        var edited = legacy; edited.automaticallyCleanWorktrees = false
        let restored = try JSONDecoder().decode(IntegrationsPreferences.self, from: JSONEncoder().encode(edited))
        XCTAssertFalse(restored.automaticallyCleanWorktrees)
        XCTAssertEqual(restored.integrateWithAvailableAgents, legacy.integrateWithAvailableAgents)
    }
}
