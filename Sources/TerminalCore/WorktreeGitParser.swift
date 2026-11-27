import Foundation

struct WorktreeGitParsedEntry {
    let path: String
    var head: String?
    var branch: String?
    var bare = false
    var detached = false
    var locked = false
    var prunable = false
}

enum WorktreeGitParser {
    static func absolute(_ value: String) throws -> String {
        guard value.hasPrefix("/"), !value.utf8.contains(0), value.utf8.count <= 16_384 else {
            throw WorktreeGitError.unsafe("Invalid absolute filesystem path")
        }
        var parts: [Substring] = []
        for part in value.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() } }
            else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }

    static func join(_ parent: String, _ value: String) throws -> String {
        guard !value.isEmpty, !value.utf8.contains(0) else { throw WorktreeGitError.unsafe("Empty or invalid path") }
        return try absolute(value.hasPrefix("/") ? value : parent + "/" + value)
    }

    static func singleLine(_ data: Data) throws -> String {
        guard !data.isEmpty, data.count <= 16_384, data.last == 10,
              let value = String(data: data.dropLast(), encoding: .utf8), !value.isEmpty, !value.utf8.contains(0) else {
            throw WorktreeGitError.unsafe("Invalid Git path or object response")
        }
        return value
    }

    static func creation(cwd: String, arguments: [String], fileSystem: WorktreeGitFileSystem) throws -> WorktreeCreationInvocation? {
        guard !arguments.isEmpty, arguments.count <= 512, arguments.reduce(0, { $0 + $1.utf8.count }) <= 65_536,
              arguments.allSatisfy({ !$0.utf8.contains(0) && $0.utf8.count <= 16_384 }) else { return nil }
        guard cwd.hasPrefix("/") else { throw WorktreeGitError.unsafe("Creation cwd must be absolute") }
        var current = try resolvedPath(cwd, relativeTo: "/", fileSystem: fileSystem)
        var gitDir: String?, workTree: String?
        var bare = false
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "-C" {
                index += 1; guard index < arguments.count else { return nil }
                if !arguments[index].isEmpty { current = try resolvedPath(arguments[index], relativeTo: current, fileSystem: fileSystem) }
            } else if arg.hasPrefix("--git-dir=") { gitDir = String(arg.dropFirst(10)) }
            else if arg.hasPrefix("--work-tree=") { workTree = String(arg.dropFirst(12)) }
            else if arg == "--git-dir" || arg == "--work-tree" {
                index += 1; guard index < arguments.count else { return nil }
                if arg == "--git-dir" { gitDir = arguments[index] } else { workTree = arguments[index] }
            } else if arg == "--bare" { bare = true; if gitDir == nil { gitDir = current } }
            else if ["-P", "--no-pager", "-p", "--paginate", "--no-optional-locks", "--no-replace-objects", "--no-lazy-fetch", "--no-advice",
                     "--literal-pathspecs", "--no-literal-pathspecs", "--glob-pathspecs", "--noglob-pathspecs", "--icase-pathspecs"].contains(arg) {}
            else if arg.hasPrefix("-") { return nil }
            else { break }
            index += 1
        }
        guard index + 1 < arguments.count, arguments[index] == "worktree", arguments[index + 1] == "add" else { return nil }
        index += 2
        var positional: [String] = [], options = true
        let flags: Set<String> = ["-f", "--force", "-d", "--detach", "--checkout", "--no-checkout", "--lock", "--guess-remote", "--no-guess-remote",
                                  "--track", "--no-track", "--relative-paths", "--no-relative-paths", "-q", "--quiet", "--no-lock", "--no-detach", "--no-force", "--orphan"]
        while index < arguments.count {
            let arg = arguments[index]
            if options && arg == "--" { options = false }
            else if options && ["-b", "-B", "--reason"].contains(arg) {
                index += 1; guard index < arguments.count, !arguments[index].isEmpty else { return nil }
            } else if options && ((arg.hasPrefix("-b") || arg.hasPrefix("-B")) && arg.count > 2) {}
            else if options && arg.hasPrefix("--reason=") {}
            else if options && ["--track=direct", "--track=inherit"].contains(arg) {}
            else if options && flags.contains(arg) {}
            else if options && arg.hasPrefix("-") { return nil }
            else { positional.append(arg) }
            index += 1
        }
        guard (1...2).contains(positional.count), !positional[0].isEmpty else { return nil }
        let target = try resolvedPath(positional[0], relativeTo: current, fileSystem: fileSystem, allowMissingLast: true)
        var globals: [String] = []
        if let gitDir { globals.append("--git-dir=" + (try resolvedPath(gitDir, relativeTo: current, fileSystem: fileSystem))) }
        if let workTree { globals.append("--work-tree=" + (try resolvedPath(workTree, relativeTo: current, fileSystem: fileSystem))) }
        if bare { globals.append("--bare") }
        return WorktreeCreationInvocation(cwd: current, gitArguments: globals + ["worktree", "add", "--", target], targetPath: target)
    }

    static func resolvedPath(_ value: String, relativeTo parent: String, fileSystem: WorktreeGitFileSystem,
                             allowMissingLast: Bool = false) throws -> String {
        guard !value.isEmpty, !value.utf8.contains(0), value.utf8.count <= 16_384 else { throw WorktreeGitError.unsafe("Invalid path") }
        let raw = value.hasPrefix("/") ? value : parent + "/" + value
        let components = raw.split(separator: "/")
        var resolved: [Substring] = [], missing = false
        for (index, component) in components.enumerated() {
            if component == "." { continue }
            if component == ".." { if !resolved.isEmpty { resolved.removeLast() }; continue }
            resolved.append(component)
            let path = "/" + resolved.joined(separator: "/")
            guard let info = try fileSystem.info(path) else {
                guard allowMissingLast, index == components.count - 1 else { throw WorktreeGitError.unsafe("Missing path component") }
                missing = true; continue
            }
            guard info.kind != .symlink, index == components.count - 1 || info.kind == .directory else {
                throw WorktreeGitError.unsafe("Symbolic-link or non-directory path component")
            }
        }
        let path = "/" + resolved.joined(separator: "/")
        if !missing {
            guard try fileSystem.canonicalPath(path) == path else { throw WorktreeGitError.unsafe("Noncanonical filesystem path") }
        }
        return path
    }

    static func validOID(_ value: String) -> Bool {
        (value.utf8.count == 40 || value.utf8.count == 64) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func worktrees(_ data: Data) throws -> [WorktreeGitParsedEntry] {
        guard !data.isEmpty, data.count <= 1_048_576, data.last == 0 else { throw WorktreeGitError.unsafe("Invalid worktree porcelain framing") }
        let tokens = data.split(separator: 0, omittingEmptySubsequences: false)
        guard tokens.count <= 16_384, tokens.last?.isEmpty == true else { throw WorktreeGitError.unsafe("Worktree porcelain exceeds bound") }
        var current: WorktreeGitParsedEntry?, result: [WorktreeGitParsedEntry] = [], paths = Set<String>(), seen = Set<String>()
        for token in tokens.dropLast() {
            guard token.count <= 65_536, let text = String(data: token, encoding: .utf8) else { throw WorktreeGitError.unsafe("Invalid UTF-8 worktree porcelain") }
            if text.isEmpty {
                guard let entry = current, (entry.bare || (entry.head != nil && (entry.branch != nil || entry.detached))), paths.insert(entry.path).inserted else {
                    throw WorktreeGitError.unsafe("Incomplete or duplicate worktree porcelain record")
                }
                result.append(entry); guard result.count <= 4096 else { throw WorktreeGitError.unsafe("Too many worktrees") }
                current = nil; seen = []; continue
            }
            let fields = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let label = String(fields[0]), value = fields.count == 2 ? String(fields[1]) : nil
            guard seen.insert(label).inserted else { throw WorktreeGitError.unsafe("Duplicate worktree attribute") }
            if label == "worktree", let value, current == nil {
                let path = try absolute(value)
                guard path == value else { throw WorktreeGitError.unsafe("Noncanonical listed worktree path") }
                current = WorktreeGitParsedEntry(path: path); continue
            }
            guard current != nil else { throw WorktreeGitError.unsafe("Worktree attribute before path") }
            switch label {
            case "HEAD": guard let value, validOID(value) else { throw WorktreeGitError.unsafe("Invalid worktree object ID") }; current!.head = value
            case "branch": guard let value, value.hasPrefix("refs/heads/"), value.count > 11 else { throw WorktreeGitError.unsafe("Invalid worktree branch") }; current!.branch = value
            case "bare": guard value == nil else { throw WorktreeGitError.unsafe("Invalid bare attribute") }; current!.bare = true
            case "detached": guard value == nil else { throw WorktreeGitError.unsafe("Invalid detached attribute") }; current!.detached = true
            case "locked": current!.locked = true
            case "prunable": current!.prunable = true
            default: throw WorktreeGitError.unsafe("Unsupported worktree attribute")
            }
        }
        guard current == nil, !result.isEmpty else { throw WorktreeGitError.unsafe("Truncated worktree porcelain record") }
        return result
    }

    static func requireNoSparseConfiguration(_ result: WorktreeGitCommandResult) throws {
        if result.status == 1 && result.stdout.isEmpty && result.stderr.isEmpty { return }
        guard result.status == 0, result.stderr.isEmpty, result.stdout.last == 10,
              let text = String(data: result.stdout, encoding: .utf8) else {
            throw WorktreeGitError.unsafe("Sparse-checkout configuration is uncertain")
        }
        let records = text.dropLast().split(separator: "\n", omittingEmptySubsequences: false)
        let keys: Set<String> = ["core.sparsecheckout", "core.sparsecheckoutcone", "index.sparse"]
        guard !records.isEmpty, records.count <= 16_384 else { throw WorktreeGitError.unsafe("Sparse-checkout configuration exceeds bound") }
        for record in records {
            let fields = record.split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count == 2, keys.contains(String(fields[0]).lowercased()), fields[1] == "false" else {
                throw WorktreeGitError.unsafe("Sparse checkout or sparse index prevents safe inspection")
            }
        }
    }

    static func requireVisibleIndex(_ data: Data) throws {
        if data.isEmpty { return }
        guard data.count <= 1_048_576, data.last == 0 else { throw WorktreeGitError.unsafe("Invalid tracked-index framing") }
        let records = data.split(separator: 0, omittingEmptySubsequences: false).dropLast()
        guard records.count <= 16_384 else { throw WorktreeGitError.unsafe("Tracked index exceeds bound") }
        var paths = Set<Data>()
        for record in records {
            guard record.count > 2, record.count <= 16_384, record[record.startIndex] == 72,
                  record[record.startIndex + 1] == 32, paths.insert(Data(record.dropFirst(2))).inserted else {
                throw WorktreeGitError.unsafe("Tracked-index flags may hide modified files")
            }
        }
    }

    static func status(_ data: Data) throws -> (clean: Bool, ignored: Bool) {
        if data.isEmpty { return (true, false) }
        guard data.count <= 1_048_576, data.last == 0 else { throw WorktreeGitError.unsafe("Invalid status framing") }
        let entries = data.split(separator: 0, omittingEmptySubsequences: false).dropLast()
        var index = entries.startIndex, ignored = false
        let codes = Set(" MADRCU?!".utf8)
        while index < entries.endIndex {
            let bytes = Array(entries[index])
            guard bytes.count > 3, bytes[2] == 32, codes.contains(bytes[0]), codes.contains(bytes[1]),
                  bytes[0] != 32 || bytes[1] != 32 else { throw WorktreeGitError.unsafe("Invalid porcelain status record") }
            if bytes[0] == 33 && bytes[1] == 33 { ignored = true }
            index += 1
            if bytes[0] == 82 || bytes[0] == 67 || bytes[1] == 82 || bytes[1] == 67 {
                guard index < entries.endIndex, !entries[index].isEmpty else { throw WorktreeGitError.unsafe("Truncated rename status") }
                index += 1
            }
        }
        return (false, ignored)
    }

    static func retained(_ data: Data) throws -> Bool {
        if data.isEmpty { return false }
        guard data.last == 10, let text = String(data: data, encoding: .utf8) else { throw WorktreeGitError.unsafe("Invalid retention refs") }
        let refs = text.dropLast().split(separator: "\n", omittingEmptySubsequences: false)
        guard refs.count <= 16_384, refs.allSatisfy({ ref in
            ["refs/heads/", "refs/tags/", "refs/remotes/"].contains(where: { ref.hasPrefix($0) && ref.count > $0.count }) &&
            !ref.contains(" ") && !ref.contains("\0") && !ref.contains("\r")
        }) else { throw WorktreeGitError.unsafe("Unexpected retention ref namespace") }
        return !refs.isEmpty
    }
}
