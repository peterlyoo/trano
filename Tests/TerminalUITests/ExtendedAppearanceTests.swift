import AppKit
import ImageIO
import XCTest
import TerminalCore
@testable import TranoApp

final class ExtendedAppearanceTests: XCTestCase {
    // Implements: U05, U06
    @MainActor func testLineSpacingAndFallbackReachRenderer() throws {
        _ = NSApplication.shared
        let view = TranoView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        var settings = TerminalSettings()
        settings.appearance.lineSpacing = 1.45
        settings.appearance.fallbackFontName = "AppleSDGothicNeo-Regular"
        view.configure(settings)
        XCTAssertEqual(view.lineSpacing, 1.45, accuracy: 0.001)
        let cascade = try XCTUnwrap(view.font.fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor])
        XCTAssertEqual(cascade.first?.postscriptName, settings.appearance.fallbackFontName)
    }

    // Implements: U05
    func testImageImportDownsamplesAndRejectsNonImages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trano-appearance-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2200, pixelsHigh: 1200, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: source)
        let path = try BackgroundImageStore.importImage(from: source, root: directory)
        XCTAssertTrue(path.hasPrefix(directory.appendingPathComponent("backgrounds").path + "/"))
        let image = try XCTUnwrap(BackgroundImageStore.load(path: path))
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 1600)
        let file = directory.appendingPathComponent("text.png")
        try Data("not an image".utf8).write(to: file)
        XCTAssertThrowsError(try BackgroundImageStore.importImage(from: file, root: directory))
    }
}
