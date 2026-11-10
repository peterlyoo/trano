import Foundation

public enum TerminalCursorStyle: String, Codable, CaseIterable { case block, beam, underline }

public struct AppearancePreferences: Codable, Equatable {
    public var foreground = "#ECECEE"
    public var cursor = "#85D7C1"
    public var selection = "#35594F"
    public var opacity = 1.0
    public var cursorStyle: TerminalCursorStyle = .block
    public var cursorBlink = false
    public var lineSpacing = 1.0
    public var fallbackFontName = "AppleSDGothicNeo-Regular"
    public var backgroundImagePath: String?
    public var backgroundImageOpacity = 0.18
    public var ansiColors = ["#242428", "#F07D82", "#91C994", "#E5C07B", "#8BAFE3", "#C7A0DA", "#82CFC6", "#D6D6DC", "#686872", "#FFA2A6", "#B1E5B2", "#F3D99C", "#AECBF2", "#E0BBEE", "#A7EAE1", "#F5F5F7"]
    public init() {}
    private enum CodingKeys: String, CodingKey { case foreground, cursor, selection, opacity, cursorStyle, cursorBlink, ansiColors, lineSpacing, fallbackFontName, backgroundImagePath, backgroundImageOpacity }
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        foreground = try box.decodeIfPresent(String.self, forKey: .foreground) ?? foreground
        cursor = try box.decodeIfPresent(String.self, forKey: .cursor) ?? cursor
        selection = try box.decodeIfPresent(String.self, forKey: .selection) ?? selection
        opacity = try box.decodeIfPresent(Double.self, forKey: .opacity) ?? opacity
        cursorStyle = try box.decodeIfPresent(TerminalCursorStyle.self, forKey: .cursorStyle) ?? cursorStyle
        cursorBlink = try box.decodeIfPresent(Bool.self, forKey: .cursorBlink) ?? cursorBlink
        lineSpacing = try box.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? lineSpacing
        fallbackFontName = try box.decodeIfPresent(String.self, forKey: .fallbackFontName) ?? fallbackFontName
        backgroundImagePath = try box.decodeIfPresent(String.self, forKey: .backgroundImagePath)
        backgroundImageOpacity = try box.decodeIfPresent(Double.self, forKey: .backgroundImageOpacity) ?? backgroundImageOpacity
        ansiColors = try box.decodeIfPresent([String].self, forKey: .ansiColors) ?? ansiColors
        try validate()
    }

    public func validate() throws {
        guard opacity.isFinite, (0.3...1).contains(opacity), ansiColors.count == 16,
              lineSpacing.isFinite, (1...2).contains(lineSpacing),
              backgroundImageOpacity.isFinite, (0...0.4).contains(backgroundImageOpacity),
              fallbackFontName.utf8.count <= 200, !fallbackFontName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              ([foreground, cursor, selection] + ansiColors).allSatisfy(Self.isHexColor) else {
            throw TerminalError.invalid("Use valid colors, 30–100% opacity, 1–2× line spacing, and 0–40% image intensity.")
        }
        if let path = backgroundImagePath {
            guard path.hasPrefix("/"), path.utf8.count <= 4096,
                  !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw TerminalError.invalid("Background images must use a local absolute path.")
            }
        }
    }

    public static func isHexColor(_ value: String) -> Bool {
        value.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil
    }
}

public struct TerminalTheme: Identifiable {
    public let id: String
    public let title: String
    public let background: String
    public let appearance: AppearancePreferences
    public static let all: [TerminalTheme] = {
        let black = AppearancePreferences()
        var graphite = black
        graphite.foreground = "#E4E4E7"; graphite.cursor = "#C5D7F2"; graphite.selection = "#42495A"
        var contrast = black
        contrast.foreground = "#FFFFFF"; contrast.cursor = "#FFFFFF"; contrast.selection = "#535353"
        return [.init(id: "black", title: "Trano Black", background: "#0B0B0C", appearance: black),
                .init(id: "graphite", title: "Graphite", background: "#202024", appearance: graphite),
                .init(id: "contrast", title: "High Contrast", background: "#000000", appearance: contrast)]
    }()
}
