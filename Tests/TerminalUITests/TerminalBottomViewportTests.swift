import AppKit
import XCTest
@testable import SwiftTerm
@testable import TranoApp

@MainActor final class TerminalBottomViewportTests: XCTestCase {
    // Implements: FR-CHROME-FOOTER-1, FR-TRANSP-2, FR-SET-53
    func testBottomRemainderMatchesTheTerminalBackgroundAtBothScales() async throws {
        _ = NSApplication.shared
        let terminal = TerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 14, weight: .regular))
        terminal.suspendsRenderingWhenNotVisible = false
        terminal.frameDriver.invalidate()
        terminal.nativeForegroundColor = .white
        let container = DeveloperTerminalContainer(terminal: terminal, rowHeight: { terminal.cellDimension.height })
        let window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 240, height: 123),
                              styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isOpaque = false; window.backgroundColor = .clear
        window.contentView = container; window.orderFrontRegardless()
        defer { window.contentView = nil; window.close() }
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(terminal.frame, container.bounds)
        let remainder = container.bounds.height.truncatingRemainder(dividingBy: terminal.cellDimension.height)
        XCTAssertGreaterThan(remainder, 2)
        for opacity in [1.0, 0.8, 0.45, 0.0] {
            for multiplier in [1.0, 0.82] {
                terminal.nativeBackgroundColor = NSColor(srgbRed: 0.4, green: 0.55, blue: 0.7, alpha: opacity)
                terminal.inactiveBackgroundMultiplier = multiplier
                container.backgroundColor = terminal.nativeBackgroundColor
                terminal.feed(text: "\u{1b}[2J\u{1b}[H\u{1b}[?25lfirst-row\u{1b}[\(terminal.terminalDimensions.rows);1Hlast-row")
                terminal.frameTick()
                terminal.needsDisplay = true
                for _ in 0..<3 { container.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
                for scale in [1, 2] {
                    let bitmap = try capture(terminal, scale: scale)
                    let middle = try color(bitmap, x: 200, y: 60, scale: scale)
                    let bottom = try color(bitmap, x: 200, y: 121, scale: scale)
                    XCTAssertEqual(middle.alphaComponent, opacity, accuracy: 2.0 / 255)
                    XCTAssertEqual(bottom.alphaComponent, middle.alphaComponent, accuracy: 2.0 / 255,
                                   "Bottom opacity must not be applied twice: \(opacity), \(multiplier), \(scale)x")
                    if opacity > 0 {
                        XCTAssertEqual(bottom.redComponent, middle.redComponent, accuracy: 3.0 / 255)
                        XCTAssertEqual(bottom.greenComponent, middle.greenComponent, accuracy: 3.0 / 255)
                        XCTAssertEqual(bottom.blueComponent, middle.blueComponent, accuracy: 3.0 / 255)
                    }
                    if let folder = ProcessInfo.processInfo.environment["TRANO_POPULATED_FOOTER_CAPTURE"] {
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                            URL(fileURLWithPath: folder).appendingPathComponent("bottom-\(opacity)-\(multiplier)-\(scale)x.png"))
                    }
                }
            }
        }
    }

    private func capture(_ view: TerminalView, scale: Int) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width) * scale, pixelsHigh: Int(view.bounds.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = view.bounds.size
        let background = try XCTUnwrap(view.layer?.backgroundColor)
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertEqual(try color(bitmap, x: 200, y: 60, scale: scale).alphaComponent, 0,
                       "AppKit caches the content backing store without its background layer")
        XCTAssertEqual(try color(bitmap, x: 200, y: 121, scale: scale).alphaComponent, 0,
                       "Default-background remainder must use the same backing layer as default cells")
        let result = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: result)).cgContext
        let rect = CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        context.setFillColor(background); context.fill(rect)
        context.draw(try XCTUnwrap(bitmap.cgImage), in: rect)
        result.size = bitmap.size
        let rowHeight = view.cellDimension.height
        let lastRowTop = rowHeight * CGFloat(view.terminalDimensions.rows - 1)
        XCTAssertGreaterThan(try whitePixels(result, top: 0, height: rowHeight, scale: scale), 20 * scale,
                             "First-row ink must be visible at the top, not flipped or clipped")
        XCTAssertGreaterThan(try whitePixels(result, top: lastRowTop, height: rowHeight, scale: scale), 20 * scale,
                             "The complete last row must remain visible")
        return result
    }

    private func whitePixels(_ image: NSBitmapImageRep, top: CGFloat, height: CGFloat, scale: Int) throws -> Int {
        var count = 0
        for y in Int(top * CGFloat(scale))..<Int((top + height) * CGFloat(scale)) {
            for x in 0..<(120 * scale) {
                let value = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                if min(value.redComponent, value.greenComponent, value.blueComponent) > 0.9,
                   value.alphaComponent > 0.9 { count += 1 }
            }
        }
        return count
    }

    private func color(_ image: NSBitmapImageRep, x: Int, y: Int, scale: Int) throws -> NSColor {
        try XCTUnwrap(image.colorAt(x: x * scale, y: y * scale)?.usingColorSpace(.sRGB))
    }
}
