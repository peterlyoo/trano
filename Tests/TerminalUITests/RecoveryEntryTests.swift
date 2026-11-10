import Foundation
import XCTest

final class RecoveryEntryTests: XCTestCase {
    // Implements: U01, U07, FR-RECOVERY-2
    func testNativeRecoveryEntryPointsReleaseSharedTransactionBeforeSSH() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var count = 0
        for name in ["Store.swift", "WorkspaceView.swift"] {
            let source = try String(contentsOf: project.appendingPathComponent("Sources/TranoApp/" + name), encoding: .utf8)
            for line in source.split(separator: "\n") where line.contains("recoverSessions(") {
                count += 1
                XCTAssertTrue(line.contains("holdingTransaction: false"), name + " wraps SSH recovery in a shared transaction: " + line)
            }
        }
        XCTAssertGreaterThanOrEqual(count, 3)
    }
}
