import AppKit
import SwiftTerm
import XCTest
import TerminalCore
@testable import TranoApp

final class TerminalTextClarityTests: XCTestCase {
    // Implements: U02, U05, U06
    @MainActor func testConfigurationKeepsCustomFontAndInputWhileUsingThinStrokes() async throws {
        _ = NSApplication.shared
        let view = TranoView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        var settings = TerminalSettings()
        settings.fontName = "Monaco"
        settings.fontSize = 17
        view.configure(settings)
        XCTAssertFalse(view.fontSmoothing)
        XCTAssertEqual(view.font.fontName, "Monaco")
        XCTAssertEqual(view.font.pointSize, 17)
        let frame = view.frame
        let content = try XCTUnwrap(view.terminalContentSnapshot(region: .viewport))
        view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        settings.background = "#111113"
        view.configure(settings)
        XCTAssertFalse(view.fontSmoothing)
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.frame, frame)
        XCTAssertEqual(view.terminalContentSnapshot(region: .viewport)?.inputState.dimensions, content.inputState.dimensions)
        view.unmarkText()
        view.feed(text: "\u{1b}[2J\u{1b}[H한글 Aa \u{1b}[38;2;17;93;201mRGB\u{1b}[0m")
        let deadline = Date().addingTimeInterval(2)
        while view.terminalContentSnapshot(region: .viewport)?.rows.first?.text.hasPrefix("한글 Aa RGB") != true, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let row = try XCTUnwrap(view.terminalContentSnapshot(region: .viewport)?.rows.first)
        XCTAssertTrue(row.text.hasPrefix("한글 Aa RGB"))
        XCTAssertTrue(row.cells.contains { $0.attribute.fg == .trueColor(red: 17, green: 93, blue: 201) })
    }

    // Implements: U02, U05, U06
    @MainActor func testNativeRendererKeepsAntialiasingAtOneAndTwoTimesResolution() async throws {
        _ = NSApplication.shared
        var measurements: [[String: Any]] = []
        for scale in [1, 2] {
            for smoothing in [true, false] {
                let view = TranoView(frame: NSRect(x: 0, y: 0, width: 480, height: 100))
                var settings = TerminalSettings()
                settings.background = "#000000"
                settings.appearance.foreground = "#FFFFFF"
                view.configure(settings)
                let configuredRGB = try rgb(view.nativeForegroundColor)
                XCTAssertEqual(configuredRGB, [1, 1, 1])
                view.fontSmoothing = smoothing
                view.suspendsRenderingWhenNotVisible = false
                let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = view
                window.setFrameOrigin(NSPoint(x: -14000, y: -14000))
                window.orderFrontRegardless()
                defer { window.close() }
                let attachedRGB = try rgb(view.nativeForegroundColor)
                let beforeFrames = view.diagnostics.frames
                view.feed(text: "\u{1b}[2J\u{1b}[HSharp Aa 0123 한글\r\n\u{1b}[31mRed\u{1b}[38;5;202m Orange\u{1b}[38;2;17;93;201m Blue\u{1b}[0m\r\n\u{1b}[38;2;255;255;255mExplicit RGB white\u{1b}[0m")
                let deadline = Date().addingTimeInterval(2)
                while view.terminalContentSnapshot(region: .viewport)?.rows.first?.text.hasPrefix("Sharp Aa 0123 한글") != true, Date() < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                let firstRow = try XCTUnwrap(view.terminalContentSnapshot(region: .viewport)?.rows.first)
                XCTAssertTrue(firstRow.text.hasPrefix("Sharp Aa 0123 한글"))
                XCTAssertEqual(firstRow.cells.first?.attribute.fg, .defaultColor)
                XCTAssertFalse(firstRow.cells.first?.attribute.style.contains(.dim) ?? true)
                view.requestRedraw()
                while view.diagnostics.frames <= beforeFrames, Date() < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertGreaterThan(view.diagnostics.frames, beforeFrames)
                let frameRGB = try rgb(view.nativeForegroundColor)
                XCTAssertEqual(frameRGB, [1, 1, 1], "An asynchronous initialization callback must not replace the configured foreground")
                let stableColorFrames = view.diagnostics.frames
                view.requestRedraw()
                let stableDeadline = Date().addingTimeInterval(2)
                while view.diagnostics.frames <= stableColorFrames, Date() < stableDeadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertGreaterThan(view.diagnostics.frames, stableColorFrames)
                view.needsDisplay = true
                view.displayIfNeeded()
                let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 480 * scale,
                    pixelsHigh: 100 * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                bitmap.size = view.bounds.size
                view.cacheDisplay(in: view.bounds, to: bitmap)
                var antialiased = 0
                var foreground = 0
                for y in 0..<min(24 * scale, bitmap.pixelsHigh) {
                    for x in 0..<min(180 * scale, bitmap.pixelsWide) {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                        let gray = color.redComponent
                        let alpha = color.alphaComponent
                        if abs(gray - color.greenComponent) < 0.01, abs(gray - color.blueComponent) < 0.01 {
                            if alpha > 0.02, alpha < 0.98 { antialiased += 1 }
                            if gray >= 0.98, alpha >= 0.98 { foreground += 1 }
                        }
                    }
                }
                XCTAssertGreaterThan(antialiased, 30, "Text antialiasing must remain enabled")
                XCTAssertGreaterThan(foreground, 10, "A nonempty image alone does not establish rendered text")
                XCTAssertEqual(view.font.fontName, "Menlo-Regular")
                XCTAssertEqual(view.font.pointSize, 14)
                measurements.append(["scale": scale, "font_smoothing": smoothing,
                    "antialiased_pixels": antialiased, "foreground_pixels": foreground,
                    "width_pixels": bitmap.pixelsWide, "height_pixels": bitmap.pixelsHigh,
                    "configured_foreground_rgb": configuredRGB, "attached_foreground_rgb": attachedRGB,
                    "first_frame_foreground_rgb": frameRGB,
                    "native_window_backing_scale": window.backingScaleFactor])
                if let prefix = ProcessInfo.processInfo.environment["TRANO_TEXT_CLARITY_PREVIEW"] {
                    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: prefix + "-\(scale)x-\(smoothing ? "smooth" : "thin").png"))
                }
            }
        }
        if let prefix = ProcessInfo.processInfo.environment["TRANO_TEXT_CLARITY_PREVIEW"] {
            let data = try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: prefix + "-metrics.json"))
        }
    }

    // Implements: U02, U05, U06
    @MainActor func testFontSmoothingThickensRegularRunsButLeavesBoldRunsAtNativeWeight() async throws {
        _ = NSApplication.shared
        var ink: [Bool: [Double]] = [:]
        for smoothing in [true, false] {
            let view = TranoView(frame: NSRect(x: 0, y: 0, width: 480, height: 100))
            var settings = TerminalSettings()
            settings.background = "#011423"
            settings.appearance.foreground = "#CBE0F0"
            view.configure(settings)
            view.fontSmoothing = smoothing
            view.suspendsRenderingWhenNotVisible = false
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.setFrameOrigin(NSPoint(x: -14000, y: -14000))
            window.orderFrontRegardless()
            defer { window.close() }
            let beforeFrames = view.diagnostics.frames
            view.feed(text: "\u{1b}[2J\u{1b}[H\u{1b}[38;2;229;46;46masdfqwer\u{1b}[0m\r\n\u{1b}[1;38;2;229;46;46masdfqwer\u{1b}[0m")
            let deadline = Date().addingTimeInterval(2)
            while view.terminalContentSnapshot(region: .viewport)?.rows.dropFirst().first?.text.hasPrefix("asdfqwer") != true, Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            view.requestRedraw()
            while view.diagnostics.frames <= beforeFrames, Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            view.needsDisplay = true
            view.displayIfNeeded()
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 960,
                pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = view.bounds.size
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.bitmapData)
            var bands: [Double] = []
            var current: Double?
            for y in 0..<bitmap.pixelsHigh {
                var row = 0.0
                for x in 0..<bitmap.pixelsWide { row += Double(data[y * bitmap.bytesPerRow + x * 4]) / 229 }
                if row > 0.5 { current = (current ?? 0) + row } else if let band = current { bands.append(band); current = nil }
            }
            XCTAssertEqual(bands.count, 2, "Expected one regular and one bold row of red ink")
            ink[smoothing] = bands
        }
        let smooth = try XCTUnwrap(ink[true]), thin = try XCTUnwrap(ink[false])
        guard smooth.count == 2, thin.count == 2 else { return }
        XCTAssertGreaterThan(smooth[0], thin[0] * 1.15, "Smoothing must still thicken regular runs")
        XCTAssertEqual(smooth[1], thin[1], accuracy: thin[1] * 0.01, "Smoothing must not dilate bold runs")
    }

    @MainActor private func rgb(_ color: NSColor) throws -> [Double] {
        let converted = try XCTUnwrap(color.usingColorSpace(.sRGB))
        return [Double(converted.redComponent), Double(converted.greenComponent), Double(converted.blueComponent)]
    }
}
