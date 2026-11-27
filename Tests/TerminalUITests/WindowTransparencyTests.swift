import AppKit
import SwiftUI
import SwiftTerm
import XCTest
@testable import TerminalCore
@testable import TranoApp

@MainActor final class WindowTransparencyTests: XCTestCase {
    // Implements: FR-TRANSP-1, FR-TRANSP-3
    func testWindowTopBottomSidebarAndEmptyContentUseConfiguredBackgroundAlpha() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-alpha-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        let binding = SupervisorBinding(paneID: UUID().uuidString, backendPID: 4711,
            configuration: SupervisorConfiguration(provider: .claude, cwd: root.path))
        let store = AppStore(runtime: runtime, externalBinding: binding)
        let host = NSHostingView(rootView: WorkspaceView(store: store))
        let window = WorkspaceWindow.make(contentRect: NSRect(x: -12000, y: -12000, width: 1100, height: 700), contentView: host)
        window.orderFrontRegardless()
        defer { window.contentView = nil; window.close(); try? FileManager.default.removeItem(at: root) }
        store.showSessionsSidebar = true
        for opacity in [1.0, 0.8, 0.45, 0.05, 0.0] {
            store.state.settings.appearance.opacity = opacity
            for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            let header = try XCTUnwrap(find("workspace-header", in: host))
            let content = try XCTUnwrap(find("terminal-workspace", in: host))
            let top = rect(header, host), terminal = rect(content, host)
            for scale in [1, 2] {
                let image = try capture(host, scale: scale)
                for (name, point) in [("top", NSPoint(x: 300, y: top.midY)),
                                       ("bottom", NSPoint(x: 350, y: host.bounds.height - 12)),
                                       ("sidebar", NSPoint(x: 30, y: terminal.minY + 180)),
                                       ("empty", NSPoint(x: terminal.maxX - 50, y: terminal.minY + 80))] {
                    XCTAssertEqual(try alpha(image, point, scale: scale), opacity, accuracy: 2.0 / 255, "\(name) \(scale)x")
                }
            }
            XCTAssertEqual(window.alphaValue, 1)
            XCTAssertFalse(window.isOpaque)
            XCTAssertEqual(window.backgroundColor?.alphaComponent, 0)
            XCTAssertTrue(store.terminalViews.isEmpty)
        }
    }

    // Implements: FR-TRANSP-2
    func testNativeContainerPaintsAnchoringGapsWithoutRepaintingUnderItsChild() throws {
        let child = AlphaPaintView()
        child.clipsToBounds = true
        child.color = NSColor.black.withAlphaComponent(0.8)
        let container = DeveloperTerminalContainer(terminal: child, rowHeight: { 30 })
        container.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        container.backgroundColor = child.color
        for anchor in [DeveloperTerminalAnchoring.top, .bottom] {
            container.anchoring = anchor
            container.layoutSubtreeIfNeeded()
            for scale in [1, 2] {
                let image = try capture(container, scale: scale)
                for point in [NSPoint(x: 50, y: 2), NSPoint(x: 50, y: 50), NSPoint(x: 50, y: 98)] {
                    XCTAssertEqual(try alpha(image, point, scale: scale), 0.8, accuracy: 2.0 / 255, "\(anchor) \(point)")
                }
            }
        }
    }

    // Implements: FR-TRANSP-2
    func testImageBackgroundAppliesOpacityOnceAfterImageComposition() async throws {
        _ = NSApplication.shared
        let pixel = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        memset(try XCTUnwrap(pixel.bitmapData), 255, pixel.bytesPerRow * pixel.pixelsHigh)
        XCTAssertEqual(try XCTUnwrap(pixel.colorAt(x: 0, y: 0)).alphaComponent, 1)
        let image = NSImage(cgImage: try XCTUnwrap(pixel.cgImage), size: NSSize(width: 1, height: 1))
        var settings = TerminalSettings()
        settings.appearance.opacity = 0.8
        settings.appearance.backgroundImagePath = "/synthetic-image-not-read.png"
        settings.appearance.backgroundImageOpacity = 0.4
        let host = NSHostingView(rootView: TerminalBackgroundSurface(settings: settings, image: image))
        let window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 180, height: 120), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isOpaque = false; window.backgroundColor = .clear
        window.contentView = host; window.orderFrontRegardless()
        defer { window.contentView = nil; window.close() }
        let overrides: [Double?] = [nil, 0.72]
        for override in overrides {
            host.rootView = TerminalBackgroundSurface(settings: settings, image: image, backgroundOpacity: override)
            for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            for scale in [1, 2] {
                let bitmap = try capture(host, scale: scale)
                let center = NSPoint(x: host.bounds.midX, y: host.bounds.midY)
                let color = try XCTUnwrap(bitmap.colorAt(x: Int(center.x) * scale, y: Int(center.y) * scale))
                XCTAssertGreaterThan(color.usingColorSpace(.sRGB)?.redComponent ?? 0, 0.25)
                XCTAssertEqual(try alpha(bitmap, center, scale: scale), override ?? 0.8, accuracy: 2.0 / 255)
            }
        }
    }

    // Implements: FR-TRANSP-1, FR-TRANSP-2
    func testPaneHeaderAndPaddingDoNotMultiplyTheChildBackgroundOpacity() async throws {
        _ = NSApplication.shared
        var context = InterfaceContext(); context.backgroundOpacity = 0.8
        var preferences = InterfacePreferences(); preferences.paddingX = 10; preferences.paddingY = 10
        preferences.highlightActivePaneEdges = false
        let host = NSHostingView(rootView: AlphaPaneFixture(plan: preferences.resolve(context)))
        let window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 200, height: 160), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isOpaque = false; window.backgroundColor = .clear
        window.contentView = host; window.orderFrontRegardless()
        defer { window.contentView = nil; window.close() }
        for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        for scale in [1, 2] {
            let image = try capture(host, scale: scale)
            for point in [NSPoint(x: 100, y: 10), NSPoint(x: 3, y: 100), NSPoint(x: 100, y: 80), NSPoint(x: 100, y: 156)] {
                XCTAssertEqual(try alpha(image, point, scale: scale), 0.8, accuracy: 2.0 / 255, "\(point) \(scale)x")
            }
        }
    }

    // Implements: FR-TRANSP-1, FR-TRANSP-2
    func testNativeTerminalTransparencyKeepsTextCursorAndSelectionOpaque() throws {
        let view = TranoView.makeClipboardTerminal(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        var settings = TerminalSettings(); settings.appearance.opacity = 0.8
        view.configure(settings)
        XCTAssertEqual(view.nativeBackgroundColor.alphaComponent, 0.8, accuracy: 0.001)
        XCTAssertEqual(view.nativeForegroundColor.alphaComponent, 1)
        XCTAssertEqual(view.caretColor.alphaComponent, 1)
        XCTAssertEqual(view.selectedTextBackgroundColor.alphaComponent, 1)
        XCTAssertFalse(view.started)
    }

    private func find(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { self.find(id, in: $0) }.first
    }
    private func rect(_ view: NSView, _ root: NSView) -> NSRect {
        let value = view.convert(view.bounds, to: root)
        return NSRect(x: value.minX, y: root.isFlipped ? value.minY : root.bounds.maxY - value.maxY, width: value.width, height: value.height)
    }
    private func capture(_ view: NSView, scale: Int) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width) * scale,
            pixelsHigh: Int(view.bounds.height) * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
    private func alpha(_ bitmap: NSBitmapImageRep, _ point: NSPoint, scale: Int) throws -> Double {
        Double(try XCTUnwrap(bitmap.colorAt(x: Int(point.x * CGFloat(scale)), y: Int(point.y * CGFloat(scale)))).alphaComponent)
    }
}

@MainActor private final class AlphaPaintView: NSView {
    var color = NSColor.clear
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); dirtyRect.fill() }
}

private struct AlphaPaneFixture: View {
    let plan: InterfacePresentation
    @Namespace private var namespace
    var body: some View {
        InterfacePaneChrome(plan: plan, active: false, namespace: namespace,
            header: { Color.clear }, content: { Color.black.opacity(0.8) })
    }
}
