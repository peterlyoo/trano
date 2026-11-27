import Foundation
import Darwin

enum TwinFileAliasAdmission {
    static func validate(worktree: String, temporaryDirectory: String,
                         fileSystem: TwinArtifactFileSystem = TwinNativeGitFileSystem(),
                         maxEntries: Int = 100_000, maxDepth: Int = 128) throws {
        guard (1...100_000).contains(maxEntries), (0...128).contains(maxDepth),
              validRoot(worktree), validRoot(temporaryDirectory),
              !overlaps(worktree, temporaryDirectory) else { throw TwinGitError.unsafe("Invalid twin alias admission roots or bounds") }
        let roots = [worktree, temporaryDirectory]
        var records: [TwinAliasAdmissionRecord] = []
        var directories = Set<TwinAliasDirectoryIdentity>()
        func children(_ path: String, limit: Int) throws -> [String] {
            let names = try fileSystem.artifactChildren(path, limit: limit)
            guard names.count <= limit, Set(names).count == names.count,
                  names.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.utf8.contains(0) && $0.utf8.count <= 16_384 }) else {
                throw TwinGitError.unsafe("Unsafe twin alias inventory entry")
            }
            return names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        }
        func walk(_ path: String, depth: Int) throws {
            guard depth <= maxDepth, records.count < maxEntries, path.utf8.count <= 16_384,
                  let node = try fileSystem.artifactInfo(path), node.metadata.ownerUID == getuid(),
                  node.metadata.kind == .directory || node.links == 1 else {
                throw TwinGitError.unsafe("Twin write roots contain a linked, unowned, or unavailable entry")
            }
            let index = records.count
            records.append(.init(path: path, node: node, children: nil))
            if node.metadata.kind == .directory {
                let identity = TwinAliasDirectoryIdentity(device: node.metadata.identity.device, inode: node.metadata.identity.inode)
                guard directories.insert(identity).inserted else { throw TwinGitError.unsafe("Twin write roots contain an aliased directory") }
                let names = try children(path, limit: maxEntries - records.count)
                guard try fileSystem.artifactInfo(path) == node else { throw TwinGitError.unsafe("Twin directory changed during alias inventory") }
                records[index].children = names
                for name in names { try walk(path + "/" + name, depth: depth + 1) }
            }
        }
        for root in roots {
            guard try fileSystem.canonicalPath(root) == root,
                  let node = try fileSystem.artifactInfo(root), node.metadata.kind == .directory, node.metadata.ownerUID == getuid() else {
                throw TwinGitError.unsafe("Twin write roots must be exact owned canonical directories")
            }
            try walk(root, depth: 0)
        }
        for record in records {
            guard try fileSystem.artifactInfo(record.path) == record.node else { throw TwinGitError.unsafe("Twin entry changed during alias admission") }
            if let names = record.children {
                guard try children(record.path, limit: names.count) == names,
                      try fileSystem.artifactInfo(record.path) == record.node else { throw TwinGitError.unsafe("Twin directory inventory changed during alias admission") }
            }
        }
        for root in roots {
            guard let record = records.first(where: { $0.path == root }),
                  try fileSystem.canonicalPath(root) == root,
                  try fileSystem.artifactInfo(root) == record.node else { throw TwinGitError.unsafe("Twin write root identity changed during alias admission") }
        }
    }
    private static func validRoot(_ path: String) -> Bool {
        path.hasPrefix("/") && path != "/" && path.utf8.count <= 16_384 && !path.hasSuffix("/") && !path.contains("//") && !path.utf8.contains(0)
            && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }
    private static func overlaps(_ first: String, _ second: String) -> Bool {
        first == second || first.hasPrefix(second + "/") || second.hasPrefix(first + "/")
    }
}

private struct TwinAliasAdmissionRecord {
    let path: String
    let node: TwinArtifactNode
    var children: [String]?
}
private struct TwinAliasDirectoryIdentity: Hashable {
    let device: UInt64
    let inode: UInt64
}
