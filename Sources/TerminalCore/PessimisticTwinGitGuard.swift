import Foundation

struct TwinGitMergeInventory {
    let root: String
    let paths: [String]
    private let leaves: [(String, TwinGitNode?)]
    private let parents: [(String, TwinGitNode?)]

    init(root: String, paths: [String], leaves: [(String, TwinGitNode?)], files: TwinGitFileSystem) throws {
        guard paths.count <= 10_000, paths == leaves.map(\.0), try files.info(root)?.kind == .directory else {
            throw TwinGitError.unsafe("Source merge inventory is incomplete")
        }
        var parentPaths = Set([root])
        for path in paths {
            var current = root
            for component in path.split(separator: "/").dropLast() {
                current += "/" + component; parentPaths.insert(current)
                guard parentPaths.count <= 100_000 else { throw TwinGitError.unsafe("Source merge parent inventory exceeds its bound") }
            }
        }
        var captured: [(String, TwinGitNode?)] = []
        for path in parentPaths.sorted() {
            let node = try files.info(path)
            guard node == nil || node?.kind == .directory else { throw TwinGitError.unsafe("Source merge parent became linked or unsupported") }
            captured.append((path, node))
        }
        self.root = root; self.paths = paths; self.leaves = leaves; self.parents = captured
        guard try matches(paths: paths, files: files) else { throw TwinGitError.unsafe("Source files changed while their merge inventory was captured") }
    }

    func matches(paths currentPaths: [String], files: TwinGitFileSystem) throws -> Bool {
        guard paths == currentPaths else { return false }
        for (path, expected) in parents {
            let current = try files.info(path)
            switch (expected, current) {
            case (nil, nil): break
            case (.some(let expected), .some(let current)):
                guard current.kind == .directory, current.identity == expected.identity,
                      current.ownerUID == expected.ownerUID, current.mode == expected.mode else { return false }
            default: return false
            }
        }
        for (path, expected) in leaves where try files.info(root + "/" + path) != expected { return false }
        return true
    }
}

enum TwinGitMutationPolicy {
    static func attributes(paths: [String], command: ([String], Data?) throws -> Data) throws {
        if paths.isEmpty { return }
        let data = try command(["check-attr", "-z", "--stdin", "merge"], Data((paths.joined(separator: "\0") + "\0").utf8))
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        guard data.last == 0, fields.count == paths.count * 3 + 1 else { throw TwinGitError.unsafe("Cannot verify merge attributes") }
        for index in paths.indices {
            guard String(data: Data(fields[index * 3]), encoding: .utf8) == paths[index], fields[index * 3 + 1] == Data("merge".utf8),
                  let value = String(data: Data(fields[index * 3 + 2]), encoding: .utf8), ["unspecified", "set", "unset", "text", "binary"].contains(value) else {
                throw TwinGitError.unsafe("Custom or union merge attributes require human review")
            }
        }
    }
}
