import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct ConversationHistorySource: Codable, Equatable {
    public let id: String
    public let provider: AgentKind
    public let configurationRoot: String
    public let accountID: String?
    public let label: String
    public let enabled: Bool
    public init(id: String, provider: AgentKind, configurationRoot: String, accountID: String? = nil, label: String, enabled: Bool = true) {
        self.id = id; self.provider = provider; self.configurationRoot = configurationRoot
        self.accountID = accountID; self.label = label; self.enabled = enabled
    }
}

public struct AgentConversation: Codable, Equatable, Identifiable {
    public var id: String { source.id + ":" + providerSessionID }
    public let source: ConversationHistorySource
    public let providerSessionID: String
    public let title: String
    public let cwd: String
    public let updatedAt: Date
    public let relativePath: String
    public init(source: ConversationHistorySource, providerSessionID: String, title: String, cwd: String,
                updatedAt: Date, relativePath: String) {
        self.source = source; self.providerSessionID = providerSessionID; self.title = title
        self.cwd = cwd; self.updatedAt = updatedAt; self.relativePath = relativePath
    }
}

public struct ConversationHistorySnapshot: Codable, Equatable {
    public let conversations: [AgentConversation]
    public let warnings: [String]
    public let truncated: Bool
    public init(conversations: [AgentConversation], warnings: [String], truncated: Bool) {
        self.conversations = conversations; self.warnings = warnings; self.truncated = truncated
    }
}

public struct ConversationHistoryLimits: Equatable {
    public let maxSources: Int
    public let maxVisitedEntries: Int
    public let maxFiles: Int
    public let maxTotalBytes: Int
    public let headBytes: Int
    public let tailBytes: Int
    public let maxLineBytes: Int
    public let maxConversations: Int
    public init(maxSources: Int = 32, maxVisitedEntries: Int = 10_000, maxFiles: Int = 256,
                maxTotalBytes: Int = 16_777_216, headBytes: Int = 65_536, tailBytes: Int = 32_768,
                maxLineBytes: Int = 65_536, maxConversations: Int = 200) {
        self.maxSources = min(64, max(0, maxSources)); self.maxVisitedEntries = min(50_000, max(0, maxVisitedEntries))
        self.maxFiles = min(1024, max(0, maxFiles)); self.maxTotalBytes = min(67_108_864, max(0, maxTotalBytes))
        self.headBytes = min(262_144, max(0, headBytes)); self.tailBytes = min(262_144, max(0, tailBytes))
        self.maxLineBytes = min(262_144, max(0, maxLineBytes)); self.maxConversations = min(1000, max(0, maxConversations))
    }
}

public enum ConversationHistoryIndex {
    public static func discover(sources: [ConversationHistorySource], limits: ConversationHistoryLimits = .init(),
                                cancelled: @escaping () -> Bool = { false }) -> ConversationHistorySnapshot {
        HistoryDiscovery(sources: sources, limits: limits, cancelled: cancelled).run()
    }

    public static func validate(conversation: AgentConversation) throws -> AgentConversation {
        guard let expectedID = HistoryFile.sessionID(conversation.relativePath, provider: conversation.source.provider),
              expectedID == conversation.providerSessionID.lowercased(), HistoryFile.validCWD(conversation.cwd) else {
            throw TerminalError.invalid("Conversation identity or source is unavailable")
        }
        let root = try HistoryFile.openRoot(conversation.source.configurationRoot)
        defer { close(root) }
        let file = try HistoryFile.openFile(root: root, relative: conversation.relativePath)
        defer { close(file) }
        var budget = ConversationHistoryLimits().maxTotalBytes
        let (rows, info, _) = try HistoryFile.rows(file, limits: .init(), remaining: &budget)
        guard let fresh = HistoryFile.parse(rows, source: conversation.source, relative: conversation.relativePath, info: info),
              fresh.providerSessionID == expectedID, fresh.cwd == conversation.cwd else {
            throw TerminalError.invalid("Conversation changed or no longer has verified provider metadata")
        }
        return fresh
    }
}

private enum HistoryFile {
    static func validCWD(_ value: String) -> Bool {
        value.hasPrefix("/") && value.utf8.count <= 4096 && !value.contains("\0") && !value.contains("\n") && !value.contains("\r") &&
        !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }

    static func components(_ value: String) throws -> [String] {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !value.isEmpty, value.utf8.count <= 4096, !value.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else {
            throw TerminalError.invalid("Invalid relative history path")
        }
        return parts
    }

    static func openRoot(_ path: String) throws -> Int32 {
        guard validCWD(path) else { throw TerminalError.invalid("Invalid history root") }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var info = stat()
        guard fd >= 0 else { throw TerminalError.invalid("History root is unavailable") }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            close(fd); throw TerminalError.invalid("History root must be an owned directory")
        }
        return fd
    }

    static func openDirectory(_ parent: Int32, _ name: String) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw TerminalError.invalid("History directory is unavailable") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            close(fd); throw TerminalError.invalid("History directory must be owned")
        }
        return fd
    }

    static func openFile(root: Int32, relative: String) throws -> Int32 {
        let parts = try components(relative)
        var directory = fcntl(root, F_DUPFD_CLOEXEC, 0)
        guard directory >= 0 else { throw TerminalError.runtime("Cannot open history root descriptor") }
        defer { close(directory) }
        for part in parts.dropLast() {
            let next = try openDirectory(directory, part)
            close(directory); directory = next
        }
        let fd = openat(directory, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw TerminalError.invalid("History file is unavailable") }
        var info = stat()
        guard fstat(fd, &info) == 0, safe(info) else { close(fd); throw TerminalError.invalid("History must be an owned single-link regular file") }
        return fd
    }

    static func safe(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid() && info.st_nlink == 1 && info.st_size >= 0
    }

    static func modified(_ info: stat) -> Date {
        #if canImport(Darwin)
        return Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        #else
        return Date(timeIntervalSince1970: Double(info.st_mtim.tv_sec) + Double(info.st_mtim.tv_nsec) / 1_000_000_000)
        #endif
    }

    static func sessionID(_ relative: String, provider: AgentKind) -> String? {
        guard let parts = try? components(relative), let name = parts.last, name.hasSuffix(".jsonl") else { return nil }
        let stem = String(name.dropLast(6))
        switch provider {
        case .claude:
            guard parts.count == 3, parts[0] == "projects", let uuid = UUID(uuidString: stem) else { return nil }
            return uuid.uuidString.lowercased()
        case .codex:
            guard parts.count == 5, parts[0] == "sessions", parts[1].count == 4, parts[1].allSatisfy(\.isNumber),
                  parts[2].count == 2, let month = Int(parts[2]), (1...12).contains(month),
                  parts[3].count == 2, let day = Int(parts[3]), (1...31).contains(day),
                  stem.hasPrefix("rollout-"), stem.count > 44, let uuid = UUID(uuidString: String(stem.suffix(36))),
                  stem.dropLast(36).hasSuffix("-") else { return nil }
            return uuid.uuidString.lowercased()
        case .shell: return nil
        }
    }

    static func rows(_ fd: Int32, limits: ConversationHistoryLimits, remaining: inout Int) throws -> ([[String: Any]], stat, Bool) {
        var before = stat()
        guard fstat(fd, &before) == 0, safe(before) else { throw TerminalError.invalid("Unsafe history file") }
        let size = min(Int64(Int.max), Int64(before.st_size))
        let allowance = min(remaining, limits.headBytes + limits.tailBytes)
        guard allowance > 0 else { throw TerminalError.invalid("History read budget exhausted") }
        func read(_ offset: Int64, _ count: Int) throws -> Data {
            guard count > 0 else { return Data() }
            var bytes = [UInt8](repeating: 0, count: count)
            var offsetRead = 0
            while offsetRead < count {
                let amount = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress!.advanced(by: offsetRead), count - offsetRead, off_t(offset + Int64(offsetRead))) }
                if amount < 0 && errno == EINTR { continue }
                guard amount >= 0 else { throw TerminalError.invalid("Cannot read history metadata") }
                if amount == 0 { break }
                offsetRead += amount
            }
            remaining -= offsetRead
            return Data(bytes.prefix(offsetRead))
        }
        var pieces: [Data] = []
        var truncated = size > Int64(allowance)
        if !truncated { pieces = [try read(0, Int(size))] }
        else {
            let head = min(limits.headBytes, allowance)
            var prefix = try read(0, head)
            if let newline = prefix.lastIndex(of: 10) { prefix = Data(prefix[...newline]) } else { prefix = Data() }
            pieces.append(prefix)
            let tail = min(limits.tailBytes, allowance - head)
            if tail > 0 {
                var suffix = try read(size - Int64(tail), tail)
                if let newline = suffix.firstIndex(of: 10) { suffix = Data(suffix.dropFirst(newline + 1)) } else { suffix = Data() }
                pieces.append(suffix)
            }
        }
        var result: [[String: Any]] = []
        for piece in pieces {
            for line in piece.split(separator: 10, omittingEmptySubsequences: true) {
                if line.count > limits.maxLineBytes { truncated = true; continue }
                guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    throw TerminalError.invalid("Malformed history metadata")
                }
                result.append(object)
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, safe(after), before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, modified(before) == modified(after) else { throw TerminalError.invalid("History changed while reading") }
        return (result, after, truncated)
    }

    static func title(_ text: String?) -> String? {
        guard let text else { return nil }
        var bytes = Array(text.utf8.prefix(512))
        while !bytes.isEmpty && String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        guard let value = String(bytes: bytes, encoding: .utf8) else { return nil }
        let clean = value.unicodeScalars.map { $0.value < 32 || $0.value == 127 ? " " : String($0) }.joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return clean.isEmpty ? nil : clean
    }

    static func text(_ value: Any?) -> String? {
        if let value = value as? String { return title(value) }
        guard let blocks = value as? [[String: Any]] else { return nil }
        return blocks.compactMap { block -> String? in
            guard ["text", "input_text", "output_text"].contains(block["type"] as? String ?? "") else { return nil }
            return title(block["text"] as? String)
        }.first
    }

    static func noninteractive(_ source: Any?) -> Bool {
        if let source = source as? String { return ["exec", "codex_exec", "sdk", "sdk-cli", "subagent", "noninteractive"].contains(source.lowercased()) }
        if let source = source as? [String: Any] {
            return source.keys.contains { ["subagent", "exec", "sdk", "noninteractive"].contains($0.lowercased()) } || noninteractive(source["type"])
        }
        return false
    }

    static func parse(_ rows: [[String: Any]], source: ConversationHistorySource, relative: String, info: stat) -> AgentConversation? {
        guard let id = sessionID(relative, provider: source.provider) else { return nil }
        var cwd: String?, firstUser: String?, summary: String?, custom: String?
        var verified = false, interactive = false
        if source.provider == .claude {
            for row in rows {
                if row["isSidechain"] as? Bool == true || row["agentId"] != nil || row["agent_id"] != nil || noninteractive(row["entrypoint"]) { return nil }
                if let entry = row["entrypoint"] as? String, entry != "cli" { return nil }
                if let metadataID = row["sessionId"] as? String {
                    guard UUID(uuidString: metadataID)?.uuidString.lowercased() == id else { return nil }
                    if let directory = row["cwd"] as? String { guard validCWD(directory) else { return nil }; cwd = directory; verified = true }
                }
                let kind = row["type"] as? String
                if ["user", "assistant"].contains(kind ?? ""), let message = row["message"] as? [String: Any] {
                    interactive = true
                    if kind == "user", firstUser == nil, row["isMeta"] as? Bool != true { firstUser = text(message["content"]) }
                }
                if kind == "summary", let value = title(row["summary"] as? String) { summary = value }
                if kind == "custom-title", let value = title(row["customTitle"] as? String) { custom = value }
            }
        } else {
            guard let first = rows.first, first["type"] as? String == "session_meta", let payload = first["payload"] as? [String: Any],
                  UUID(uuidString: payload["id"] as? String ?? "")?.uuidString.lowercased() == id,
                  let directory = payload["cwd"] as? String, validCWD(directory), !noninteractive(payload["source"]) else { return nil }
            cwd = directory; verified = true; interactive = true
            for row in rows {
                guard let payload = row["payload"] as? [String: Any] else { continue }
                let kind = payload["type"] as? String ?? ""
                if row["type"] as? String == "session_meta" {
                    guard UUID(uuidString: payload["id"] as? String ?? "")?.uuidString.lowercased() == id,
                          payload["cwd"] as? String == cwd, !noninteractive(payload["source"]) else { return nil }
                }
                if kind == "user_message", firstUser == nil { firstUser = text(payload["message"]) }
                if kind == "message", payload["role"] as? String == "user", firstUser == nil { firstUser = text(payload["content"]) }
                if ["thread_name_updated", "thread_name", "session_title", "conversation_title", "title"].contains(kind) {
                    custom = title(payload["name"] as? String ?? payload["title"] as? String ?? payload["thread_name"] as? String) ?? custom
                }
            }
        }
        guard verified, interactive, let cwd else { return nil }
        return AgentConversation(source: source, providerSessionID: id, title: custom ?? summary ?? firstUser ?? "Conversation " + id.prefix(8),
                                 cwd: cwd, updatedAt: modified(info), relativePath: relative)
    }
}

private final class HistoryDiscovery {
    let sources: [ConversationHistorySource]
    let limits: ConversationHistoryLimits
    let cancelled: () -> Bool
    var visited = 0, files = 0, remaining: Int
    var truncated = false
    var warnings: [String] = []
    var roots: [Int: Int32] = [:]
    struct Candidate { let source: Int; let path: String; let modified: Date }
    var candidates: [Candidate] = []

    init(sources: [ConversationHistorySource], limits: ConversationHistoryLimits, cancelled: @escaping () -> Bool) {
        self.sources = sources; self.limits = limits; self.cancelled = cancelled; remaining = limits.maxTotalBytes
    }
    deinit { for fd in roots.values { close(fd) } }
    func warning(_ value: String) { if warnings.count < 32 && !warnings.contains(value) { warnings.append(value) } }
    func stopped() -> Bool { if cancelled() { truncated = true; return true }; return false }
    func newer(_ a: Candidate, _ b: Candidate) -> Bool { a.modified == b.modified ? (sources[a.source].id + a.path) < (sources[b.source].id + b.path) : a.modified > b.modified }
    func keep(_ value: Candidate) {
        guard limits.maxFiles > 0 else { truncated = true; return }
        candidates.append(value)
        if candidates.count > limits.maxFiles { candidates.sort(by: newer); candidates.removeLast(); truncated = true }
    }
    func entries(_ fd: Int32, _ body: (String, stat) -> Void) {
        let copy = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0, let stream = fdopendir(copy) else { if copy >= 0 { close(copy) }; return }
        defer { closedir(stream) }
        while !stopped(), let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard visited < limits.maxVisitedEntries else { truncated = true; return }
            visited += 1
            var info = stat()
            if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { body(name, info) }
        }
    }
    func scan(_ index: Int, _ fd: Int32, _ path: String, _ depth: Int) {
        guard !stopped(), visited < limits.maxVisitedEntries else { truncated = true; return }
        let provider = sources[index].provider
        let leaf = provider == .claude ? depth == 1 : depth == 3
        entries(fd) { name, info in
            let relative = path + "/" + name
            if leaf {
                if HistoryFile.safe(info), HistoryFile.sessionID(relative, provider: provider) != nil { keep(Candidate(source: index, path: relative, modified: HistoryFile.modified(info))) }
            } else if info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() {
                if provider == .codex && !(name.allSatisfy(\.isNumber) && name.count == (depth == 0 ? 4 : 2)) { return }
                if let next = try? HistoryFile.openDirectory(fd, name) { defer { close(next) }; scan(index, next, relative, depth + 1) }
            }
        }
    }
    func run() -> ConversationHistorySnapshot {
        if sources.count > limits.maxSources { truncated = true }
        for (index, source) in sources.prefix(limits.maxSources).enumerated() {
            if stopped() { break }
            if sources.prefix(index).contains(source) { continue }
            guard source.provider != .shell else { warning(source.label + ": unsupported history provider"); continue }
            do {
                let root = try HistoryFile.openRoot(source.configurationRoot); roots[index] = root
                let directory = source.provider == .claude ? "projects" : "sessions"
                if let child = try? HistoryFile.openDirectory(root, directory) { defer { close(child) }; scan(index, child, directory, 0) }
            } catch { warning(source.label + ": history root is unavailable or unsafe") }
        }
        var byID: [String: AgentConversation] = [:], ambiguous: Set<String> = []
        for candidate in candidates.sorted(by: newer) {
            if stopped() { break }
            guard files < limits.maxFiles, remaining > 0 else { truncated = true; break }
            do {
                let fd = try HistoryFile.openFile(root: roots[candidate.source]!, relative: candidate.path); defer { close(fd) }
                files += 1
                let (rows, info, partial) = try HistoryFile.rows(fd, limits: limits, remaining: &remaining)
                truncated = truncated || partial
                if let entry = HistoryFile.parse(rows, source: sources[candidate.source], relative: candidate.path, info: info) {
                    if ambiguous.contains(entry.id) { continue }
                    if let old = byID[entry.id] {
                        if old.cwd != entry.cwd || old.source != entry.source {
                            byID.removeValue(forKey: entry.id)
                            ambiguous.insert(entry.id)
                            warning(entry.source.label + ": ambiguous conversation identity")
                        }
                    } else { byID[entry.id] = entry }
                }
            } catch { warning(sources[candidate.source].label + ": skipped malformed, changed or unsafe history") }
        }
        var result = Array(byID.values)
        for (index, root) in roots where sources[index].provider == .codex && result.contains(where: { $0.source == sources[index] }) {
            if stopped() { break }
            guard files < limits.maxFiles, remaining > 0, let fd = try? HistoryFile.openFile(root: root, relative: "session_index.jsonl") else { continue }
            files += 1
            do {
                let (rows, _, partial) = try HistoryFile.rows(fd, limits: limits, remaining: &remaining)
                truncated = truncated || partial
                for row in rows {
                    guard let id = UUID(uuidString: row["id"] as? String ?? "")?.uuidString.lowercased(), let title = HistoryFile.title(row["thread_name"] as? String) else { continue }
                    if let position = result.firstIndex(where: { $0.source == sources[index] && $0.providerSessionID == id }) {
                        let old = result[position]
                        result[position] = AgentConversation(source: old.source, providerSessionID: old.providerSessionID, title: title, cwd: old.cwd, updatedAt: old.updatedAt, relativePath: old.relativePath)
                    }
                }
            } catch { warning(sources[index].label + ": ignored invalid history index") }
            close(fd)
        }
        result.sort { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
        if result.count > limits.maxConversations { result = Array(result.prefix(limits.maxConversations)); truncated = true }
        return ConversationHistorySnapshot(conversations: result, warnings: warnings, truncated: truncated)
    }
}
