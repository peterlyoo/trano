import AppKit
import SwiftUI
import XCTest
import TerminalCore
@testable import TranoApp

final class ProfilesEntryDiagnosticTests: XCTestCase {
    // Implements: U05, U21
    @MainActor func testIsolatedProfilesMountRecordsColdAndWarmMenuCost() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-profile-entry-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        var settings = TerminalSettings()
        settings.automaticRestore = false
        settings.appearanceProfiles = [AppearanceProfile(name: "Reading", settings: settings)]
        try runtime.update { $0.settings = settings }
        let store = AppStore(runtime: runtime, recoverOnStartup: false)
        let ready = Date().addingTimeInterval(3)
        while store.loading && Date() < ready { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.loading)
        defer { try? FileManager.default.removeItem(at: root) }
        var samples: [[String: Any]] = []
        for iteration in 0..<3 {
            let draft = SettingsDraft(settings: settings, automaticallyChecksForUpdates: true, automaticallyDownloadsUpdates: false)
            let started = ProcessInfo.processInfo.systemUptime
            let hosting = NSHostingView(rootView: ProfilesEntryFixture(store: store, draft: draft))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.setFrameOrigin(NSPoint(x: -14000, y: -14000))
            hosting.layoutSubtreeIfNeeded()
            let synchronousMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
            let deadline = Date().addingTimeInterval(3)
            while popups(in: hosting).count < 2 && Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
                hosting.layoutSubtreeIfNeeded()
            }
            let controls = popups(in: hosting)
            XCTAssertGreaterThanOrEqual(controls.count, 2)
            XCTAssertEqual(draft.settings, settings)
            XCTAssertEqual(try runtime.state().settings, settings)
            XCTAssertTrue(try runtime.list().isEmpty)
            samples.append([
                "iteration": iteration,
                "synchronous_mount_ms": synchronousMilliseconds,
                "settled_mount_ms": (ProcessInfo.processInfo.systemUptime - started) * 1000,
                "native_font_menu_count": controls.count,
                "unopened_menu_item_counts": controls.map(\.numberOfItems)
            ])
            window.close()
        }
        if let path = ProcessInfo.processInfo.environment["TRANO_PROFILES_ENTRY_METRICS"] {
            let data = try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path))
        }
    }

    @MainActor private func popups(in view: NSView) -> [NSPopUpButton] {
        (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap { popups(in: $0) }
    }
}

@MainActor private struct ProfilesEntryFixture: View {
    @ObservedObject var store: AppStore
    @ObservedObject var draft: SettingsDraft
    var body: some View {
        ProfileAppearanceView(store: store, embedded: true, draft: $draft.settings)
            .frame(width: 680, height: 480)
    }
}
