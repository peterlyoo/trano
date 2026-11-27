import Foundation
import XCTest
import Darwin
@testable import TerminalCore

final class PessimisticTwinAliasAdmissionTests: XCTestCase {
    // Implements: FR-TWIN-4, FR-TWIN-10
    func testNativeOutsideHardlinkIsRejectedWithoutChangingOriginalBytes() throws {
        let f = try TwinAliasRealFixture(); defer { f.remove() }
        try FileManager.default.linkItem(at: f.outside, to: f.worktree.appendingPathComponent("alias"))
        XCTAssertThrowsError(try TwinFileAliasAdmission.validate(worktree: f.worktree.path, temporaryDirectory: f.temporary.path))
        XCTAssertEqual(try Data(contentsOf: f.outside), f.bytes)
    }
    func testNativeTemporaryHardlinkAndHardlinkedSymlinkAreRejected() throws {
        let f = try TwinAliasRealFixture(); defer { f.remove() }
        let alias = f.temporary.appendingPathComponent("alias")
        try FileManager.default.linkItem(at: f.outside, to: alias)
        XCTAssertThrowsError(try TwinFileAliasAdmission.validate(worktree: f.worktree.path, temporaryDirectory: f.temporary.path))
        try FileManager.default.removeItem(at: alias)
        let symlink = f.worktree.appendingPathComponent("opaque")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: f.outside)
        XCTAssertEqual(linkat(AT_FDCWD, symlink.path, AT_FDCWD, alias.path, 0), 0)
        XCTAssertEqual(try TwinNativeGitFileSystem().artifactInfo(alias.path)?.links, 2)
        XCTAssertThrowsError(try TwinFileAliasAdmission.validate(worktree: f.worktree.path, temporaryDirectory: f.temporary.path))
        XCTAssertEqual(try Data(contentsOf: f.outside), f.bytes)
    }
    func testNativeSafeCopyOpaqueSymlinkAndFIFOAreMetadataOnly() throws {
        let f = try TwinAliasRealFixture(); defer { f.remove() }
        try FileManager.default.linkItem(at: f.outside, to: f.base.appendingPathComponent("source-other-link"))
        try f.bytes.write(to: f.worktree.appendingPathComponent("independent-copy"))
        try FileManager.default.createSymbolicLink(at: f.worktree.appendingPathComponent("opaque"), withDestinationURL: f.outside)
        XCTAssertEqual(mkfifo(f.temporary.appendingPathComponent("sdk-fifo").path, 0o600), 0)
        XCTAssertNoThrow(try TwinFileAliasAdmission.validate(worktree: f.worktree.path, temporaryDirectory: f.temporary.path))
        XCTAssertEqual(try Data(contentsOf: f.outside), f.bytes)
        XCTAssertEqual(try TwinNativeGitFileSystem().artifactInfo(f.outside.path)?.links, 2)
    }
    func testNativeRootThroughSymlinkParentCannotBeAdopted() throws {
        let f = try TwinAliasRealFixture(); defer { f.remove() }
        let parent = f.base.appendingPathComponent("parent-alias")
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: f.worktree.deletingLastPathComponent())
        XCTAssertThrowsError(try TwinFileAliasAdmission.validate(worktree: parent.appendingPathComponent(f.worktree.lastPathComponent).path, temporaryDirectory: f.temporary.path))
    }
    func testEveryNondirectoryRequiresSingleLinkIncludingSDKOtherNodes() throws {
        for kind in [TwinGitNode.Kind.regular, .symlink, .other] {
            for links: UInt64 in [0, 2] {
                let f = TwinAliasFakeFileSystem(); f.add("/work/file", kind: kind, links: links)
                XCTAssertThrowsError(try TwinFileAliasAdmission.validate(worktree: "/work", temporaryDirectory: "/temporary", fileSystem: f))
                XCTAssertEqual(f.contentReads, 0)
            }
        }
        let f = TwinAliasFakeFileSystem(); f.add("/work/socket", kind: .other, links: 1)
        XCTAssertNoThrow(try TwinFileAliasAdmission.validate(worktree: "/work", temporaryDirectory: "/temporary", fileSystem: f))
    }
    func testRootsMustBeAbsoluteCanonicalOwnedDisjointDirectories() throws {
        for invalid in ["/", "relative", "/work/../source", "/work/", "/work//nested"] {
            let f = TwinAliasFakeFileSystem()
            XCTAssertThrowsError(try TwinFileAliasAdmission.validate(worktree: invalid, temporaryDirectory: "/temporary", fileSystem: f))
            XCTAssertTrue(f.infoReads.isEmpty)
        }
        let f = TwinAliasFakeFileSystem()
        XCTAssertThrowsError(try TwinFileAliasAdmission.validate(worktree: "/work", temporaryDirectory: "/work/tmp", fileSystem: f))
        f.canonical["/work"] = "/source"
        XCTAssertThrowsError(try TwinFileAliasAdmission.validate(worktree: "/work", temporaryDirectory: "/temporary", fileSystem: f))
        f.canonical = [:]; f.nodes["/work"] = f.node(kind: .directory, inode: 1, owner: getuid() + 1)
        XCTAssertThrowsError(try TwinFileAliasAdmission.validate(worktree: "/work", temporaryDirectory: "/temporary", fileSystem: f))
        f.nodes["/work"] = f.node(kind: .regular, inode: 1)
        XCTAssertThrowsError(try TwinFileAliasAdmission.validate(worktree: "/work", temporaryDirectory: "/temporary", fileSystem: f))
    }
    func testInventoryHasTotalEntryDepthAndValidatedChildNameBounds() throws {
        let f = TwinAliasFakeFileSystem(); f.add("/work/a"); f.add("/work/b")
        XCTAssertThrowsError(try TwinFileAliasAdmission.validate(worktree: "/work", temporaryDirectory: "/temporary", fileSystem: f, maxEntries: 3))
        XCTAssertThrowsError(try TwinFileAliasAdmission.validate(worktree: "/work", temporaryDirectory: "/temporary", fileSystem: f, maxDepth: 0))
        for invalid in ["..", ".", "a/b", "", "nul\0"] {
            let f = TwinAliasFakeFileSystem(); f.children["/work"] = [invalid]
            XCTAssertThrowsError(try TwinFileAliasAdmission.validate(worktree: "/work", temporaryDirectory: "/temporary", fileSystem: f))
        }
        let duplicate = TwinAliasFakeFileSystem(); duplicate.children["/work"] = ["same", "same"]
        XCTAssertThrowsError(try TwinFileAliasAdmission.validate(worktree: "/work", temporaryDirectory: "/temporary", fileSystem: duplicate))
    }
    func testInvalidLimitsDoNotTouchFilesystem() {
        let f = TwinAliasFakeFileSystem()
        XCTAssertThrowsError(try TwinFileAliasAdmission.validate(worktree: "/work", temporaryDirectory: "/temporary", fileSystem: f, maxEntries: 0))
        XCTAssertThrowsError(try TwinFileAliasAdmission.validate(worktree: "/work", temporaryDirectory: "/temporary", fileSystem: f, maxEntries: 100_001))
        XCTAssertThrowsError(try TwinFileAliasAdmission.validate(worktree: "/work", temporaryDirectory: "/temporary", fileSystem: f, maxDepth: 129))
        XCTAssertTrue(f.infoReads.isEmpty)
    }
    func testLinkCountChangeAndDirectoryInventoryMutationAreRejected() throws {
        let changed = TwinAliasFakeFileSystem(); changed.add("/work/file")
        changed.onInfo = { path, count in
            if path == "/work/file", count >= 2 { changed.nodes[path] = changed.node(kind: .regular, inode: 3, links: 2) }
        }
        XCTAssertThrowsError(try TwinFileAliasAdmission.validate(worktree: "/work", temporaryDirectory: "/temporary", fileSystem: changed))
        let inventory = TwinAliasFakeFileSystem()
        inventory.onChildren = { path, count in if path == "/work", count >= 2 { inventory.children[path] = ["late"] } }
        XCTAssertThrowsError(try TwinFileAliasAdmission.validate(worktree: "/work", temporaryDirectory: "/temporary", fileSystem: inventory))
    }
    func testFirstRootIdentityMustRemainStableWhileSecondRootIsWalked() throws {
        let f = TwinAliasFakeFileSystem()
        f.onInfo = { path, _ in if path == "/temporary" { f.nodes["/work"] = f.node(kind: .directory, inode: 999) } }
        XCTAssertThrowsError(try TwinFileAliasAdmission.validate(worktree: "/work", temporaryDirectory: "/temporary", fileSystem: f))
    }
    func testOpaqueSymlinkNeverTraversesOrReadsItsTarget() throws {
        let f = TwinAliasFakeFileSystem(); f.add("/work/outside-link", kind: .symlink)
        XCTAssertNoThrow(try TwinFileAliasAdmission.validate(worktree: "/work", temporaryDirectory: "/temporary", fileSystem: f))
        XCTAssertEqual(f.contentReads, 0)
        XCTAssertFalse(f.infoReads.keys.contains { $0.hasPrefix("/source") || $0.hasPrefix("/work/outside-link/") })
        XCTAssertNil(f.childReads["/work/outside-link"])
    }
}

private final class TwinAliasRealFixture {
    let base: URL; let worktree: URL; let temporary: URL; let outside: URL
    let bytes = Data("TRANO_OWNED_FRESH_ALIAS_FIXTURE\n".utf8)
    init() throws {
        base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("twin-alias-admission-" + UUID().uuidString)
        worktree = base.appendingPathComponent("owned/worktree"); temporary = base.appendingPathComponent("owned/profile/tmp"); outside = base.appendingPathComponent("source-original")
        for p in [worktree, temporary] { try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try bytes.write(to: outside)
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
}

private final class TwinAliasFakeFileSystem: TwinArtifactFileSystem {
    var nodes: [String: TwinArtifactNode] = [:], children: [String: [String]] = [:], canonical: [String: String] = [:]
    var infoReads: [String: Int] = [:], childReads: [String: Int] = [:], contentReads = 0
    var onInfo: ((String, Int) -> Void)?, onChildren: ((String, Int) -> Void)?
    init() { nodes["/work"] = node(kind: .directory, inode: 1); nodes["/temporary"] = node(kind: .directory, inode: 2); children["/work"] = []; children["/temporary"] = [] }
    func node(kind: TwinGitNode.Kind, inode: UInt64, owner: UInt32 = getuid(), links: UInt64 = 1) -> TwinArtifactNode { .init(metadata: .init(identity: .init(device: 1, inode: inode), ownerUID: owner, kind: kind), links: links) }
    func add(_ path: String, kind: TwinGitNode.Kind = .regular, links: UInt64 = 1) { nodes[path] = node(kind: kind, inode: UInt64(nodes.count + 1), links: links); let p = URL(fileURLWithPath: path); children[p.deletingLastPathComponent().path, default: []].append(p.lastPathComponent) }
    func canonicalPath(_ path: String) throws -> String { canonical[path] ?? path }
    func artifactInfo(_ path: String) throws -> TwinArtifactNode? { infoReads[path, default: 0] += 1; onInfo?(path, infoReads[path]!); return nodes[path] }
    func artifactChildren(_ path: String, limit: Int) throws -> [String] { childReads[path, default: 0] += 1; onChildren?(path, childReads[path]!); let values = children[path] ?? []; guard values.count <= limit else { throw TwinGitError.unsafe("Fake bound") }; return values }
    func info(_ path: String) throws -> TwinGitNode? { try artifactInfo(path)?.metadata }
    func read(_ path: String, limit: Int) throws -> Data { contentReads += 1; throw TwinGitError.unsafe("Alias admission must not read content") }
    func readLink(_ path: String, limit: Int) throws -> Data { try read(path, limit: limit) }
    func artifactDigest(_ path: String, expected: TwinArtifactNode, limit: UInt64) throws -> String { contentReads += 1; throw TwinGitError.unsafe("Alias admission must not hash content") }
    func ensurePrivateDirectory(_ path: String) throws { XCTFail("Metadata guard mutated filesystem") }
    func writePrivate(_ data: Data, path: String) throws { XCTFail("Metadata guard wrote content") }
    func removePrivateFile(_ path: String) throws { XCTFail("Metadata guard removed content") }
    func artifactMove(_ source: String, _ destination: String, expected: TwinArtifactNode) throws { XCTFail("Metadata guard moved content") }
    func artifactCreatePrivateDirectory(_ path: String) throws { XCTFail("Metadata guard created directory") }
    func artifactSyncDirectory(_ path: String) throws { XCTFail("Metadata guard synced mutable data") }
}
