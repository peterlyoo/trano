import Foundation

public struct AccountDatabaseTransfer: Codable {
    public let file: String
    public let sessionID: String
    public let installedDigest: String
    public let replaced: Bool
    public var historyReset: Bool = false
    public let previousDigest: String?

    private enum CodingKeys: String, CodingKey { case file, sessionID, installedDigest, replaced, historyReset, previousDigest }

    init(file: String, sessionID: String, installedDigest: String, replaced: Bool, historyReset: Bool = false, previousDigest: String? = nil) {
        self.file = file
        self.sessionID = sessionID
        self.installedDigest = installedDigest
        self.replaced = replaced
        self.historyReset = historyReset
        self.previousDigest = previousDigest
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        file = try values.decode(String.self, forKey: .file)
        sessionID = try values.decode(String.self, forKey: .sessionID)
        installedDigest = try values.decode(String.self, forKey: .installedDigest)
        replaced = try values.decode(Bool.self, forKey: .replaced)
        historyReset = try values.decodeIfPresent(Bool.self, forKey: .historyReset) ?? false
        previousDigest = try values.decodeIfPresent(String.self, forKey: .previousDigest)
    }

    struct Rollback {
        let database: URL
        let sessionID: String
        let previous: AccountRollbackRows.Rows
        let current: AccountRollbackRows.Rows
        let columns: [String]
        let history: AccountHistoryReset.Rollback?

        func apply() throws {
            let attach = history.map { "ATTACH DATABASE " + AccountDatabaseTransfer.literal($0.database.absoluteString + "?mode=rw") + " AS trano_history;\n" } ?? ""
            let guardRows = AccountRollbackRows.guardSQL(table: "main.threads", columns: columns, idColumn: "id", sessionID: sessionID, rows: current, ordinal: 0)
            let restore = previous.first.map { AccountDatabaseTransfer.upsert($0, columns: columns) } ?? "DELETE FROM threads WHERE id = " + AccountDatabaseTransfer.literal(sessionID) + ";"
            let sql = attach + "BEGIN IMMEDIATE;\n" + AccountRollbackRows.guardSetup + "\n" + guardRows + "\n" +
                (history?.guards(schema: "trano_history", startingAt: 1) ?? "") + "\n" + restore + "\n" +
                (history?.restoreSQL(schema: "trano_history") ?? "") + "\nCOMMIT;\n"
            try AccountDatabaseTransfer.execute(database, sql: sql)
        }
    }

    static func install(sessionID: String, source: URL, target: URL, rollout: String, backup: URL) throws -> AccountDatabaseTransfer? {
        guard let database = try databaseName(source) else { return nil }
        let sourceDB = try checkedDatabase(source.appendingPathComponent(database))
        let sourceRows = try query(sourceDB, sql: "SELECT * FROM threads WHERE id = " + literal(sessionID))
        guard sourceRows.count == 1 else { throw TerminalError.invalid("Codex conversation is missing its SQLite metadata") }
        let targetURL = target.appendingPathComponent(database)
        if !FileManager.default.fileExists(atPath: targetURL.path) {
            var environment = ProcessInfo.processInfo.environment
            for key in ["CODEX_SQLITE_HOME", "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_BASE_URL", "TRANO_LAUNCH_ID"] { environment.removeValue(forKey: key) }
            environment["CODEX_HOME"] = target.path
            _ = try AccountRPC.request(method: "account/read", parameters: .object(["refreshToken": .bool(false)]), environment: environment)
        }
        let targetDB = try checkedDatabase(targetURL)
        let columns = try query(targetDB, sql: "PRAGMA table_info(threads)").compactMap { $0["name"]?.text }
        var row = sourceRows[0]
        guard Set(row.keys) == Set(columns), row["id"]?.text == sessionID else { throw TerminalError.invalid("Codex account database versions differ; update Codex before switching") }
        guard !row.values.contains(where: { $0.text?.contains("\0") == true }) else { throw TerminalError.invalid("Codex metadata contains unsupported text") }
        row["rollout_path"] = .string(target.appendingPathComponent(rollout).path)
        for key in ["project_id", "thread_section_id", "section_position", "section_entered_at_ms"] where row[key] != nil { row[key] = .null }
        let previous = try query(targetDB, sql: "SELECT * FROM threads WHERE id = " + literal(sessionID))
        guard previous.count <= 1 else { throw TerminalError.invalid("Duplicate Codex conversation metadata") }
        try TerminalRuntime.atomicWrite(JSONEncoder().encode(previous), to: backup.appendingPathComponent("database-previous.json"))
        var receipt = AccountDatabaseTransfer(file: database, sessionID: sessionID, installedDigest: try digest([row]), replaced: !previous.isEmpty, previousDigest: try AccountRollbackRows.digest(previous))
        try TerminalRuntime.atomicWrite(JSONEncoder().encode(receipt), to: backup.appendingPathComponent("database-transfer.json"))
        let command = "BEGIN IMMEDIATE;\n" + upsert(row, columns: columns) + "\nCOMMIT;\n"
        try execute(targetDB, sql: command)
        let installed = try query(targetDB, sql: "SELECT * FROM threads WHERE id = " + literal(sessionID))
        guard try digest(installed) == receipt.installedDigest else { throw TerminalError.invalid("Codex metadata changed during transfer") }
        receipt.historyReset = try AccountHistoryReset.install(sessionID: sessionID, source: source, target: target, backup: backup)
        try TerminalRuntime.atomicWrite(JSONEncoder().encode(receipt), to: backup.appendingPathComponent("database-transfer.json"))
        return receipt
    }

    func rollback(target: URL, backup: URL) throws {
        try prepareRollback(target: target, backup: backup).apply()
    }

    func prepareRollback(target: URL, backup: URL) throws -> Rollback {
        let database = try Self.checkedDatabase(target.appendingPathComponent(file))
        let current = try Self.query(database, sql: "SELECT * FROM threads WHERE id = " + Self.literal(sessionID))
        let old = try JSONDecoder().decode([[String: JSONValue]].self, from: AccountFile.read(backup.appendingPathComponent("database-previous.json"), limit: 1_048_576))
        let columns = try Self.query(database, sql: "PRAGMA table_info(threads)").compactMap { $0["name"]?.text }
        guard old.count <= 1, current.count <= 1, replaced == !old.isEmpty else { throw TerminalError.invalid("Invalid Codex metadata backup") }
        try AccountRollbackRows.validate(old, columns: columns, idColumn: "id", sessionID: sessionID)
        try AccountRollbackRows.validate(current, columns: columns, idColumn: "id", sessionID: sessionID)
        guard try previousDigest == nil || previousDigest == AccountRollbackRows.digest(old) else { throw TerminalError.invalid("Codex metadata backup changed") }
        guard try Self.digest(current) == installedDigest || Self.digest(current) == Self.digest(old) else { throw TerminalError.invalid("Codex metadata changed after switching; preserving newer work") }
        let hasHistory = try historyReset || AccountRollbackRows.exists(backup.appendingPathComponent("history-previous.json")) || AccountRollbackRows.exists(backup.appendingPathComponent("history-transfer.json"))
        let history = try hasHistory ? AccountHistoryReset.prepareRollback(sessionID: sessionID, target: target, backup: backup) : nil
        return Rollback(database: database, sessionID: sessionID, previous: old, current: current, columns: columns, history: history)
    }

    private static func databaseName(_ root: URL) throws -> String? {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
            $0.range(of: "^state_[0-9]+\\.sqlite$", options: .regularExpression) != nil
        }
        return names.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.first
    }

    private static func checkedDatabase(_ url: URL) throws -> URL {
        guard url.lastPathComponent.range(of: "^state_[0-9]+\\.sqlite$", options: .regularExpression) != nil else { throw TerminalError.invalid("Invalid Codex database name") }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw TerminalError.invalid("Codex metadata must be an owned regular database")
        }
        return url
    }

    private static func query(_ database: URL, sql: String) throws -> [[String: JSONValue]] {
        let result = try CommandRunner.run("/usr/bin/sqlite3", ["-readonly", "-json", "-cmd", ".timeout 2000", database.path, sql], limit: 1_048_576)
        guard result.status == 0 else { throw TerminalError.runtime("Cannot read Codex conversation metadata") }
        return result.stdout.isEmpty ? [] : try JSONDecoder().decode([[String: JSONValue]].self, from: result.stdout)
    }

    private static func execute(_ database: URL, sql: String) throws {
        let result = try CommandRunner.run("/usr/bin/sqlite3", ["-bail", "-cmd", ".timeout 2000", database.path], input: Data(sql.utf8), limit: 1_048_576)
        guard result.status == 0 else { throw TerminalError.runtime("Cannot transfer Codex conversation metadata") }
    }

    static func literal(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
    static func identifier(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    static func value(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): return literal(text)
        case .number(let number): return String(number)
        case .bool(let flag): return flag ? "1" : "0"
        default: return "NULL"
        }
    }
    private static func upsert(_ row: [String: JSONValue], columns: [String]) -> String {
        "INSERT INTO threads (" + columns.map(identifier).joined(separator: ",") + ") VALUES (" + columns.map { value(row[$0] ?? .null) }.joined(separator: ",") + ") ON CONFLICT(id) DO UPDATE SET " + columns.filter { $0 != "id" }.map { identifier($0) + " = excluded." + identifier($0) }.joined(separator: ",") + ";"
    }
    private static func digest(_ rows: [[String: JSONValue]]) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return AccountSessionFiles.digest(try encoder.encode(rows))
    }
}
