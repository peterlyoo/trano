import AppKit
import CryptoKit
import ImageIO
import SwiftUI
import TerminalCore
import UniformTypeIdentifiers

enum BackgroundImageStore {
    private static let cache: NSCache<NSString, NSImage> = {
        let result = NSCache<NSString, NSImage>()
        result.countLimit = 4; result.totalCostLimit = 24 * 1024 * 1024
        return result
    }()

    private static func thumbnail(_ url: URL) throws -> CGImage {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let bytes = values.fileSize, bytes > 0, bytes <= 20 * 1024 * 1024 else {
            throw TerminalError.invalid("Choose a local image smaller than 20 MiB.")
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              width.doubleValue * height.doubleValue <= 32_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                                                        kCGImageSourceThumbnailMaxPixelSize: 1600,
                                                                        kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw TerminalError.invalid("Choose a supported image with at most 32 megapixels.")
        }
        return image
    }

    static func importImage(from source: URL, root: URL) throws -> String {
        let image = try thumbnail(source)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw TerminalError.runtime("Cannot prepare the background image.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length <= 12 * 1024 * 1024 else { throw TerminalError.invalid("The background image is too large.") }
        let bytes = data as Data
        let directory = try ManagedDirectory.ensure(root, component: "backgrounds")
        let name = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() + ".png"
        let target = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: target.path) { try TerminalRuntime.atomicWrite(bytes, to: target) }
        return target.path
    }

    static func load(path: String) -> NSImage? {
        if let value = cache.object(forKey: path as NSString) { return value }
        guard let bitmap = try? thumbnail(URL(fileURLWithPath: path)) else { return nil }
        let image = NSImage(cgImage: bitmap, size: NSSize(width: bitmap.width, height: bitmap.height))
        cache.setObject(image, forKey: path as NSString, cost: bitmap.bytesPerRow * bitmap.height)
        return image
    }
}

struct TerminalBackgroundView: View {
    let settings: TerminalSettings
    @State private var image: NSImage?

    var body: some View {
        Group {
            if settings.appearance.backgroundImagePath != nil {
                GeometryReader { geometry in
                    ZStack {
                        Color(NSColor(hex: settings.background)).opacity(settings.appearance.opacity)
                        if let image {
                            Image(nsImage: image).resizable().scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                                .opacity(settings.appearance.backgroundImageOpacity * settings.appearance.opacity)
                        }
                    }
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
            .task(id: settings.appearance.backgroundImagePath) {
                image = nil
                guard let path = settings.appearance.backgroundImagePath else { return }
                let loaded = await Task.detached(priority: .utility) { BackgroundImageStore.load(path: path) }.value
                guard !Task.isCancelled else { return }
                image = loaded
            }
    }
}
