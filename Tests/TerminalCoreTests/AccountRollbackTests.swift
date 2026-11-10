import XCTest
@testable import TerminalCore

final class AccountRollbackTests: XCTestCase {
    private let tables = ["thread_items", "thread_turns", "thread_realtime_items", "thread_history_projection_state"]

    private struct Fixture {
        let runtime: TerminalRuntime
        let source: URL
        let target: URL
        let directory: URL
        let sessionID: String
        let relative: String
        let receipt: AccountTransferReceipt
    }

    private func sql(_ root: URL, file: String, statement: String) throws -> Data {
        let result = try CommandRunner.run("/usr/bin/sqlite3", ["-bail", root.appendingPathComponent(file).path], input: Data(statement.utf8))
        guard result.status == 0 else { throw TerminalError.runtime("Rollback fixture SQL failed") }
        return result.stdout
    }

    private func fixture() throws -> Fixture {
        let runtime = try TerminalRuntime(root: URL(fileURLWithPath: "/tmp/trano-rollback-" + UUID().uuidString.prefix(8)))
        let sourceAccount = try runtime.addAccount(provider: .codex, label: "Source")
        let targetAccount = try runtime.addAccount(provider: .codex, label: "Target")
        let source = try runtime.accountRoot(sourceAccount.id), target = try runtime.accountRoot(targetAccount.id)
        let sessionID = UUID().uuidString.lowercased(), pane = UUID().uuidString.lowercased()
        let relative = "sessions/2026/11/11/rollout-fixture-" + sessionID + ".jsonl"
        let rollout = try AccountSessionFiles.path(relative, beneath: source, createParents: true)
        try Data(("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(sessionID)\",\"cwd\":\"/tmp\"}}\n").utf8).write(to: rollout)
        let oldRollout = try AccountSessionFiles.path(relative, beneath: target, createParents: true)
        try Data("previous target rollout\n".utf8).write(to: oldRollout)
        for (root, title) in [(source, "source"), (target, "previous")] {
            _ = try sql(root, file: "state_5.sqlite", statement: "CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT, title TEXT); INSERT INTO threads VALUES ('\(sessionID)', '/\(title)', '\(title)');")
            let history = tables.map {
                "CREATE TABLE \($0)(thread_id TEXT, payload TEXT); INSERT INTO \($0) VALUES ('\(sessionID)', '\(title)'); INSERT INTO \($0) VALUES ('unrelated', 'keep');"
            }.joined(separator: "\n")
            _ = try sql(root, file: "thread_history_1.sqlite", statement: history)
        }
        let launch = AgentLaunch(paneID: pane, provider: .codex, providerSessionID: sessionID, cwd: "/tmp", accountID: sourceAccount.id, configurationRoot: source.path, bootID: try TerminalRuntime.bootIdentity(), processID: nil, providerPID: nil)
        try runtime.update {
            $0.sessions.append(TerminalSession(id: pane, title: "Fixture", cwd: "/tmp", pid: 0))
            $0.agentLaunches.append(launch)
        }
        let plan = try runtime.prepareAccountSwitch(paneID: pane, targetAccountID: targetAccount.id, expectedGeneration: launch.id, toolsInFlight: false, safeTurnBoundary: true)
        let receipt = try runtime.transferAccountSession(plan)
        return Fixture(runtime: runtime, source: source, target: target, directory: runtime.root.appendingPathComponent("account-transfers/" + receipt.id), sessionID: sessionID, relative: relative, receipt: receipt)
    }

    private func targetSnapshot(_ fixture: Fixture) throws -> [Data] {
        let state = try sql(fixture.target, file: "state_5.sqlite", statement: "SELECT * FROM threads ORDER BY id;")
        let history = try tables.map { try sql(fixture.target, file: "thread_history_1.sqlite", statement: "SELECT * FROM \($0) ORDER BY thread_id, payload;") }
        return [state] + history
    }

    // Implements: FR-ACCOUNT-2
    func testHistoryOnlyTargetChangesRefuseRollbackBeforeAnyMutation() throws {
        for table in tables {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
            _ = try sql(fixture.target, file: "thread_history_1.sqlite", statement: "UPDATE \(table) SET payload = 'new target work' WHERE thread_id = '\(fixture.sessionID)';")
            let before = try targetSnapshot(fixture)
            let rollout = try AccountSessionFiles.path(fixture.relative, beneath: fixture.target)
            let bytes = try Data(contentsOf: rollout)
            XCTAssertThrowsError(try fixture.runtime.rollbackAccountTransfer(fixture.receipt), table)
            XCTAssertEqual(try targetSnapshot(fixture), before, table)
            XCTAssertEqual(try Data(contentsOf: rollout), bytes, table)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.path), table)
        }
    }

    // Implements: FR-ACCOUNT-2
    func testInvalidHistoryBackupCannotRestoreMetadataOrRolloutFirst() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
        let before = try targetSnapshot(fixture)
        let rollout = try AccountSessionFiles.path(fixture.relative, beneath: fixture.target)
        let bytes = try Data(contentsOf: rollout)
        try Data("{}".utf8).write(to: fixture.directory.appendingPathComponent("history-previous.json"))
        XCTAssertThrowsError(try fixture.runtime.rollbackAccountTransfer(fixture.receipt))
        XCTAssertEqual(try targetSnapshot(fixture), before)
        XCTAssertEqual(try Data(contentsOf: rollout), bytes)
    }

    // Implements: FR-ACCOUNT-2
    func testMissingRolloutBackupIsPreflightedEvenWhenDestinationIsAbsent() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
        let before = try targetSnapshot(fixture)
        let rollout = try AccountSessionFiles.path(fixture.relative, beneath: fixture.target)
        try FileManager.default.removeItem(at: rollout)
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("backup/" + fixture.relative))
        XCTAssertThrowsError(try fixture.runtime.rollbackAccountTransfer(fixture.receipt))
        XCTAssertEqual(try targetSnapshot(fixture), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rollout.path))
    }

    // Implements: FR-ACCOUNT-2
    func testLegacyHistoryReceiptWithoutInstalledProofPreservesTargetRows() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
        let proof = fixture.directory.appendingPathComponent("history-transfer.json")
        if FileManager.default.fileExists(atPath: proof.path) { try FileManager.default.removeItem(at: proof) }
        let before = try targetSnapshot(fixture)
        XCTAssertThrowsError(try fixture.runtime.rollbackAccountTransfer(fixture.receipt))
        XCTAssertEqual(try targetSnapshot(fixture), before)
    }

    // Implements: FR-ACCOUNT-2
    func testPartialHistoryInstallWithOldRowsCanRollbackFromSidecarReceipt() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
        for table in tables {
            _ = try sql(fixture.target, file: "thread_history_1.sqlite", statement: "UPDATE \(table) SET payload = 'previous' WHERE thread_id = '\(fixture.sessionID)';")
        }
        var partial = fixture.receipt
        partial.database = nil
        try JSONEncoder().encode(partial).write(to: fixture.directory.appendingPathComponent("receipt.json"))
        var database = try XCTUnwrap(fixture.receipt.database)
        database.historyReset = false
        try JSONEncoder().encode(database).write(to: fixture.directory.appendingPathComponent("database-transfer.json"))
        try fixture.runtime.rollbackAccountTransfer(partial)
        XCTAssertEqual(try sql(fixture.target, file: "state_5.sqlite", statement: "SELECT title FROM threads WHERE id = '\(fixture.sessionID)';"), Data("previous\n".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.target.appendingPathComponent(fixture.relative)), Data("previous target rollout\n".utf8))
    }

    // Implements: FR-ACCOUNT-2
    func testRepeatedDatabaseRollbackAcceptsAlreadyRestoredRows() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
        let database = try XCTUnwrap(fixture.receipt.database)
        try database.rollback(target: fixture.target, backup: fixture.directory)
        let before = try targetSnapshot(fixture)
        try database.rollback(target: fixture.target, backup: fixture.directory)
        XCTAssertEqual(try targetSnapshot(fixture), before)
    }

    // Implements: FR-ACCOUNT-2
    func testMissingReceiptDirectoryIsAnErrorWithoutRecreatingIt() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
        try FileManager.default.removeItem(at: fixture.directory)
        let before = try targetSnapshot(fixture)
        XCTAssertThrowsError(try fixture.runtime.rollbackAccountTransfer(fixture.receipt))
        XCTAssertEqual(try targetSnapshot(fixture), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    // Implements: FR-ACCOUNT-2
    func testHistoryWriteFailureRollsBackTheMetadataTransaction() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
        _ = try sql(fixture.target, file: "thread_history_1.sqlite", statement: "CREATE TRIGGER reject_restore BEFORE INSERT ON thread_history_projection_state WHEN NEW.payload = 'previous' BEGIN SELECT RAISE(ABORT, 'fixture failure'); END;")
        let before = try targetSnapshot(fixture)
        let rollout = try Data(contentsOf: fixture.target.appendingPathComponent(fixture.relative))
        XCTAssertThrowsError(try fixture.runtime.rollbackAccountTransfer(fixture.receipt))
        XCTAssertEqual(try targetSnapshot(fixture), before)
        XCTAssertEqual(try Data(contentsOf: fixture.target.appendingPathComponent(fixture.relative)), rollout)
    }

    // Implements: FR-ACCOUNT-2
    func testHistoryChangesAfterPreflightCannotCommitMetadataRestoration() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
        let plan = try XCTUnwrap(fixture.receipt.database).prepareRollback(target: fixture.target, backup: fixture.directory)
        _ = try sql(fixture.target, file: "thread_history_1.sqlite", statement: "INSERT INTO thread_turns VALUES ('\(fixture.sessionID)', 'new concurrent turn');")
        let before = try targetSnapshot(fixture)
        XCTAssertThrowsError(try plan.apply())
        XCTAssertEqual(try targetSnapshot(fixture), before)
    }

    // Implements: FR-ACCOUNT-2
    func testChangedRolloutBackupIsRejectedBeforeDatabaseMutation() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
        let before = try targetSnapshot(fixture)
        try Data("corrupt readable backup\n".utf8).write(to: fixture.directory.appendingPathComponent("backup/" + fixture.relative))
        XCTAssertThrowsError(try fixture.runtime.rollbackAccountTransfer(fixture.receipt))
        XCTAssertEqual(try targetSnapshot(fixture), before)
    }

    // Implements: FR-ACCOUNT-2
    func testChangedMetadataBackupIsRejectedBeforeAnyRestoration() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
        let before = try targetSnapshot(fixture)
        let backup = fixture.directory.appendingPathComponent("database-previous.json")
        var rows = try JSONDecoder().decode([[String: JSONValue]].self, from: Data(contentsOf: backup))
        rows[0]["title"] = .string("corrupt readable backup")
        try JSONEncoder().encode(rows).write(to: backup)
        XCTAssertThrowsError(try fixture.runtime.rollbackAccountTransfer(fixture.receipt))
        XCTAssertEqual(try targetSnapshot(fixture), before)
    }

    // Implements: FR-ACCOUNT-2
    func testHistoryDigestsIgnoreRowOrderAndPreserveDuplicateCounts() throws {
        let a: [String: JSONValue] = ["thread_id": .string("session"), "payload": .string("a")]
        let b: [String: JSONValue] = ["thread_id": .string("session"), "payload": .string("b")]
        XCTAssertEqual(try AccountRollbackRows.digest([a, b, a]), try AccountRollbackRows.digest([b, a, a]))
        XCTAssertNotEqual(try AccountRollbackRows.digest([a, b, a]), try AccountRollbackRows.digest([b, a, b]))
    }

    // Implements: FR-ACCOUNT-2
    func testLegacyDatabaseReceiptDefaultsMissingHistoryFlag() throws {
        let bytes = Data(#"{"file":"state_5.sqlite","sessionID":"fixture","installedDigest":"fixture","replaced":false}"#.utf8)
        let receipt = try JSONDecoder().decode(AccountDatabaseTransfer.self, from: bytes)
        XCTAssertFalse(receipt.historyReset)
        XCTAssertNil(receipt.previousDigest)
    }
}
