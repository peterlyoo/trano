import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import XCTest
@testable import TerminalCore

final class DeveloperSettingsTests: XCTestCase {
    // Implements: FR-SET-98, FR-SET-101, FR-SET-102, FR-SET-103, FR-SET-104
    func testDeveloperMasterGatesExperimentalBehavior() throws {
        var value = DeveloperPreferences()
        value.cursorEffect = .comet; value.terminalAnchoring = .bottom
        value.newQuickSwitcher = true; value.quickLookLinks = true
        XCTAssertEqual(value.effectiveCursorEffect, .none)
        XCTAssertEqual(value.effectiveAnchoring, .top)
        XCTAssertFalse(value.usesNewQuickSwitcher); XCTAssertFalse(value.previewsLinks)
        value.enabled = true
        XCTAssertEqual(value.effectiveCursorEffect, .comet)
        XCTAssertEqual(value.effectiveAnchoring, .bottom)
        XCTAssertTrue(value.usesNewQuickSwitcher); XCTAssertTrue(value.previewsLinks)
    }

    // Implements: FR-SET-98, FR-SET-106, FR-SET-107
    func testBackwardDecodeAndInvalidCheckoutSelection() throws {
        let value = try JSONDecoder().decode(DeveloperPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(value, DeveloperPreferences())
        var bad = value; bad.installationLocation = .sourceCheckout
        XCTAssertThrowsError(try bad.validate())
        bad.sourceDirectory = "/tmp/checkout\nother"
        XCTAssertThrowsError(try bad.validate())
    }

    // Implements: FR-SET-98, FR-SET-99, FR-SET-100, FR-SET-105
    func testIndependentSidecarFieldwiseMergeAndCancel() throws {
        let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DeveloperSettingsStore(root: directory)
        let baseline = try store.load()
        var first = baseline; first.enabled = true
        _ = try store.merge(baseline: baseline, edited: first)
        var second = baseline; second.updateChannel = .bleedingEdge
        let merged = try store.merge(baseline: baseline, edited: second)
        XCTAssertTrue(merged.enabled); XCTAssertEqual(merged.updateChannel, .bleedingEdge)
        var canceled = merged; canceled.cursorEffect = .warp
        XCTAssertEqual(try store.load(), merged)
        let path = directory.appendingPathComponent("developer-settings.json")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // Implements: FR-SET-99, FR-SET-100, FR-SET-105
    func testUpdateReadinessDoesNotInventFeedAndUsesSignedChannels() {
        var preferences = DeveloperPreferences()
        preferences.installUpdatesAutomatically = true
        preferences.updateChannel = .bleedingEdge
        let unavailable = DeveloperUpdatePolicy.resolve(preferences, info: [:], inheritedAutomaticDownloads: true)
        XCTAssertFalse(unavailable.available); XCTAssertFalse(unavailable.immediateInstallation)
        XCTAssertFalse(unavailable.reason.isEmpty)
        let ready = DeveloperUpdatePolicy.resolve(preferences, info: signedUpdateInfo(), inheritedAutomaticDownloads: false)
        XCTAssertTrue(ready.available); XCTAssertTrue(ready.automaticDownloads)
        XCTAssertTrue(ready.immediateInstallation); XCTAssertEqual(ready.channels, ["bleeding-edge"])
        preferences.installUpdatesAutomatically = false; preferences.downloadUpdatesAutomatically = nil; preferences.updateChannel = .preview
        let inherited = DeveloperUpdatePolicy.resolve(preferences, info: signedUpdateInfo(), inheritedAutomaticDownloads: true)
        XCTAssertTrue(inherited.automaticDownloads); XCTAssertFalse(inherited.immediateInstallation); XCTAssertEqual(inherited.channels, [])
    }

    // Implements: FR-SET-101
    func testDefaultAnchoringUsesFullBoundsAndExplicitBottomPreservesWholeRows() {
        let bounds = CGRect(x: 0, y: 0, width: 801, height: 413)
        for flipped in [true, false] {
            XCTAssertEqual(TerminalAnchoringLayout.frame(bounds: bounds, rowHeight: 20, anchoring: .top, flipped: flipped), bounds)
        }
        XCTAssertEqual(TerminalAnchoringLayout.frame(bounds: bounds, rowHeight: 20, anchoring: .bottom, flipped: true), CGRect(x: 0, y: 13, width: 801, height: 400))
        XCTAssertEqual(TerminalAnchoringLayout.frame(bounds: bounds, rowHeight: 20, anchoring: .bottom, flipped: false), CGRect(x: 0, y: 0, width: 801, height: 400))
        XCTAssertEqual(TerminalAnchoringLayout.frame(bounds: bounds, rowHeight: 0, anchoring: .bottom, flipped: false), bounds)
    }

    // Implements: FR-SET-102
    func testCursorEffectsAreBoundedExpireAndRespectReducedMotion() {
        let previous = CGRect(x: 10, y: 30, width: 8, height: 18)
        let current = CGRect(x: 120, y: 30, width: 8, height: 18)
        for style in [DeveloperCursorEffect.warp, .comet, .blaze] {
            let points = CursorEffectGeometry.points(style: style, previous: previous, current: current, elapsed: 0.03, reduceMotion: false)
            XCTAssertFalse(points.isEmpty); XCTAssertLessThanOrEqual(points.count, 24)
            XCTAssertTrue(points.allSatisfy { $0.radius.isFinite && $0.opacity.isFinite && $0.opacity > 0 && $0.opacity <= 1 })
            XCTAssertTrue(CursorEffectGeometry.points(style: style, previous: previous, current: current, elapsed: 1, reduceMotion: false).isEmpty)
            XCTAssertTrue(CursorEffectGeometry.points(style: style, previous: previous, current: current, elapsed: 0.03, reduceMotion: true).isEmpty)
        }
        XCTAssertNotEqual(CursorEffectGeometry.points(style: .warp, previous: previous, current: current, elapsed: 0.03, reduceMotion: false), CursorEffectGeometry.points(style: .comet, previous: previous, current: current, elapsed: 0.03, reduceMotion: false))
    }

    // Implements: FR-SET-104
    func testQuickLookAcceptsOnlyFilesAndWebWithoutEmbeddedCredentials() throws {
        let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("한글.md"); try Data("text".utf8).write(to: file)
        XCTAssertEqual(QuickLookLinkTarget.parse("한글.md", cwd: directory), .file(file))
        XCTAssertEqual(QuickLookLinkTarget.parse("https://example.com/docs?q=한글", cwd: directory), .web(URL(string: "https://example.com/docs?q=한글")!))
        XCTAssertNil(QuickLookLinkTarget.parse("javascript:alert(1)", cwd: directory))
        XCTAssertNil(QuickLookLinkTarget.parse("https://user:secret@example.com", cwd: directory))
        XCTAssertNil(QuickLookLinkTarget.parse("missing.md", cwd: directory))
    }

    // Implements: FR-SET-103
    func testNewSwitcherIncludesOpenWorkspacesTabsPanesAndReportingTasks() throws {
        var layout = WorkspaceLayout()
        let workspace = layout.addWorkspace(title: "silver-harbor")
        let tab = layout.addTab(paneID: "pane-1")
        var session = TerminalSession(id: "pane-1", title: "Fix API", cwd: "/tmp", pid: 10)
        session.agentTasks = [AgentTask(id: "task-1", name: "Review build", agent: .codex)]
        let entries = DeveloperQuickSwitcher.entries(layout: layout, sessions: [session], query: "")
        XCTAssertEqual(Set(entries.map(\.kind)), [.workspace, .tab, .pane, .process])
        XCTAssertEqual(entries.first(where: { $0.kind == .process })?.paneID, "pane-1")
        XCTAssertEqual(entries.first(where: { $0.kind == .pane })?.tabID, tab)
        XCTAssertEqual(entries.first(where: { $0.kind == .workspace })?.workspaceID, workspace)
        XCTAssertEqual(DeveloperQuickSwitcher.entries(layout: layout, sessions: [session], query: "review").count, 1)
        layout.closeWorkspace(workspace)
        XCTAssertTrue(DeveloperQuickSwitcher.entries(layout: layout, sessions: [session], query: "").isEmpty)
    }

    // Implements: FR-SET-106, FR-SET-107, FR-SET-108, FR-SET-109, FR-SET-110, FR-SET-111
    func testCheckoutInspectorVerifiesMetadataAndHashesActualExecutable() throws {
        let directory = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try makeCheckout(in: directory)
        let metadata = try DeveloperInstallationInspector.sourceBundle(directory: directory)
        XCTAssertEqual(metadata.apiVersion, 1); XCTAssertEqual(metadata.version, "0.1.0")
        XCTAssertEqual(metadata.commit, String(repeating: "a", count: 40))
        XCTAssertEqual(metadata.finalSHA256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertTrue(metadata.executable.path.hasPrefix(bundle.path + "/"))
        XCTAssertThrowsError(try DeveloperInstallationInspector.inspect(bundle: bundle, expectedAPIVersion: 2))
        let executable = metadata.executable
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
        XCTAssertThrowsError(try DeveloperInstallationInspector.sourceBundle(directory: directory))
    }

    private func fixtureDirectory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent("trano-developer-unit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return value
    }
    private func signedUpdateInfo() -> [String: Any] {
        ["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString(), "CFBundleVersion": "1", "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true]
    }
    private func makeCheckout(in directory: URL) throws -> URL {
        try Data("// swift-tools-version: 5.9\n".utf8).write(to: directory.appendingPathComponent("Package.swift"))
        let bundle = directory.appendingPathComponent("build/Trano.app/Contents/Helpers/Trano Service.app")
        let executable = bundle.appendingPathComponent("Contents/MacOS/TranoApp")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let info: [String: Any] = ["CFBundleExecutable": "TranoApp", "CFBundleIdentifier": "dev.trano.activity", "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1", "TranoBuildID": String(repeating: "b", count: 64), "TranoSourceCommit": String(repeating: "a", count: 40), "TranoAPIVersion": 1]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        return bundle
    }
}
