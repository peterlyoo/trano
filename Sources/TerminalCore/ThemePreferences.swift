import Foundation
import Darwin

public enum ThemeMode: String, Codable, CaseIterable { case light, dark }

public struct ThemePalette: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var background: String
    public var foreground: String
    public var cursor: String
    public var cursorText: String?
    public var selection: String
    public var selectionForeground: String?
    public var ansiColors: [String]
    public var indexedColors: [Int: String]

    public init(id: String = UUID().uuidString.lowercased(), name: String,
                background: String = "#0B0B0C", foreground: String = "#ECECEE",
                cursor: String = "#85D7C1", cursorText: String? = nil,
                selection: String = "#35594F", selectionForeground: String? = nil,
                ansiColors: [String] = AppearancePreferences().ansiColors, indexedColors: [Int: String] = [:]) {
        self.id = id; self.name = name; self.background = background; self.foreground = foreground
        self.cursor = cursor; self.cursorText = cursorText; self.selection = selection
        self.selectionForeground = selectionForeground; self.ansiColors = ansiColors; self.indexedColors = indexedColors
    }

    public func validate(custom: Bool = true) throws {
        let colors = [background, foreground, cursor, selection] + [cursorText, selectionForeground].compactMap { $0 }
        guard (!custom || UUID(uuidString: id) != nil), !id.isEmpty, id.utf8.count <= 80,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80, name.utf8.count <= 2048,
              !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.value == 0x2028 || $0.value == 0x2029 || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }),
              colors.allSatisfy(AppearancePreferences.isHexColor), ansiColors.count == 16,
              ansiColors.allSatisfy(AppearancePreferences.isHexColor), indexedColors.count <= 240,
              indexedColors.allSatisfy({ (16...255).contains($0.key) && AppearancePreferences.isHexColor($0.value) }) else {
            throw TerminalError.invalid("Choose a valid theme name, 16 ANSI colors and RGB palette entries 16–255.")
        }
    }

    public mutating func merge(_ draft: ThemePalette, from baseline: ThemePalette) {
        if draft.name != baseline.name { name = draft.name }
        if draft.background != baseline.background { background = draft.background }
        if draft.foreground != baseline.foreground { foreground = draft.foreground }
        if draft.cursor != baseline.cursor { cursor = draft.cursor }
        if draft.cursorText != baseline.cursorText { cursorText = draft.cursorText }
        if draft.selection != baseline.selection { selection = draft.selection }
        if draft.selectionForeground != baseline.selectionForeground { selectionForeground = draft.selectionForeground }
        if ansiColors.count == 16, draft.ansiColors.count == 16, baseline.ansiColors.count == 16 {
            for index in 0..<16 where draft.ansiColors[index] != baseline.ansiColors[index] { ansiColors[index] = draft.ansiColors[index] }
        }
        for index in Set(draft.indexedColors.keys).union(baseline.indexedColors.keys)
        where draft.indexedColors[index] != baseline.indexedColors[index] { indexedColors[index] = draft.indexedColors[index] }
    }
}

public struct ThemeApplication: Equatable {
    public var settings: TerminalSettings
    public var useExtendedPalette: Bool
    public var indexedColors: [Int: String]
    public var cursorText: String?
    public var selectionForeground: String?
    public func paletteOSC() -> String {
        guard useExtendedPalette else { return "" }
        let entries = indexedColors.keys.sorted().compactMap { index -> String? in
            guard (16...255).contains(index), let color = indexedColors[index], AppearancePreferences.isHexColor(color) else { return nil }
            return "\(index);\(color)"
        }
        return entries.isEmpty ? "" : "\u{1b}]4;" + entries.joined(separator: ";") + "\u{1b}\\"
    }
}

public struct ThemePreferences: Codable, Equatable {
    public static let currentPaletteID = "current"
    public static let defaultLightPaletteID = "trano-light"
    public var schemaVersion = 1
    public var lightThemeID = Self.defaultLightPaletteID
    public var darkThemeID = Self.currentPaletteID
    public var lightExtendedPalette = false
    public var darkExtendedPalette = false
    public var customThemes: [ThemePalette] = []
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, lightThemeID, darkThemeID, lightExtendedPalette, darkExtendedPalette, customThemes
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        lightThemeID = try values.decodeIfPresent(String.self, forKey: .lightThemeID) ?? Self.defaultLightPaletteID
        darkThemeID = try values.decodeIfPresent(String.self, forKey: .darkThemeID) ?? Self.currentPaletteID
        lightExtendedPalette = try values.decodeIfPresent(Bool.self, forKey: .lightExtendedPalette) ?? false
        darkExtendedPalette = try values.decodeIfPresent(Bool.self, forKey: .darkExtendedPalette) ?? false
        customThemes = try values.decodeIfPresent([ThemePalette].self, forKey: .customThemes) ?? []
        try validate()
    }
    public static var builtIns: [ThemePalette] {
        TerminalTheme.all.map { ThemePalette(id: $0.id, name: $0.title, background: $0.background,
                                             foreground: $0.appearance.foreground, cursor: $0.appearance.cursor,
                                             selection: $0.appearance.selection, ansiColors: $0.appearance.ansiColors) } + [
            ThemePalette(id: defaultLightPaletteID, name: "Trano Light", background: "#F7F8FA", foreground: "#202127",
                         cursor: "#256C56", selection: "#D7E9E1", ansiColors: [
                            "#202127", "#C13C37", "#287D3C", "#8B6508", "#2C65B7", "#944C9E", "#007D86", "#D6D6DC",
                            "#737780", "#D64843", "#309E4D", "#AC800F", "#417DD6", "#B663C1", "#008F9A", "#FFFFFF"
                         ])
        ]
    }
    public func validate() throws {
        let ids = Set(Self.builtIns.map(\.id) + [Self.currentPaletteID] + customThemes.map(\.id))
        guard schemaVersion == 1, customThemes.count <= 64,
              Set(customThemes.map(\.id)).count == customThemes.count,
              ids.contains(lightThemeID), ids.contains(darkThemeID) else { throw TerminalError.invalid("Invalid theme preferences.") }
        for palette in customThemes { try palette.validate() }
    }
    public func palette(id: String, legacy: TerminalSettings = TerminalSettings()) -> ThemePalette? {
        if id == Self.currentPaletteID {
            return ThemePalette(id: id, name: "Current Appearance", background: legacy.background, foreground: legacy.appearance.foreground,
                                cursor: legacy.appearance.cursor, selection: legacy.appearance.selection, ansiColors: legacy.appearance.ansiColors)
        }
        return customThemes.first { $0.id == id } ?? Self.builtIns.first { $0.id == id }
    }
    public func application(for mode: ThemeMode, legacy: TerminalSettings, profileAssigned: Bool = false) -> ThemeApplication {
        let extended = mode == .light ? lightExtendedPalette : darkExtendedPalette
        guard !profileAssigned, let palette = palette(id: mode == .light ? lightThemeID : darkThemeID, legacy: legacy),
              (try? palette.validate(custom: false)) != nil else {
            return ThemeApplication(settings: legacy, useExtendedPalette: extended, indexedColors: [:], cursorText: nil, selectionForeground: nil)
        }
        var settings = legacy
        settings.background = palette.background
        settings.appearance.foreground = palette.foreground; settings.appearance.cursor = palette.cursor
        settings.appearance.selection = palette.selection; settings.appearance.ansiColors = palette.ansiColors
        return ThemeApplication(settings: settings, useExtendedPalette: extended, indexedColors: extended ? palette.indexedColors : [:],
                                cursorText: palette.cursorText, selectionForeground: palette.selectionForeground)
    }
    public mutating func select(_ id: String, for mode: ThemeMode) throws {
        guard palette(id: id) != nil else { throw TerminalError.invalid("Choose an existing theme.") }
        if mode == .light { lightThemeID = id } else { darkThemeID = id }
    }
    @discardableResult public mutating func duplicate(_ id: String, name: String? = nil,
                                                     legacy: TerminalSettings = TerminalSettings()) throws -> String {
        guard var copy = palette(id: id, legacy: legacy) else { throw TerminalError.invalid("Choose an existing theme.") }
        copy.id = UUID().uuidString.lowercased(); copy.name = name ?? uniqueName(copy.name)
        try save(copy)
        return copy.id
    }
    public mutating func save(_ palette: ThemePalette) throws {
        try palette.validate()
        var result = self
        if let index = result.customThemes.firstIndex(where: { $0.id == palette.id }) { result.customThemes[index] = palette }
        else { result.customThemes.append(palette) }
        try result.validate()
        self = result
    }
    public mutating func remove(_ id: String) throws {
        guard customThemes.contains(where: { $0.id == id }) else { throw TerminalError.invalid("Built-in themes cannot be removed.") }
        customThemes.removeAll { $0.id == id }
        if lightThemeID == id { lightThemeID = Self.defaultLightPaletteID }
        if darkThemeID == id { darkThemeID = Self.currentPaletteID }
    }
    @discardableResult public mutating func importTheme(data: Data, filename: String, format: ThemeImportFormat? = nil,
                                                       for mode: ThemeMode) throws -> String {
        var palette = try ThemeImport.parse(data: data, filename: filename, format: format)
        palette.name = uniqueName(palette.name)
        var result = self
        try result.save(palette); try result.select(palette.id, for: mode)
        self = result
        return palette.id
    }
    public mutating func merge(_ draft: ThemePreferences, from baseline: ThemePreferences) throws {
        try draft.validate(); try baseline.validate(); try validate()
        var result = self
        if draft.lightThemeID != baseline.lightThemeID { result.lightThemeID = draft.lightThemeID }
        if draft.darkThemeID != baseline.darkThemeID { result.darkThemeID = draft.darkThemeID }
        if draft.lightExtendedPalette != baseline.lightExtendedPalette { result.lightExtendedPalette = draft.lightExtendedPalette }
        if draft.darkExtendedPalette != baseline.darkExtendedPalette { result.darkExtendedPalette = draft.darkExtendedPalette }
        let old = Dictionary(uniqueKeysWithValues: baseline.customThemes.map { ($0.id, $0) })
        let edited = Dictionary(uniqueKeysWithValues: draft.customThemes.map { ($0.id, $0) })
        result.customThemes.removeAll { old[$0.id] != nil && edited[$0.id] == nil }
        for palette in draft.customThemes {
            guard palette != old[palette.id] else { continue }
            if let index = result.customThemes.firstIndex(where: { $0.id == palette.id }), let original = old[palette.id] {
                result.customThemes[index].merge(palette, from: original)
            } else if let index = result.customThemes.firstIndex(where: { $0.id == palette.id }) {
                guard result.customThemes[index] == palette else { throw TerminalError.invalid("A theme with this identifier already exists.") }
            } else { result.customThemes.append(palette) }
        }
        if result.palette(id: result.lightThemeID) == nil { result.lightThemeID = Self.defaultLightPaletteID }
        if result.palette(id: result.darkThemeID) == nil { result.darkThemeID = Self.currentPaletteID }
        try result.validate()
        self = result
    }
    private func uniqueName(_ name: String) -> String {
        let existing = Set(customThemes.map(\.name) + Self.builtIns.map(\.name))
        guard existing.contains(name) else { return name }
        for index in 2...66 {
            let suffix = " (\(index))"
            let proposed = String(name.prefix(80 - suffix.count)) + suffix
            if !existing.contains(proposed) { return proposed }
        }
        return String(name.prefix(65)) + " " + UUID().uuidString.prefix(8)
    }
}

public struct ThemePreferencesStore {
    public let root: URL
    public init(root: URL) { self.root = root }
    private let maximumBytes = 2_097_152
    public func load() throws -> ThemePreferences {
        try validateRoot()
        let path = root.appendingPathComponent("theme-preferences.json").path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0, errno == ENOENT { return ThemePreferences() }
        guard fd >= 0 else { throw TerminalError.invalid("Cannot open private theme preferences.") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o077 == 0, info.st_size >= 0, info.st_size <= maximumBytes else {
            throw TerminalError.invalid("Theme preferences must be a private owned regular file of at most 2 MiB.")
        }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = read(fd, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw TerminalError.runtime("Cannot read theme preferences.") }
            if count == 0 { break }
            guard data.count + count <= maximumBytes else { throw TerminalError.invalid("Theme preferences exceed 2 MiB.") }
            data.append(contentsOf: bytes.prefix(count))
        }
        return try JSONDecoder().decode(ThemePreferences.self, from: data)
    }
    @discardableResult public func save(_ draft: ThemePreferences, baseline: ThemePreferences? = nil) throws -> ThemePreferences {
        try draft.validate()
        var current = try load()
        if let baseline { try current.merge(draft, from: baseline) } else { current = draft }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(current)
        guard data.count <= maximumBytes else { throw TerminalError.invalid("Theme preferences exceed 2 MiB.") }
        try TerminalRuntime.atomicWrite(data, to: root.appendingPathComponent("theme-preferences.json"))
        return current
    }
    private func validateRoot() throws {
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw TerminalError.invalid("Theme preference directory must be private and owned by the current user.")
        }
    }
}

extension TerminalRuntime {
    public func themePreferences() throws -> ThemePreferences { try transaction { try ThemePreferencesStore(root: root).load() } }
    @discardableResult public func saveThemePreferences(_ draft: ThemePreferences, baseline: ThemePreferences? = nil) throws -> ThemePreferences {
        try transaction { try ThemePreferencesStore(root: root).save(draft, baseline: baseline) }
    }
}
