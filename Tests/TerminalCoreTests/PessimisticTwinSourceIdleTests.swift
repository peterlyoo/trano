import Foundation
import XCTest
import Darwin
@testable import TerminalCore

final class PessimisticTwinSourceIdleTests: XCTestCase {
    // Implements: FR-TWIN-6, FR-TWIN-8.
    func testSourceOperationMarkersHoldMainAndLinkedSourceWorktrees() throws {
        let markers = ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG", "BISECT_START", "AUTO_MERGE",
            "rebase-merge", "rebase-apply", "sequencer", "index.lock", "HEAD.lock"]
        for source in ["/repository/.git", "/repository/.git/worktrees/source"] {
            let snapshot = sourceSnapshot(source)
            for directory in Set([source, snapshot.commonDirectory]) {
                for marker in markers {
                    let fs = SourceIdleFS(snapshot)
                    try TwinRuntimeGitWork.ensureSourceIdle(snapshot, fileSystem: fs)
                    fs.nodes[directory + "/" + marker] = SourceIdleFS.node(.regular)
                    XCTAssertThrowsError(try TwinRuntimeGitWork.ensureSourceIdle(snapshot, fileSystem: fs), directory + "/" + marker)
                    XCTAssertEqual(fs.mutations, 0)
                }
            }
        }
    }
    func testMissingReplacedOrSymlinkSourceMetadataAlwaysRetainsArtifacts() throws {
        for reason in ["missing-source", "missing-common", "replaced-common", "symlink-source", "foreign-source"] {
            let snapshot = sourceSnapshot("/repository/.git/worktrees/source"), fs = SourceIdleFS(sourceSnapshot("/repository/.git/worktrees/source"))
            if reason == "missing-source" { fs.nodes[snapshot.sourceGitDirectory] = nil }
            if reason == "missing-common" { fs.nodes[snapshot.commonDirectory] = nil }
            if reason == "replaced-common" { fs.nodes[snapshot.commonDirectory] = SourceIdleFS.node(.directory, inode: 999) }
            if reason == "symlink-source" { fs.nodes[snapshot.sourceGitDirectory] = SourceIdleFS.node(.symlink) }
            if reason == "foreign-source" { fs.nodes[snapshot.sourceGitDirectory] = SourceIdleFS.node(.directory, owner: getuid() &+ 1) }
            XCTAssertThrowsError(try TwinRuntimeGitWork.ensureSourceIdle(snapshot, fileSystem: fs), reason)
            XCTAssertEqual(fs.mutations, 0)
        }
    }
    func testIdleCheckOnlyReadsKnownMetadataAndAllowsOrdinaryIndex() throws {
        let snapshot = sourceSnapshot("/repository/.git/worktrees/source"), fs = SourceIdleFS(sourceSnapshot("/repository/.git/worktrees/source"))
        fs.nodes[snapshot.sourceGitDirectory + "/index"] = SourceIdleFS.node(.regular)
        try TwinRuntimeGitWork.ensureSourceIdle(snapshot, fileSystem: fs)
        XCTAssertTrue(fs.reads.contains(snapshot.sourceGitDirectory + "/MERGE_HEAD"))
        XCTAssertTrue(fs.reads.contains(snapshot.commonDirectory + "/MERGE_HEAD"))
        XCTAssertTrue(fs.reads.allSatisfy { $0.hasPrefix(snapshot.commonDirectory) })
        XCTAssertEqual(fs.mutations, 0)
    }
}

private func sourceSnapshot(_ source: String) -> TwinGitSnapshot {
    let identity = WorktreeFileIdentity(device: 1, inode: 11)
    let ownership = WorktreeIdentity(path: "/runtime/twin/worktree", commonDirectory: "/repository/.git", adminDirectory: "/repository/.git/worktrees/twin", pathIdentity: identity, gitFileIdentity: identity, adminIdentity: identity, commonIdentity: identity)
    return TwinGitSnapshot(runID: "44444444-4444-4444-8444-444444444444", round: 1, repositoryRoot: "/repository", sourceCWD: "/repository", sourceGitDirectory: source, commonDirectory: ownership.commonDirectory, sourceBranch: "refs/heads/main", sourceHEAD: String(repeating: "1", count: 40), sourceIndexSHA256: String(repeating: "2", count: 64), sourceTree: String(repeating: "3", count: 40), snapshotCommit: String(repeating: "4", count: 40), twinBranch: "refs/heads/trano/twins/44444444-4444-4444-8444-444444444444/round-1", worktreePath: ownership.path, ownership: ownership)
}
private final class SourceIdleFS: TwinGitFileSystem {
    var nodes: [String: TwinGitNode]
    var reads: [String] = []
    var mutations = 0
    init(_ snapshot: TwinGitSnapshot) { nodes = [snapshot.commonDirectory: Self.node(.directory)] ; nodes[snapshot.sourceGitDirectory] = Self.node(.directory) }
    static func node(_ kind: TwinGitNode.Kind, inode: UInt64 = 11, owner: UInt32 = getuid()) -> TwinGitNode {
        TwinGitNode(identity: .init(device: 1, inode: inode), ownerUID: owner, kind: kind)
    }
    func info(_ path: String) throws -> TwinGitNode? { reads.append(path); return nodes[path] }
    func canonicalPath(_ path: String) throws -> String { throw TwinGitError.unsafe("Unexpected traversal") }
    func read(_ path: String, limit: Int) throws -> Data { throw TwinGitError.unsafe("Unexpected content read") }
    func readLink(_ path: String, limit: Int) throws -> Data { throw TwinGitError.unsafe("Unexpected link read") }
    func ensurePrivateDirectory(_ path: String) throws { mutations += 1; throw TwinGitError.unsafe("Unexpected mutation") }
    func writePrivate(_ data: Data, path: String) throws { mutations += 1; throw TwinGitError.unsafe("Unexpected mutation") }
    func removePrivateFile(_ path: String) throws { mutations += 1; throw TwinGitError.unsafe("Unexpected mutation") }
}
