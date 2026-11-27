#if os(macOS)
import AppKit
import XCTest
@testable import SwiftTerm

@MainActor
final class TerminalColorCoverageTests: XCTestCase {
    // Implements: U02, FR-SET-75
    func testRedTextRetainsTheSameGlyphCoverageAsWhiteOnTransparentBackgrounds() throws {
        _ = NSApplication.shared
        var measurements: [[String: Any]] = []
        for fontName in ["Menlo-Regular", "MesloLGSNFM-Regular"] {
            guard let font = NSFont(name: fontName, size: 14) else { continue }
            for scale in [1, 2] {
                for smoothing in [false, true] {
                    let white = try render(font: font, scale: scale, smoothing: smoothing, red: false)
                    let red = try render(font: font, scale: scale, smoothing: smoothing, red: true)
                    let whiteAlpha = stride(from: 3, to: white.count, by: 4).reduce(0) { $0 + Int(white[$1]) }
                    let redAlpha = stride(from: 3, to: red.count, by: 4).reduce(0) { $0 + Int(red[$1]) }
                    let whiteSolid = stride(from: 3, to: white.count, by: 4).filter { white[$0] > 250 }.count
                    let redSolid = stride(from: 3, to: red.count, by: 4).filter { red[$0] > 250 }.count
                    let colorError = stride(from: 0, to: red.count, by: 4).filter { red[$0 + 3] > 64 }.reduce(0.0) { error, offset in
                        let alpha = Double(red[offset + 3])
                        return max(error, abs(Double(red[offset]) / alpha - 229.0 / 255),
                                   abs(Double(red[offset + 1]) / alpha - 46.0 / 255),
                                   abs(Double(red[offset + 2]) / alpha - 46.0 / 255))
                    }
                    measurements.append(["font": fontName, "scale": scale, "smoothing": smoothing,
                        "whiteAlpha": whiteAlpha, "redAlpha": redAlpha,
                        "whiteSolid": whiteSolid, "redSolid": redSolid, "maxColorError": colorError])
                    XCTAssertGreaterThan(whiteAlpha, 1000)
                    XCTAssertLessThan(colorError, 0.02, "Coverage correction must retain the requested red RGB")
                    XCTAssertEqual(Double(redAlpha) / Double(whiteAlpha), 1, accuracy: 0.02,
                                   "Changing ink color must not erode glyph coverage: \(fontName), \(scale)x, smoothing=\(smoothing)")
                }
            }
        }
        if let directory = ProcessInfo.processInfo.environment["TRANO_RENDER_CAPTURE_DIR"] {
            try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("color-coverage.json"))
        }
    }

    private func render(font: NSFont, scale: Int, smoothing: Bool, red: Bool) throws -> [UInt8] {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 64), font: font,
                                options: TerminalOptions(cols: 36, rows: 3, scrollback: 0))
        view.frameDriver.invalidate()
        view.metalScaleFactorOverride = CGFloat(scale)
        view.nativeBackgroundColor = NSColor(srgbRed: 1 / 255, green: 20 / 255, blue: 35 / 255, alpha: 0.462)
        view.nativeForegroundColor = .white
        view.fontSmoothing = smoothing
        view.feed(text: "\u{1b}[?25l" + (red ? "\u{1b}[38;2;229;46;46m" : "\u{1b}[38;2;255;255;255m") + "Error Aa 0123 한글")
        view.frameTick()
        let width = 320 * scale, height = 64 * scale
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            defer { NSGraphicsContext.restoreGraphicsState() }
            view.drawTerminalContents(dirtyRect: view.bounds, context: context, bufferOffset: 0)
            if let directory = ProcessInfo.processInfo.environment["TRANO_RENDER_CAPTURE_DIR"] {
                let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                    URL(fileURLWithPath: directory).appendingPathComponent("\(font.fontName)-\(scale)x-\(smoothing)-\(red ? "red" : "white").png"))
            }
        }
        return bytes
    }
}
#endif
