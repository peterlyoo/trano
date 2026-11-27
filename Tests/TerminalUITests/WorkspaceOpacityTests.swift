import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class WorkspaceOpacityTests: XCTestCase {
    // Implements: FR-NAV-6, U05, U21
    @MainActor func testChromeAndSplitBoundariesAreOpaqueAtBothCaptureScales() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        var evidence: [[String: Any]] = []
        for axis in [SplitAxis.horizontal, .vertical] {
            fixture.store.state.layout.tabs[0].tree = .split(id: "opacity-split", axis: axis, ratio: 0.43,
                first: .pane(fixture.panes[0].id), second: .pane(fixture.panes[1].id))
            for (size, sidebar) in [(NSSize(width: 1000, height: 700), false), (NSSize(width: 900, height: 620), true)] {
                fixture.store.showSessionsSidebar = sidebar
                fixture.window.setFrame(NSRect(origin: NSPoint(x: -12000, y: -12000), size: size), display: true)
                fixture.hosting.layoutSubtreeIfNeeded()
                fixture.window.update()
                try await Task.sleep(for: .milliseconds(60))
                let header = try XCTUnwrap(region("workspace-header", in: fixture.hosting))
                let workspace = try XCTUnwrap(region("terminal-workspace", in: fixture.hosting))
                let headerRect = topRect(header, in: fixture.hosting)
                let workspaceRect = topRect(workspace, in: fixture.hosting)
                let paneHeaders = try fixture.panes.map { pane in
                    topRect(try XCTUnwrap(region("pane-header-" + pane.id, in: fixture.hosting)), in: fixture.hosting)
                }
                let terminals = try fixture.panes.map { pane in
                    try XCTUnwrap(fixture.store.terminalViews[pane.id])
                }
                let terminalRects = terminals.map { topRect($0, in: fixture.hosting) }
                var samples: [(String, NSPoint)] = [
                    ("header-boundary-left", NSPoint(x: 100, y: headerRect.maxY + 0.5)),
                    ("header-boundary-right", NSPoint(x: size.width - 30, y: headerRect.maxY + 0.5)),
                    ("window-bottom-left", NSPoint(x: 100, y: workspaceRect.maxY - 0.5)),
                    ("window-bottom-right", NSPoint(x: size.width - 30, y: workspaceRect.maxY - 0.5))
                ]
                for (index, rect) in paneHeaders.enumerated() {
                    samples.append(("pane-\(index)-header-edge", NSPoint(x: rect.minX + 2, y: rect.minY + 2)))
                    samples.append(("pane-\(index)-header-end", NSPoint(x: rect.maxX - 2, y: rect.maxY - 2)))
                }
                if sidebar {
                    samples.append(("sidebar-boundary", NSPoint(x: workspaceRect.minX - 0.5, y: workspaceRect.minY + 100)))
                }
                let splitPoint = axis == .horizontal
                    ? NSPoint(x: (terminalRects[0].maxX + terminalRects[1].minX) / 2, y: workspaceRect.minY + 100)
                    : NSPoint(x: workspaceRect.midX, y: (terminalRects[0].maxY + paneHeaders[1].minY) / 2)
                samples.append(("split-boundary", splitPoint))
                for scale in [1, 2] {
                    let bitmap = try capture(fixture.hosting, scale: scale)
                    var alpha: [String: Double] = [:]
                    for (label, point) in samples {
                        let color = try XCTUnwrap(bitmap.colorAt(x: Int(point.x * CGFloat(scale)), y: Int(point.y * CGFloat(scale))))
                        // cacheDisplay omits a terminal's backing-layer background; composite it under the captured ink.
                        let layerAlpha = zip(terminals, terminalRects).first { $0.1.contains(point) }
                            .flatMap { $0.0.layer?.backgroundColor?.alpha } ?? 0
                        let effective = color.alphaComponent + Double(layerAlpha) * (1 - color.alphaComponent)
                        alpha[label] = effective
                        XCTAssertEqual(effective, 1, accuracy: 1.0 / 255,
                            "\(axis) \(Int(size.width)) scale\(scale) \(label) at \(point) is transparent")
                    }
                    evidence.append(["axis": axis.rawValue, "width": size.width, "height": size.height,
                        "sidebar": sidebar, "capture_scale": scale, "sample_alpha": alpha])
                    if let path = ProcessInfo.processInfo.environment["TRANO_OPACITY_PREVIEW"] {
                        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        try data.write(to: URL(fileURLWithPath: path + "-\(axis.rawValue)-\(Int(size.width))-\(scale)x.png"))
                    }
                }
                for terminal in terminals {
                    XCTAssertEqual(terminal.nativeBackgroundColor.alphaComponent, 1, accuracy: 0.001)
                    XCTAssertEqual(try XCTUnwrap(terminal.layer?.backgroundColor).alpha, 1, accuracy: 0.001)
                }
            }
        }
        if let path = ProcessInfo.processInfo.environment["TRANO_OPACITY_PREVIEW"] {
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: path + "-metrics.json"))
        }
        for pane in fixture.panes {
            let live = try XCTUnwrap(fixture.runtime.list().first { $0.id == pane.id })
            XCTAssertTrue(live.alive)
            XCTAssertEqual(live.pid, pane.pid)
        }
    }

    // Implements: U05, FR-NAV-6
    @MainActor func testOpaqueChromeDoesNotReplaceConfiguredTerminalTransparencyOrProfile() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        fixture.store.state.settings.appearance.opacity = 0.45
        var profileSettings = TerminalSettings()
        profileSettings.background = "#182030"
        profileSettings.appearance.opacity = 0.65
        let profile = AppearanceProfile(name: "Translucent", settings: profileSettings)
        fixture.store.state.settings.appearanceProfiles = [profile]
        fixture.store.state.settings.paneAppearanceProfiles[fixture.panes[1].id] = profile.id
        fixture.hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        let values = [0.45, 0.65]
        for (index, pane) in fixture.panes.enumerated() {
            let terminal = try XCTUnwrap(fixture.store.terminalViews[pane.id])
            XCTAssertEqual(terminal.nativeBackgroundColor.alphaComponent, values[index], accuracy: 0.001)
            XCTAssertEqual(try XCTUnwrap(terminal.layer?.backgroundColor).alpha, values[index], accuracy: 0.001)
        }
        XCTAssertEqual(fixture.store.state.settings.appearance.opacity, 0.45)
        XCTAssertEqual(fixture.store.state.settings.paneAppearanceProfiles[fixture.panes[1].id], profile.id)
        XCTAssertEqual(fixture.store.state.settings.appearanceProfiles, [profile])
        XCTAssertFalse(fixture.window.isOpaque)
        XCTAssertEqual(fixture.window.backgroundColor?.alphaComponent, 0)
    }

    @MainActor private struct Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let panes: [TerminalSession]
        let store: AppStore
        let hosting: NSHostingView<WorkspaceView>
        let window: NSWindow
    }

    @MainActor private func makeFixture() async throws -> Fixture {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-opacity-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        let panes = try (0..<2).map { try runtime.create(title: "Pane \($0)", cwd: root.path, shell: "/bin/sleep", arguments: ["90"]) }
        try runtime.update {
            $0.settings.automaticRestore = false
            $0.layout.addWorkspace(title: "amber-cedar")
            let tab = $0.layout.addTab(paneID: panes[0].id)
            try $0.layout.split(tabID: tab, paneID: panes[1].id, axis: .horizontal)
        }
        let store = AppStore(runtime: runtime, recoverOnStartup: false)
        let hosting = NSHostingView(rootView: WorkspaceView(store: store))
        let window = WorkspaceWindow.make(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), contentView: hosting)
        window.setFrameOrigin(NSPoint(x: -12000, y: -12000))
        window.orderFrontRegardless()
        let deadline = Date().addingTimeInterval(5)
        while (store.loading || panes.contains { store.terminalViews[$0.id]?.process.running != true }) && Date() < deadline {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(store.loading)
        return Fixture(root: root, runtime: runtime, panes: panes, store: store, hosting: hosting, window: window)
    }

    @MainActor private func dispose(_ fixture: Fixture) {
        fixture.window.close()
        for terminal in fixture.store.terminalViews.values { terminal.terminate() }
        for pane in fixture.panes { try? fixture.runtime.terminate(pane.id) }
        try? FileManager.default.removeItem(at: fixture.root)
    }

    @MainActor private func topRect(_ view: NSView, in root: NSView) -> NSRect {
        let rect = view.convert(view.bounds, to: root)
        return NSRect(x: rect.minX, y: root.isFlipped ? rect.minY : root.bounds.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    @MainActor private func capture(_ view: NSView, scale: Int) throws -> NSBitmapImageRep {
        let rect = view.bounds
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width) * scale,
            pixelsHigh: Int(rect.height) * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = rect.size
        view.cacheDisplay(in: rect, to: bitmap)
        return bitmap
    }

    @MainActor private func region(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { self.region(id, in: $0) }.first
    }
}
