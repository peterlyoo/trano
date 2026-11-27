import AppKit
import XCTest
import SwiftUI
@testable import TerminalCore
@testable import TranoApp

@MainActor final class WindowOpacityPreviewTests: XCTestCase {
    func testDraftDragChangesEffectiveWindowImmediatelyWithoutPersisting() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let owner = UUID()
        f.store.beginWindowOpacityPreview(owner: owner, opacity: 0.8)
        for value in [0.7, 0.1, 0.0, 1] {
            f.store.updateWindowOpacityPreview(owner: owner, opacity: value)
            XCTAssertEqual(f.store.effectiveWindowOpacity, value)
            XCTAssertEqual(f.store.interfaceResolvedSettings(for: "ordinary").appearance.opacity, value)
            XCTAssertEqual(f.store.state.settings.appearance.opacity, 0.8)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("state.json").path))
        }
    }
    func testCancelUsesLatestStoredValueAndOldOwnerCannotChangeNewPreview() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let old = UUID(), next = UUID()
        f.store.beginWindowOpacityPreview(owner: old, opacity: 0.8)
        f.store.updateWindowOpacityPreview(owner: old, opacity: 0.2)
        f.store.beginWindowOpacityPreview(owner: next, opacity: 0.6)
        f.store.updateWindowOpacityPreview(owner: old, opacity: 0)
        f.store.endWindowOpacityPreview(owner: old)
        XCTAssertEqual(f.store.effectiveWindowOpacity, 0.6)
        f.store.state.settings.appearance.opacity = 0.4
        f.store.endWindowOpacityPreview(owner: next)
        XCTAssertEqual(f.store.effectiveWindowOpacity, 0.4)
        XCTAssertNil(f.store.windowOpacityPreview)
    }
    func testProfileOverridesAndInvalidDraftValuesArePreserved() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var settings = TerminalSettings(); settings.appearance.opacity = 0.65
        let profile = AppearanceProfile(name: "Retain", settings: settings)
        f.store.state.settings.appearanceProfiles = [profile]
        f.store.state.settings.paneAppearanceProfiles["profile"] = profile.id
        let owner = UUID()
        f.store.beginWindowOpacityPreview(owner: owner, opacity: 0.5)
        for value in [-0.1, 1.01, .nan, .infinity] { f.store.updateWindowOpacityPreview(owner: owner, opacity: value) }
        XCTAssertEqual(f.store.effectiveWindowOpacity, 0.5)
        XCTAssertEqual(f.store.interfaceResolvedSettings(for: "profile").appearance.opacity, 0.65)
        XCTAssertEqual(f.store.interfaceResolvedSettings(for: "ordinary").appearance.opacity, 0.5)
    }
    func testActualSettingsSliderUpdatesParentWindowAndUnmoutingCancelsPreview() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let main = NSHostingView(rootView: WorkspaceView(store: f.store))
        let mainWindow = WorkspaceWindow.make(contentRect: NSRect(x: -12000, y: -12000, width: 1000, height: 700), contentView: main)
        let draft = SettingsDraft(settings: f.store.state.settings, automaticallyChecksForUpdates: false, automaticallyDownloadsUpdates: false)
        let settings = NSHostingView(rootView: SettingsView(store: f.store, settingsDraft: draft))
        let settingsWindow = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 880, height: 630), styleMask: [], backing: .buffered, defer: false)
        settingsWindow.isReleasedWhenClosed = false; settingsWindow.contentView = settings
        mainWindow.orderFrontRegardless(); settingsWindow.orderFrontRegardless()
        defer { settingsWindow.contentView = nil; settingsWindow.close(); mainWindow.contentView = nil; mainWindow.close() }
        for _ in 0..<6 { main.layoutSubtreeIfNeeded(); settings.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        func slider(_ view: NSView) -> WindowOpacityNativeSlider? {
            if let value = view as? WindowOpacityNativeSlider { return value }
            return view.subviews.lazy.compactMap { slider($0) }.first
        }
        let control = try XCTUnwrap(slider(settings))
        XCTAssertTrue(control.isContinuous); XCTAssertEqual(control.minValue, 0); XCTAssertEqual(control.maxValue, 1)
        for value in [0.1, 0.0, 0.7] {
            control.doubleValue = value
            XCTAssertTrue(control.sendAction(control.action, to: control.target))
            for _ in 0..<4 { main.layoutSubtreeIfNeeded(); settings.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(draft.settings.appearance.opacity, value)
            XCTAssertEqual(f.store.effectiveWindowOpacity, value)
            XCTAssertEqual(f.store.state.settings.appearance.opacity, 0.8)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(main.bounds.width), pixelsHigh: Int(main.bounds.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = main.bounds.size
            main.cacheDisplay(in: main.bounds, to: bitmap)
            XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 300, y: 20)).alphaComponent, value, accuracy: 2.0 / 255)
        }
        settingsWindow.contentView = nil
        for _ in 0..<4 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(f.store.windowOpacityPreview)
        XCTAssertEqual(f.store.effectiveWindowOpacity, 0.8)
    }
    func testZeroOpacityMaterialIsHiddenAndCannotCapturePointerInput() {
        let material = InterfaceMaterialView()
        material.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        InterfaceMaterialBackground(enabled: true, dark: true, opacity: 0).apply(to: material)
        XCTAssertTrue(material.isHidden); XCTAssertEqual(material.alphaValue, 0)
        XCTAssertNil(material.hitTest(NSPoint(x: 20, y: 20)))
        InterfaceMaterialBackground(enabled: true, dark: true, opacity: 0.7).apply(to: material)
        XCTAssertFalse(material.isHidden); XCTAssertEqual(material.alphaValue, 0.7)
        XCTAssertNil(material.hitTest(NSPoint(x: 20, y: 20)))
    }

    private func fixture() throws -> (root: URL, store: AppStore) {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-preview-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        let binding = SupervisorBinding(paneID: UUID().uuidString, backendPID: 4711,
            configuration: SupervisorConfiguration(provider: .claude, cwd: root.path))
        let store = AppStore(runtime: runtime, externalBinding: binding)
        store.state.settings.appearance.opacity = 0.8
        return (root, store)
    }
}
