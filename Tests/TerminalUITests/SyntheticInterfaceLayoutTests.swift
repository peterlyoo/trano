import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class SyntheticInterfaceLayoutTests: XCTestCase {
    // Implements: FR-SET-34, FR-SET-40, FR-SET-45, FR-SET-46; regression FR-NAV-6
    @MainActor func testDefaultGeometryHasFortyPointToolbarTwentyEightPointPaneHeaderAndNoOuterGap() async throws {
        for size in [NSSize(width: 900, height: 620), NSSize(width: 1100, height: 760)] {
            let fixture = makeFixture(size: size)
            defer { fixture.registry.views.removeAll() }
            try await settle(fixture)
            let toolbar = try rect("workspace-header", fixture)
            let pane = try rect("pane-header", fixture)
            let terminal = try rect("terminal", fixture)
            XCTAssertEqual(toolbar, NSRect(x: 0, y: 0, width: size.width, height: 40))
            XCTAssertEqual(pane, NSRect(x: 0, y: 41, width: size.width, height: 28))
            XCTAssertEqual(terminal, NSRect(x: 0, y: 69, width: size.width, height: size.height - 69))
            XCTAssertEqual(terminal.minX, pane.minX)
            XCTAssertEqual(terminal.maxX, fixture.hosting.bounds.width)
            XCTAssertEqual(terminal.maxY, fixture.hosting.bounds.height)
            for scale in [1, 2] {
                let bitmap = try capture(fixture.hosting, scale: scale)
                try assertTerminalPaint(bitmap, at: NSPoint(x: terminal.midX, y: terminal.midY), scale: scale)
                for point in [NSPoint(x: 0.5, y: 0.5), NSPoint(x: size.width - 0.5, y: 0.5),
                              NSPoint(x: 0.5, y: 41.5), NSPoint(x: size.width - 0.5, y: 68.5),
                              NSPoint(x: 0.5, y: size.height - 0.5), NSPoint(x: size.width - 0.5, y: size.height - 0.5)] {
                    try assertOpaque(bitmap, point: point, scale: scale, label: "outer/pane edge")
                }
                for x in stride(from: 0.5, to: size.width, by: 7) {
                    try assertOpaque(bitmap, point: NSPoint(x: x, y: 40.5), scale: scale, label: "toolbar/terminal boundary")
                }
                try writePreview(bitmap, label: "default-\(Int(size.width))-\(scale)x")
            }
        }
    }

    // Implements: FR-SET-34, FR-SET-43; regression FR-NAV-6
    @MainActor func testAboveLeftAndRightToolbarsAndSidebarsStayContainedWithOpaqueSeparators() async throws {
        let size = NSSize(width: 900, height: 620)
        for position in [InterfaceToolbarLayout.above, .left, .right] {
            var preferences = InterfacePreferences()
            preferences.toolbarLayout = position
            var context = InterfaceContext()
            context.sidebarVisible = true
            let fixture = makeFixture(size: size, preferences: preferences, context: context, sidebar: true)
            defer { fixture.registry.views.removeAll() }
            try await settle(fixture)
            let sidebar = try rect("sidebar", fixture)
            let terminal = try rect("terminal", fixture)
            for view in fixture.registry.views.values {
                let bounds = topRect(view, in: fixture.hosting)
                XCTAssertTrue(fixture.hosting.bounds.insetBy(dx: -0.01, dy: -0.01).contains(bounds), "\(position): \(view.identifier?.rawValue ?? "") escaped: \(bounds)")
            }
            XCTAssertEqual(sidebar.width, 216, accuracy: 0.01)
            if position == .above {
                XCTAssertEqual(try rect("workspace-header", fixture).height, 40)
                XCTAssertEqual(terminal.minX, 217)
                XCTAssertEqual(terminal.minY, 69)
            } else {
                let toolbar = try rect("vertical-header", fixture)
                XCTAssertEqual(toolbar.height, 40)
                XCTAssertEqual(toolbar.minX, sidebar.minX)
                XCTAssertEqual(toolbar.maxX, sidebar.maxX)
                XCTAssertEqual(terminal.minY, 28)
                XCTAssertEqual(terminal.minX, position == .left ? 217 : 0)
                XCTAssertEqual(terminal.width, size.width - 217)
            }
            let separatorX = position == .right ? size.width - 216.5 : 216.5
            for scale in [1, 2] {
                let bitmap = try capture(fixture.hosting, scale: scale)
                try assertTerminalPaint(bitmap, at: NSPoint(x: terminal.midX, y: terminal.midY), scale: scale)
                for y in stride(from: 80.5, to: size.height, by: 11) {
                    try assertOpaque(bitmap, point: NSPoint(x: separatorX, y: y), scale: scale, label: "\(position) sidebar boundary")
                }
                try writePreview(bitmap, label: "\(position.rawValue)-\(scale)x")
            }
        }
    }

    // Implements: FR-SET-35
    @MainActor func testToolbarHoverOverlaysDoNotResizeOrReplaceTheTerminalViewport() async throws {
        for position in [InterfaceToolbarLayout.above, .left, .right] {
            var preferences = InterfacePreferences()
            preferences.toolbarLayout = position
            preferences.toolbarBehavior = .onHover
            var context = InterfaceContext()
            context.sidebarVisible = position != .above
            let fixture = makeFixture(preferences: preferences, context: context, sidebar: context.sidebarVisible)
            defer { fixture.registry.views.removeAll() }
            try await settle(fixture)
            let original = try XCTUnwrap(fixture.registry.views["terminal"])
            let before = try rect("terminal", fixture)
            let sidebarBefore = fixture.registry.views["sidebar"].map { topRect($0, in: fixture.hosting) }
            context.toolbarHovered = true
            fixture.hosting.rootView = SyntheticInterfaceFixture(size: fixture.size, preferences: preferences, context: context, sidebar: context.sidebarVisible, registry: fixture.registry)
            try await settle(fixture)
            XCTAssertEqual(try rect("terminal", fixture), before)
            XCTAssertTrue(fixture.registry.views["terminal"] === original)
            let headerID = position == .above ? "workspace-header" : "vertical-header"
            let toolbar = try rect(headerID, fixture)
            XCTAssertEqual(toolbar.height, 40)
            XCTAssertTrue(fixture.hosting.bounds.contains(toolbar))
            if let sidebarBefore { XCTAssertEqual(try rect("sidebar", fixture), sidebarBefore) }
            context.toolbarHovered = false
            fixture.hosting.rootView = SyntheticInterfaceFixture(size: fixture.size, preferences: preferences, context: context, sidebar: context.sidebarVisible, registry: fixture.registry)
            try await settle(fixture)
            XCTAssertEqual(try rect("terminal", fixture), before)
            XCTAssertTrue(fixture.registry.views["terminal"] === original)
        }
    }

    // Implements: FR-SET-41
    @MainActor func testPaneHeaderHoverOverlaysPreserveTerminalBoundsAndNativeViewIdentity() async throws {
        var preferences = InterfacePreferences()
        preferences.paneHeaderBehavior = .onHover
        var context = InterfaceContext()
        let fixture = makeFixture(preferences: preferences, context: context)
        defer { fixture.registry.views.removeAll() }
        try await settle(fixture)
        let terminal = try XCTUnwrap(fixture.registry.views["terminal"])
        let before = try rect("terminal", fixture)
        XCTAssertEqual(before.minY, 41)
        XCTAssertEqual(before.maxY, fixture.size.height)
        context.paneHovered = true
        fixture.hosting.rootView = SyntheticInterfaceFixture(size: fixture.size, preferences: preferences, context: context, sidebar: false, registry: fixture.registry)
        try await settle(fixture)
        XCTAssertEqual(try rect("terminal", fixture), before)
        XCTAssertTrue(fixture.registry.views["terminal"] === terminal)
        let header = try rect("pane-header", fixture)
        XCTAssertEqual(header, NSRect(x: 0, y: 41, width: fixture.size.width, height: 28))
        XCTAssertTrue(before.contains(header))
    }

    // Implements: FR-SET-45, FR-SET-46
    @MainActor func testExplicitPaddingIsInsideThePaneAndDoesNotCreateTransparentOuterMargins() async throws {
        var preferences = InterfacePreferences()
        preferences.paddingX = 12
        preferences.paddingY = 8
        preferences.paneHeaderBehavior = .hidden
        let fixture = makeFixture(preferences: preferences)
        defer { fixture.registry.views.removeAll() }
        try await settle(fixture)
        XCTAssertEqual(try rect("terminal", fixture), NSRect(x: 12, y: 49, width: fixture.size.width - 24, height: fixture.size.height - 57))
        for scale in [1, 2] {
            let bitmap = try capture(fixture.hosting, scale: scale)
            for point in [NSPoint(x: 1, y: 50), NSPoint(x: fixture.size.width - 1, y: 50),
                          NSPoint(x: fixture.size.width / 2, y: 42), NSPoint(x: fixture.size.width / 2, y: fixture.size.height - 1)] {
                try assertOpaque(bitmap, point: point, scale: scale, label: "configured interior padding")
            }
        }
    }

    @MainActor private func makeFixture(size: NSSize = NSSize(width: 900, height: 620), preferences: InterfacePreferences = InterfacePreferences(), context: InterfaceContext = InterfaceContext(), sidebar: Bool = false) -> Fixture {
        let registry = ProbeRegistry()
        let root = SyntheticInterfaceFixture(size: size, preferences: preferences, context: context, sidebar: sidebar, registry: registry)
        let host = TransparentHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        host.sizingOptions = []
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        return Fixture(size: size, hosting: host, registry: registry)
    }

    @MainActor private func settle(_ fixture: Fixture) async throws {
        fixture.hosting.layoutSubtreeIfNeeded()
        fixture.hosting.needsDisplay = true
        fixture.hosting.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(35))
        fixture.hosting.layoutSubtreeIfNeeded()
        fixture.hosting.displayIfNeeded()
        XCTAssertNil(fixture.hosting.window)
    }

    @MainActor private func rect(_ id: String, _ fixture: Fixture) throws -> NSRect {
        topRect(try XCTUnwrap(fixture.registry.views[id], "Missing native probe \(id)"), in: fixture.hosting)
    }
    @MainActor private func topRect(_ view: NSView, in root: NSView) -> NSRect {
        let rect = view.convert(view.bounds, to: root)
        return NSRect(x: rect.minX, y: root.isFlipped ? rect.minY : root.bounds.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
    @MainActor private func capture(_ view: NSView, scale: Int) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width) * scale,
            pixelsHigh: Int(view.bounds.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = view.bounds.size
        if let bytes = bitmap.bitmapData { memset(bytes, 0, bitmap.bytesPerRow * bitmap.pixelsHigh) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
    @MainActor private func assertOpaque(_ bitmap: NSBitmapImageRep, point: NSPoint, scale: Int, label: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let color = try XCTUnwrap(bitmap.colorAt(x: Int(point.x * CGFloat(scale)), y: Int(point.y * CGFloat(scale))), file: file, line: line)
        XCTAssertEqual(color.alphaComponent, 1, accuracy: 1.0 / 255, "\(label), \(scale)x at \(point)", file: file, line: line)
    }
    @MainActor private func assertTerminalPaint(_ bitmap: NSBitmapImageRep, at point: NSPoint, scale: Int) throws {
        let raw = try XCTUnwrap(bitmap.colorAt(x: Int(point.x * CGFloat(scale)), y: Int(point.y * CGFloat(scale))))
        let color = try XCTUnwrap(raw.usingColorSpace(.sRGB))
        XCTAssertEqual(color.alphaComponent, 1, accuracy: 1.0 / 255)
        XCTAssertLessThan(color.redComponent, color.greenComponent)
        XCTAssertLessThan(color.greenComponent, color.blueComponent)
        XCTAssertLessThan(color.blueComponent, 0.8)
    }
    @MainActor private func writePreview(_ bitmap: NSBitmapImageRep, label: String) throws {
        if let folder = ProcessInfo.processInfo.environment["TRANO_SYNTHETIC_LAYOUT_PREVIEW"] {
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(label + ".png"))
        }
    }
    @MainActor private struct Fixture {
        let size: NSSize
        let hosting: TransparentHostingView<SyntheticInterfaceFixture>
        let registry: ProbeRegistry
    }
}

@MainActor private final class ProbeRegistry {
    var views: [String: PaintProbe] = [:]
}
@MainActor private final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}
@MainActor private final class PaintProbe: NSView {
    var paint: NSColor
    init(id: String, color: NSColor) { paint = color; super.init(frame: .zero); identifier = NSUserInterfaceItemIdentifier(id) }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { paint.alphaComponent == 1 }
    override func draw(_ dirtyRect: NSRect) { NSBezierPath(rect: bounds).addClip(); paint.setFill(); bounds.fill() }
}
private struct NativeProbe: NSViewRepresentable {
    let id: String
    let color: NSColor
    let registry: ProbeRegistry
    func makeNSView(context: Context) -> PaintProbe {
        let view = PaintProbe(id: id, color: color)
        registry.views[id] = view
        return view
    }
    func updateNSView(_ view: PaintProbe, context: Context) { view.paint = color; view.needsDisplay = true }
}
private struct SyntheticInterfaceFixture: View {
    let size: NSSize
    let preferences: InterfacePreferences
    let context: InterfaceContext
    let sidebar: Bool
    let registry: ProbeRegistry
    @Namespace private var highlight
    var body: some View {
        let plan = preferences.resolve(context)
        InterfaceWorkspaceLayout(plan: plan, sidebarVisible: sidebar,
            header: { probe("workspace-header", color: NSColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1)) },
            verticalHeader: { probe("vertical-header", color: NSColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1)).frame(height: 40) },
            sidebar: { probe("sidebar", color: NSColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1)) },
            content: {
                InterfacePaneChrome(plan: plan, active: false, namespace: highlight,
                    header: { probe("pane-header", color: .clear) },
                    content: { probe("terminal", color: NSColor(srgbRed: 0.125, green: 0.25, blue: 0.375, alpha: 1)).id("inert-terminal") })
            })
        .frame(width: size.width, height: size.height)
    }
    private func probe(_ id: String, color: NSColor) -> some View {
        NativeProbe(id: id, color: color, registry: registry).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
