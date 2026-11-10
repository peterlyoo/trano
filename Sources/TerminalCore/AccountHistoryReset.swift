import Foundation

enum AccountHistoryReset {
    private static let tables = ["thread_items", "thread_turns", "thread_realtime_items", "thread_history_projection_state"]

    private struct Receipt: Codable {
        let sessionID: String
        let previousDigests: [String: String]
        let installedDigests: [String: String]
    }

    struct Rollback {
        let database: URL
        let sessionID: String
        let previous: [String: AccountRollbackRows.Rows]
        let current: [String: AccountRollbackRows.Rows]
        let columns: [String: [String]]

        func guards(schema: String, startingAt ordinal: Int) -> String {
            AccountHistoryReset.tables.enumerated().map { index, table in
                AccountRollbackRows.guardSQL(table: schema + "." + table, columns: columns[table]!, idColumn: "thread_id", sessionID: sessionID, rows: current[table]!, ordinal: ordinal + index)
            }.joined(separator: "\n")
        }

        func restoreSQL(schema: String) -> String {
            AccountHistoryReset.tables.map { table in
                "DELETE FROM " + schema + "." + table + " WHERE thread_id = " + AccountDatabaseTransfer.literal(sessionID) + ";\n" +
                AccountRollbackRows.insert(previous[table]!, into: schema + "." + table, columns: columns[table]!)
            }.joined(separator: "\n")
        }
    }

    static func install(sessionID: String, source: URL, target: URL, backup: URL) throws -> Bool {
        let sourceDB = try database(source)
        if sourceDB != nil, try database(target) == nil {
            var environment = ProcessInfo.processInfo.environment
            for key in ["CODEX_SQLITE_HOME", "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_BASE_URL", "TRANO_LAUNCH_ID"] { environment.removeValue(forKey: key) }
            environment["CODEX_HOME"] = target.path
            _ = try AccountRPC.request(method: "thread/turns/list", parameters: .object(["threadId": .string(sessionID), "limit": .number(1)]), environment: environment)
        }
        guard let database = try database(target) else { return false }
        var previous: [String: AccountRollbackRows.Rows] = [:], incoming: [String: AccountRollbackRows.Rows] = [:]
        var columns: [String: [String]] = [:], previousDigests: [String: String] = [:], installedDigests: [String: String] = [:]
        for table in tables {
            columns[table] = try schema(database, table: table)
            previous[table] = try rows(database, table: table, sessionID: sessionID)
            incoming[table] = try sourceDB.map { try rows($0, table: table, sessionID: sessionID) } ?? []
            try AccountRollbackRows.validate(previous[table]!, columns: columns[table]!, idColumn: "thread_id", sessionID: sessionID)
            try AccountRollbackRows.validate(incoming[table]!, columns: columns[table]!, idColumn: "thread_id", sessionID: sessionID)
            previousDigests[table] = try AccountRollbackRows.digest(previous[table]!)
            installedDigests[table] = try AccountRollbackRows.digest(incoming[table]!)
        }
        let bytes = try JSONEncoder().encode(previous)
        guard bytes.count <= 32 * 1_048_576 else { throw TerminalError.invalid("Codex history cache backup exceeds limit") }
        try TerminalRuntime.atomicWrite(bytes, to: backup.appendingPathComponent("history-previous.json"))
        let receipt = Receipt(sessionID: sessionID, previousDigests: previousDigests, installedDigests: installedDigests)
        try TerminalRuntime.atomicWrite(JSONEncoder().encode(receipt), to: backup.appendingPathComponent("history-transfer.json"))
        let plan = Rollback(database: database, sessionID: sessionID, previous: incoming, current: previous, columns: columns)
        try execute(database, sql: "BEGIN IMMEDIATE;\n" + AccountRollbackRows.guardSetup + "\n" + plan.guards(schema: "main", startingAt: 0) + "\n" + plan.restoreSQL(schema: "main") + "\nCOMMIT;\n")
        return true
    }

    static func prepareRollback(sessionID: String, target: URL, backup: URL) throws -> Rollback {
        guard let database = try database(target) else { throw TerminalError.invalid("Codex history cache disappeared during rollback") }
        let previous = try JSONDecoder().decode([String: AccountRollbackRows.Rows].self, from: AccountFile.read(backup.appendingPathComponent("history-previous.json"), limit: 32 * 1_048_576))
        guard Set(previous.keys) == Set(tables) else { throw TerminalError.invalid("Invalid history transfer tables") }
        let proof = backup.appendingPathComponent("history-transfer.json")
        let receipt = try AccountRollbackRows.exists(proof) ? JSONDecoder().decode(Receipt.self, from: AccountFile.read(proof, limit: 1_048_576)) : nil
        if let receipt {
            guard receipt.sessionID == sessionID, Set(receipt.previousDigests.keys) == Set(tables), Set(receipt.installedDigests.keys) == Set(tables) else {
                throw TerminalError.invalid("History transfer receipt does not match this conversation")
            }
        }
        var current: [String: AccountRollbackRows.Rows] = [:], columns: [String: [String]] = [:]
        for table in tables {
            columns[table] = try schema(database, table: table)
            try AccountRollbackRows.validate(previous[table]!, columns: columns[table]!, idColumn: "thread_id", sessionID: sessionID)
            current[table] = try rows(database, table: table, sessionID: sessionID)
            try AccountRollbackRows.validate(current[table]!, columns: columns[table]!, idColumn: "thread_id", sessionID: sessionID)
            let previousDigest = try AccountRollbackRows.digest(previous[table]!)
            let currentDigest = try AccountRollbackRows.digest(current[table]!)
            guard receipt == nil || receipt?.previousDigests[table] == previousDigest else { throw TerminalError.invalid("Codex history backup changed") }
            guard currentDigest == previousDigest || currentDigest == receipt?.installedDigests[table] else {
                throw TerminalError.invalid("Codex history changed after switching; preserving newer work")
            }
        }
        return Rollback(database: database, sessionID: sessionID, previous: previous, current: current, columns: columns)
    }

    static func restore(sessionID: String, target: URL, backup: URL) throws {
        let plan = try prepareRollback(sessionID: sessionID, target: target, backup: backup)
        try execute(plan.database, sql: "BEGIN IMMEDIATE;\n" + AccountRollbackRows.guardSetup + "\n" + plan.guards(schema: "main", startingAt: 0) + "\n" + plan.restoreSQL(schema: "main") + "\nCOMMIT;\n")
    }

    private static func schema(_ database: URL, table: String) throws -> [String] {
        try query(database, sql: "PRAGMA table_info(" + table + ")").compactMap { $0["name"]?.text }
    }

    private static func rows(_ database: URL, table: String, sessionID: String) throws -> AccountRollbackRows.Rows {
        try query(database, sql: "SELECT * FROM " + table + " WHERE thread_id = " + AccountDatabaseTransfer.literal(sessionID))
    }

    private static func query(_ database: URL, sql: String) throws -> AccountRollbackRows.Rows {
        let result = try CommandRunner.run("/usr/bin/sqlite3", ["-readonly", "-json", "-cmd", ".timeout 2000", database.path, sql], limit: 16 * 1_048_576)
        guard result.status == 0 else { throw TerminalError.runtime("Unsupported Codex history cache schema") }
        return result.stdout.isEmpty ? [] : try JSONDecoder().decode(AccountRollbackRows.Rows.self, from: result.stdout)
    }

    private static func database(_ target: URL) throws -> URL? {
        let url = target.appendingPathComponent("thread_history_1.sqlite")
        guard try AccountRollbackRows.exists(url) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw TerminalError.invalid("Codex history cache must be an owned regular database")
        }
        return url
    }

    private static func execute(_ database: URL, sql: String) throws {
        let result = try CommandRunner.run("/usr/bin/sqlite3", ["-bail", "-cmd", ".timeout 2000", database.path], input: Data(sql.utf8), limit: 1_048_576)
        guard result.status == 0 else { throw TerminalError.runtime("Cannot update Codex history cache; preserving account transfer backups") }
    }
}
