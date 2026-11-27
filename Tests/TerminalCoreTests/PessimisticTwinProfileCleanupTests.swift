import Foundation
import Darwin
import XCTest
@testable import TerminalCore

final class PessimisticTwinProfileCleanupTests: XCTestCase {
    // Implements: FR-TWIN-4, FR-TWIN-9.
    func testOwnedProfileRemovalDoesNotFollowChildLinksOrDeleteSiblingResources() throws {
        let f = try Fixture(); defer { f.remove() }
        let source = f.base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let credential = source.appendingPathComponent("auth.json")
        try Data("source-secret-sentinel".utf8).write(to: credential)
        try FileManager.default.createSymbolicLink(at: f.profile.appendingPathComponent("outside"), withDestinationURL: source)
        let worktree = f.round.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: false)
        let ticket = f.round.appendingPathComponent("launch-ticket.json")
        try Data("ticket-sentinel".utf8).write(to: ticket)
        try f.clean()
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.profile.path))
        XCTAssertEqual(try String(contentsOf: credential), "source-secret-sentinel")
        XCTAssertEqual(try String(contentsOf: ticket), "ticket-sentinel")
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path))
    }

    func testUntouchedRoundWithoutTicketOrProfileIsNoop() throws {
        let f = try Fixture(); defer { f.remove() }
        try FileManager.default.removeItem(at: f.round)
        XCTAssertNoThrow(try f.clean(ticketPresent: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.round.path))
    }

    func testProcessAdmissionGetsOnlyExactHeldDescriptorsAndCanRetainProfile() throws {
        let f = try Fixture(); defer { f.remove() }
        var called = false
        XCTAssertThrowsError(try f.clean(processAdmission: { descriptors in
            called = true
            XCTAssertEqual(Set(descriptors.values), [f.profile.path, f.marker.path])
            XCTAssertEqual(descriptors.count, 2)
            for descriptor in descriptors.keys { var info = stat(); XCTAssertEqual(fstat(descriptor, &info), 0) }
            throw TerminalError.invalid("An owned background tool still holds a profile file")
        }))
        XCTAssertTrue(called)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.marker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.profile.appendingPathComponent("auth.json").path))
    }

    func testTopProfileAncestorAndMarkerLinksHoldWithoutFollowingTargets() throws {
        let f = try Fixture(); defer { f.remove() }
        let retained = f.base.appendingPathComponent("retained")
        try FileManager.default.moveItem(at: f.profile, to: retained)
        try FileManager.default.createSymbolicLink(at: f.profile, withDestinationURL: retained)
        XCTAssertThrowsError(try f.clean())
        try FileManager.default.removeItem(at: f.profile)
        try FileManager.default.moveItem(at: retained, to: f.profile)
        let originalRound = f.base.appendingPathComponent("retained-round")
        try FileManager.default.moveItem(at: f.round, to: originalRound)
        try FileManager.default.createSymbolicLink(at: f.round, withDestinationURL: originalRound)
        XCTAssertThrowsError(try f.clean())
        try FileManager.default.removeItem(at: f.round)
        try FileManager.default.moveItem(at: originalRound, to: f.round)
        let markerCopy = f.base.appendingPathComponent("marker-copy")
        try FileManager.default.linkItem(at: f.marker, to: markerCopy)
        XCTAssertThrowsError(try f.clean())
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.profile.path))
        XCTAssertEqual(try String(contentsOf: markerCopy), f.markerContents)
    }

    func testMissingTicketMismatchMarkerOwnerAndInvalidPathPreserveProfile() throws {
        let f = try Fixture(); defer { f.remove() }
        XCTAssertThrowsError(try f.clean(ticketPresent: false))
        XCTAssertThrowsError(try f.clean(profilePath: f.round.path))
        XCTAssertThrowsError(try f.clean(userID: getuid() &+ 1))
        try Data("trano-pessimistic-twin-v1\nother:1:codex\n".utf8).write(to: f.marker)
        XCTAssertThrowsError(try f.clean())
        try FileManager.default.removeItem(at: f.marker)
        XCTAssertThrowsError(try f.clean())
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.profile.path))
    }

    func testIdentityOrPermissionChangeAtFinalAdmissionHoldsDeletion() throws {
        let f = try Fixture(); defer { f.remove() }
        let retained = f.base.appendingPathComponent("retained-profile")
        XCTAssertThrowsError(try f.clean(beforeRemove: {
            try FileManager.default.moveItem(at: f.profile, to: retained)
            try FileManager.default.createDirectory(at: f.profile, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        if FileManager.default.fileExists(atPath: retained.path) {
            try FileManager.default.removeItem(at: f.profile)
            try FileManager.default.moveItem(at: retained, to: f.profile)
        }
        XCTAssertThrowsError(try f.clean(beforeRemove: {
            XCTAssertEqual(chmod(f.profile.path, 0o755), 0)
        }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.marker.path))
    }

    private final class Fixture {
        let base: URL
        let root: URL
        let round: URL
        let profile: URL
        let marker: URL
        let runID = "64a9fb64-62fc-4c93-a0c4-248fb16874a4"
        var markerContents: String { "trano-pessimistic-twin-v1\n\(runID):1:codex\n" }
        init() throws {
            guard let temporary = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw CocoaError(.fileReadUnknown) }
            defer { free(temporary) }
            base = URL(fileURLWithPath: String(cString: temporary)).appendingPathComponent("twin-profile-unit-" + UUID().uuidString)
            root = base.appendingPathComponent("runtime")
            round = root.appendingPathComponent("twins/\(runID)/round-1")
            profile = round.appendingPathComponent("profile")
            marker = profile.appendingPathComponent(".trano-twin-profile")
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for path in [base, root, root.appendingPathComponent("twins"), round.deletingLastPathComponent(), round, profile] {
                guard chmod(path.path, 0o700) == 0 else { throw CocoaError(.fileWriteNoPermission) }
            }
            try Data(markerContents.utf8).write(to: marker)
            guard chmod(marker.path, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
            try Data("copied-private-auth".utf8).write(to: profile.appendingPathComponent("auth.json"))
        }
        func clean(ticketPresent: Bool = true, profilePath: String? = nil, userID: uid_t = getuid(), beforeRemove: () throws -> Void = {},
                   processAdmission: ([Int32: String]) throws -> Void = { _ in }) throws {
            try TwinPrivateProfileCleanup.remove(root: root, runID: runID, round: 1, provider: "codex", profilePath: profilePath ?? profile.path,
                ticketPresent: ticketPresent, userID: userID, beforeRemove: beforeRemove, processAdmission: processAdmission)
        }
        func remove() { try? FileManager.default.removeItem(at: base) }
    }
}
