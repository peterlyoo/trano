import Foundation
import CryptoKit
import Darwin

struct TwinArtifactNode: Equatable { let metadata: TwinGitNode; let links: UInt64 }
protocol TwinArtifactFileSystem: TwinGitFileSystem {
    func artifactInfo(_ path: String) throws -> TwinArtifactNode?
    func artifactChildren(_ path: String, limit: Int) throws -> [String]
    func artifactDigest(_ path: String, expected: TwinArtifactNode, limit: UInt64) throws -> String
    func artifactMove(_ source: String, _ destination: String, expected: TwinArtifactNode) throws
    func artifactCreatePrivateDirectory(_ path: String) throws
    func artifactSyncDirectory(_ path: String) throws
}
struct TwinArtifactLimits {
    var entries = 100_000
    var roots = 1024
    var bytes: UInt64 = 8_589_934_592
    var receiptBytes = 33_554_432
}
struct TwinArtifactRecord: Codable, Equatable {
    let path, kind: String
    let device, inode, links: UInt64
    let owner, mode: UInt32
    let size, modifiedSeconds, modifiedNanoseconds, changedSeconds, changedNanoseconds: Int64
    let sha256: String?
    init(path: String, node: TwinArtifactNode, sha256: String?) {
        self.path = path; kind = node.metadata.kind.rawValue; device = node.metadata.identity.device; inode = node.metadata.identity.inode
        owner = node.metadata.ownerUID; mode = node.metadata.mode; links = node.links; size = node.metadata.size
        modifiedSeconds = node.metadata.modifiedSeconds; modifiedNanoseconds = node.metadata.modifiedNanoseconds
        changedSeconds = node.metadata.changedSeconds; changedNanoseconds = node.metadata.changedNanoseconds; self.sha256 = sha256
    }
    var node: TwinArtifactNode { .init(metadata: .init(identity: .init(device: device, inode: inode), ownerUID: owner, kind: TwinGitNode.Kind(rawValue: kind) ?? .other, mode: mode, size: size, modifiedSeconds: modifiedSeconds, modifiedNanoseconds: modifiedNanoseconds, changedSeconds: changedSeconds, changedNanoseconds: changedNanoseconds), links: links) }
}
struct TwinArtifactPlan: Codable, Equatable {
    let snapshot: TwinGitSnapshot
    let tip: String
    let roots: [String]
    let records: [TwinArtifactRecord]
    let manifestSHA256: String
}
struct TwinArtifactQuarantine {
    let root: URL
    let files: TwinArtifactFileSystem
    var limits = TwinArtifactLimits()
    func prepare(snapshot: TwinGitSnapshot, tip: String, ignored: Data, protectedPaths: [String]) throws -> TwinArtifactPlan? {
        let location = try checkedLocation(snapshot)
        try requireUnusedNamespace(location)
        let roots = try ignoredRoots(ignored)
        guard !roots.isEmpty else { return nil }
        let protected = protectedPaths.map(Self.key)
        guard roots.count <= limits.roots, roots.allSatisfy({ root in
            !protected.contains { Self.overlap(Self.key(root), $0) }
        }) else { throw TwinGitError.unsafe("Ignored artifacts overlap tracked files or exceed the quarantine root bound") }
        var records: [TwinArtifactRecord] = [], bytes: UInt64 = 0
        for root in roots { try scan(root, base: snapshot.worktreePath, device: snapshot.ownership.pathIdentity.device, depth: 0, records: &records, bytes: &bytes) }
        let manifest = try encoded(records)
        let plan = TwinArtifactPlan(snapshot: snapshot, tip: tip, roots: roots, records: records, manifestSHA256: Self.hash(manifest))
        _ = try encoded(plan)
        try verify(records, base: snapshot.worktreePath, renamedRoots: [])
        guard TwinGitService.validOID(tip) else { throw TwinGitError.unsafe("Artifact quarantine requires an exact reviewed tip") }
        return plan
    }
    func perform(_ plan: TwinArtifactPlan, recordMutation: (TwinGitMutationStage) throws -> Void = { _ in }) throws -> String {
        let location = try checkedLocation(plan.snapshot)
        try requireUnusedNamespace(location)
        guard !plan.roots.isEmpty, plan.roots.count <= limits.roots, plan.records.count <= limits.entries,
              Self.hash(try encoded(plan.records)) == plan.manifestSHA256 else {
            throw TwinGitError.unsafe("Artifact quarantine manifest changed")
        }
        let groups = try recordGroups(plan)
        try verify(plan.records, base: plan.snapshot.worktreePath, renamedRoots: [])
        try recordMutation(.artifactsQuarantineWillStart)
        let pending = location + "/artifacts.pending-" + UUID().uuidString.lowercased()
        try files.artifactCreatePrivateDirectory(pending)
        try files.artifactCreatePrivateDirectory(pending + "/files")
        try files.writePrivate(try encoded(plan), path: pending + "/plan.json")
        try files.artifactSyncDirectory(pending)
        try files.artifactSyncDirectory(location)
        for (index, root) in plan.roots.enumerated() {
            let records = groups[index]
            try verify(records, base: plan.snapshot.worktreePath, renamedRoots: [])
            guard let entry = records.first(where: { $0.path == root }) else { throw TwinGitError.unsafe("Artifact root is missing its identity") }
            try makeParents(of: root, below: pending + "/files")
            try files.artifactMove(plan.snapshot.worktreePath + "/" + root, pending + "/files/" + root, expected: entry.node)
            try verify(records, base: pending + "/files", renamedRoots: [root])
            try files.writePrivate(try encoded(["path": root, "manifest_sha256": plan.manifestSHA256]),
                path: pending + String(format: "/moved-%04d.json", index + 1))
            try files.artifactSyncDirectory(pending)
        }
        try verify(plan.records, base: pending + "/files", renamedRoots: Set(plan.roots))
        try files.writePrivate(try encoded(["manifest_sha256": plan.manifestSHA256, "tip": plan.tip]), path: pending + "/complete.json")
        try files.artifactSyncDirectory(pending)
        guard let node = try files.artifactInfo(pending) else { throw TwinGitError.unsafe("Artifact quarantine directory disappeared") }
        try files.artifactMove(pending, location + "/artifacts", expected: node)
        try files.artifactSyncDirectory(location)
        try recordMutation(.artifactsQuarantined)
        return location + "/artifacts"
    }

    private func checkedLocation(_ snapshot: TwinGitSnapshot) throws -> String {
        let location = root.path + "/twins/" + snapshot.runID + "/round-" + String(snapshot.round)
        guard UUID(uuidString: snapshot.runID)?.uuidString.lowercased() == snapshot.runID, (1...8).contains(snapshot.round),
              snapshot.worktreePath == location + "/worktree", snapshot.ownership.path == snapshot.worktreePath,
              let worktree = try files.artifactInfo(snapshot.worktreePath), worktree.metadata.kind == .directory,
              worktree.metadata.identity == snapshot.ownership.pathIdentity, worktree.metadata.ownerUID == getuid(),
              let parent = try files.artifactInfo(location), parent.metadata.kind == .directory,
              parent.metadata.ownerUID == getuid(), parent.metadata.mode & 0o077 == 0 else {
            throw TwinGitError.unsafe("Artifact cleanup is restricted to this exact owned twin worktree")
        }
        return location
    }
    private func requireUnusedNamespace(_ location: String) throws {
        guard try !files.artifactChildren(location, limit: 2048).contains(where: { $0 == "artifacts" || $0.hasPrefix("artifacts.pending-") }) else {
            throw TwinGitError.unsafe("Retained artifact quarantine already exists; inspect the interrupted cleanup")
        }
    }
    private func ignoredRoots(_ data: Data) throws -> [String] {
        guard data.count <= 8_388_608, data.isEmpty || data.last == 0 else { throw TwinGitError.unsafe("Invalid ignored artifact list") }
        var roots: [String] = [], seen = Set<String>()
        for bytes in data.isEmpty ? [] : data.dropLast().split(separator: 0, omittingEmptySubsequences: false) {
            guard !bytes.isEmpty else { throw TwinGitError.unsafe("Empty ignored artifact path") }
            guard let text = String(data: bytes, encoding: .utf8) else { throw TwinGitError.unsafe("Ignored artifact paths must be valid UTF-8") }
            let path = text.hasSuffix("/") ? String(text.dropLast()) : text
            guard Self.valid(path), seen.insert(Self.key(path)).inserted else { throw TwinGitError.unsafe("Unsafe or ambiguous ignored artifact path") }
            roots.append(path)
        }
        let sorted = roots.sorted { $0.split(separator: "/").count == $1.split(separator: "/").count ? $0.utf8.lexicographicallyPrecedes($1.utf8) : $0.split(separator: "/").count < $1.split(separator: "/").count }
        var collapsed: [String] = []
        for path in sorted where !collapsed.contains(where: { Self.key(path).hasPrefix(Self.key($0) + "/") }) { collapsed.append(path) }
        return collapsed.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }
    private func scan(_ path: String, base: String, device: UInt64, depth: Int, records: inout [TwinArtifactRecord], bytes: inout UInt64) throws {
        guard depth <= 128, Self.valid(path), records.count < limits.entries,
              let node = try files.artifactInfo(base + "/" + path), node.metadata.ownerUID == getuid(), node.metadata.size >= 0, node.metadata.identity.device == device,
              [.directory, .regular, .symlink].contains(node.metadata.kind), node.metadata.kind == .directory || node.links == 1 else {
            throw TwinGitError.unsafe("Ignored artifact is unavailable, linked, unsupported, or exceeds the inventory bound")
        }
        let digest: String?
        if node.metadata.kind == .directory { digest = nil }
        else {
            let size = UInt64(node.metadata.size)
            guard bytes <= limits.bytes, size <= limits.bytes - bytes else { throw TwinGitError.unsafe("Ignored artifacts exceed the byte bound") }
            bytes += size; digest = try files.artifactDigest(base + "/" + path, expected: node, limit: limits.bytes)
        }
        records.append(TwinArtifactRecord(path: path, node: node, sha256: digest))
        if node.metadata.kind == .directory {
            for child in try checkedChildren(base + "/" + path) { try scan(path + "/" + child, base: base, device: device, depth: depth + 1, records: &records, bytes: &bytes) }
        }
        guard try files.artifactInfo(base + "/" + path) == node else { throw TwinGitError.unsafe("Ignored artifacts changed while hashing") }
    }
    private func recordGroups(_ plan: TwinArtifactPlan) throws -> [[TwinArtifactRecord]] {
        var index = 0, result: [[TwinArtifactRecord]] = []
        for root in plan.roots {
            guard Self.valid(root) else { throw TwinGitError.unsafe("Unsafe artifact root") }
            let start = index
            while index < plan.records.count, plan.records[index].path == root || plan.records[index].path.hasPrefix(root + "/") { index += 1 }
            guard index > start, plan.records[start].path == root else { throw TwinGitError.unsafe("Artifact manifest roots are incomplete or out of order") }
            result.append(Array(plan.records[start..<index]))
        }
        guard index == plan.records.count else { throw TwinGitError.unsafe("Artifact manifest contains an unowned path") }
        return result
    }
    private func verify(_ records: [TwinArtifactRecord], base: String, renamedRoots: Set<String>) throws {
        var children: [String: [String]] = [:]
        for record in records {
            guard Self.valid(record.path) else { throw TwinGitError.unsafe("Unsafe artifact manifest path") }
            if let slash = record.path.lastIndex(of: "/") { children[String(record.path[..<slash]), default: []].append(String(record.path[record.path.index(after: slash)...])) }
        }
        for record in records {
            guard let actual = try files.artifactInfo(base + "/" + record.path) else { throw TwinGitError.unsafe("Ignored artifact disappeared") }
            let expected = record.node
            if renamedRoots.contains(record.path) {
                // Atomic rename changes the moved entry's ctime; descendants retain their preflight tokens.
                let a = actual.metadata, b = expected.metadata
                guard a.identity == b.identity, a.ownerUID == b.ownerUID, a.kind == b.kind, a.mode == b.mode, a.size == b.size,
                      a.modifiedSeconds == b.modifiedSeconds, a.modifiedNanoseconds == b.modifiedNanoseconds, actual.links == expected.links else {
                    throw TwinGitError.unsafe("Ignored artifact changed during its atomic quarantine move")
                }
            } else if actual != expected { throw TwinGitError.unsafe("Ignored artifact changed before cleanup") }
            if actual.metadata.kind == .directory {
                let names = try checkedChildren(base + "/" + record.path).map { Data($0.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }
                let expectedNames = (children[record.path] ?? []).map { Data($0.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }
                guard names == expectedNames else { throw TwinGitError.unsafe("Ignored artifact directory entries changed") }
            }
        }
    }
    private func checkedChildren(_ path: String) throws -> [String] {
        let names = try files.artifactChildren(path, limit: limits.entries)
        var seen = Set<String>()
        guard names.allSatisfy({ !$0.contains("/") && Self.valid($0) && seen.insert(Self.key($0)).inserted }) else {
            throw TwinGitError.unsafe("Unsafe or ambiguous artifact directory entry")
        }
        return names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }
    private func makeParents(of path: String, below root: String) throws {
        var current = root
        for component in path.split(separator: "/").dropLast() {
            current += "/" + component; try files.ensurePrivateDirectory(current); try files.artifactSyncDirectory(current)
        }
    }
    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var result = try encoder.encode(value)
        guard result.count < limits.receiptBytes else { throw TwinGitError.unsafe("Artifact quarantine receipt exceeds its bound") }
        result.append(10); return result
    }
    private static func valid(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && path.utf8.count <= 16_384 && !path.utf8.contains(0)
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." || $0.caseInsensitiveCompare(".git") == .orderedSame }
    }
    private static func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
    private static func overlap(_ first: String, _ second: String) -> Bool { first == second || first.hasPrefix(second + "/") || second.hasPrefix(first + "/") }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
