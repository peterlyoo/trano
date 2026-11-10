import Foundation
import Darwin

enum AccountRollbackRows {
    typealias Rows = [[String: JSONValue]]

    static func digest(_ rows: Rows) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let ordered = try rows.map { try encoder.encode($0) }.sorted { $0.lexicographicallyPrecedes($1) }
        return AccountSessionFiles.digest(try encoder.encode(ordered))
    }

    static func validate(_ rows: Rows, columns: [String], idColumn: String, sessionID: String) throws {
        guard !columns.isEmpty, columns.contains(idColumn), !columns.contains(where: { $0.contains("\0") }) else {
            throw TerminalError.invalid("Unsupported account database schema")
        }
        for row in rows {
            guard Set(row.keys) == Set(columns), row[idColumn]?.text == sessionID,
                  row.values.allSatisfy({ value in
                      switch value {
                      case .null: return true
                      case .number(let number): return number.isFinite
                      case .string(let text): return !text.contains("\0")
                      default: return false
                      }
                  }) else { throw TerminalError.invalid("Account rollback rows do not match this conversation") }
        }
    }

    static func insert(_ rows: Rows, into table: String, columns: [String]) -> String {
        rows.map { row in
            "INSERT INTO " + table + " (" + columns.map(AccountDatabaseTransfer.identifier).joined(separator: ",") + ") VALUES (" +
            columns.map { AccountDatabaseTransfer.value(row[$0] ?? .null) }.joined(separator: ",") + ");"
        }.joined(separator: "\n")
    }

    static let guardSetup = "CREATE TEMP TABLE trano_rollback_guard(ok INTEGER CHECK(ok = 1));"

    static func guardSQL(table: String, columns: [String], idColumn: String, sessionID: String, rows: Rows, ordinal: Int) -> String {
        let expected = AccountDatabaseTransfer.identifier("trano_rollback_expected_" + String(ordinal))
        let names = columns.map(AccountDatabaseTransfer.identifier).joined(separator: ",")
        let binary = columns.map { AccountDatabaseTransfer.identifier($0) + " COLLATE BINARY" }.joined(separator: ",")
        let actualRows = "SELECT " + binary + ",COUNT(*) FROM " + table + " WHERE " + AccountDatabaseTransfer.identifier(idColumn) + " = " + AccountDatabaseTransfer.literal(sessionID) + " GROUP BY " + binary
        let expectedRows = "SELECT " + binary + ",COUNT(*) FROM " + expected + " GROUP BY " + binary
        return "CREATE TEMP TABLE " + expected + " AS SELECT " + names + " FROM " + table + " WHERE 0;\n" +
            insert(rows, into: expected, columns: columns) + "\nINSERT INTO trano_rollback_guard SELECT CASE WHEN NOT EXISTS (" +
            actualRows + " EXCEPT " + expectedRows + ") AND NOT EXISTS (" + expectedRows + " EXCEPT " + actualRows + ") THEN 1 ELSE 0 END;"
    }

    static func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        guard errno == ENOENT else { throw TerminalError.invalid("Cannot inspect account rollback data") }
        return false
    }
}
