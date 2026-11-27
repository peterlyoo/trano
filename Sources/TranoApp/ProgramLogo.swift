import AppKit
import ImageIO
import SwiftUI
import TerminalCore

@MainActor enum ProgramArtwork {
    static let thumbnailPixelLimit = 64
    static let resourceBundleName = "Trano_TranoApp.bundle"
    private static var images: [TerminalProgram: NSImage] = [:]
    private static var attempted: Set<TerminalProgram> = []
    private static let resourceBundle: Bundle? = {
        // Installed apps must not fall back to a development build's absolute resource path.
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let url = Bundle.main.resourceURL?.appendingPathComponent(resourceBundleName) else { return nil }
            return Bundle(url: url)
        }
        return Bundle.module
    }()

    static func image(for program: TerminalProgram) -> NSImage? {
        let name: String
        switch program {
        case .zsh: name = "zsh"
        case .k9s: name = "k9s"
        case .kubernetesExec: name = "kubernetes"
        case .shell, .claude, .codex: return nil
        }
        guard attempted.insert(program).inserted else { return images[program] }
        guard let bundle = resourceBundle,
              let url = bundle.url(forResource: name, withExtension: "png") ?? bundle.url(forResource: name, withExtension: "png", subdirectory: "ProgramIcons"),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: thumbnailPixelLimit
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: thumbnail, size: NSSize(width: CGFloat(thumbnail.width), height: CGFloat(thumbnail.height)))
        images[program] = image
        return image
    }
}

struct ProgramLogo: View {
    let program: TerminalProgram
    var tint: Color? = nil
    var monochrome = false

    var body: some View {
        Group {
            switch program {
            case .shell, .zsh: AgentLogo(agent: .shell, tint: tint)
            case .claude: AgentLogo(agent: .claude, tint: tint)
            case .codex: AgentLogo(agent: .codex, tint: tint)
            case .k9s, .kubernetesExec:
                if let image = ProgramArtwork.image(for: program) {
                    if monochrome {
                        Image(nsImage: image).renderingMode(.template).resizable().interpolation(.high).scaledToFit().foregroundStyle(tint ?? .primary)
                    } else {
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    }
                } else {
                    Image(systemName: "terminal").foregroundStyle(tint ?? .primary)
                }
            }
        }.frame(width: 14, height: 14)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(program.displayName)
    }
}
