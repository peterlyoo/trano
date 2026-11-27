import Foundation
import Darwin

public enum TerminalCharacterSpacingUnit: String, Codable, CaseIterable, Sendable { case pixels, percent }
public struct TerminalCharacterSpacing: Codable, Equatable, Sendable {
    public var value = 0.0
    public var unit: TerminalCharacterSpacingUnit = .pixels
    public init(value: Double = 0, unit: TerminalCharacterSpacingUnit = .pixels) { self.value = value; self.unit = unit }
}
public enum TerminalFontStylePolicy: String, Codable, CaseIterable, Sendable { case both, boldOnly, italicOnly, neither }
public enum TerminalBlinkSpeed: String, Codable, CaseIterable, Sendable { case off, slow, normal, fast, custom }
public enum TerminalOptionKey: String, Codable, CaseIterable, Sendable { case meta, specialCharacters }
public enum TerminalApplicationLinkPolicy: String, Codable, CaseIterable, Sendable { case ask, always, never }
public enum TerminalApplicationLinkDecision: Equatable, Sendable { case open, ask, deny }

public struct TerminalTrustedLink: Codable, Equatable, Sendable {
    public var scheme: String
    public var host: String?
    public var port: Int?
    public init(scheme: String, host: String? = nil, port: Int? = nil) { self.scheme = scheme; self.host = host; self.port = port }
}
public struct TerminalStartupCommand: Codable, Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public init(executable: String, arguments: [String] = []) { self.executable = executable; self.arguments = arguments }
}

public struct TerminalPreferences: Codable, Equatable, Sendable {
    public var fontName: String?
    public var fontSize: Double?
    public var fontStyle: String?
    public var fontWeight: Double?
    public var lineHeight: Double?
    public var characterSpacing = TerminalCharacterSpacing()
    public var ligatures = true
    public var fontStyles: TerminalFontStylePolicy = .both
    public var forceFontStyles = false
    public var fontSmoothing = false
    public var fallbackFonts: [String]?
    public var minimumContrastRatio = 1.0
    public var forceThemePaletteForText = false
    public var useDisplayP3 = false
    public var cursorBlinkSpeed: TerminalBlinkSpeed?
    public var cursorBlinkIntervalMS = 700.0
    public var cursorStyle: TerminalCursorStyle?
    public var forceCursorStyle = false
    public var showKeySequenceHints = true
    public var optionKey: TerminalOptionKey?
    public var smoothScrolling = false
    public var smoothResizing = true
    public var copyOnSelection = false
    public var animateCopy = false
    public var selectionForeground: String?
    public var selectionBackground: String?
    public var selectionCornerRadius = 0.0
    public var applicationLinks: TerminalApplicationLinkPolicy = .ask
    public var trustedLinks: [TerminalTrustedLink] = []
    public var showRecentPaths = true
    public var preferGeneratedTitles = false
    public var startupCommand: TerminalStartupCommand?
    public init() {}

    public func validate() throws {
        func bounded(_ value: Double, _ range: ClosedRange<Double>, _ label: String) throws {
            guard value.isFinite, range.contains(value) else { throw TerminalError.invalid("Invalid " + label) }
        }
        func font(_ value: String?) throws {
            guard let value else { return }
            guard !value.isEmpty, value.utf8.count <= 200,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw TerminalError.invalid("Invalid font name")
            }
        }
        try font(fontName); try font(fontStyle)
        if let fontSize { try bounded(fontSize, 3...256, "font size") }
        if let fontWeight { try bounded(fontWeight, -65536...65536, "font weight") }
        if let lineHeight { try bounded(lineHeight, 0.5...3, "line height") }
        try bounded(characterSpacing.value, characterSpacing.unit == .pixels ? -32...64 : -90...500, "character spacing")
        try bounded(minimumContrastRatio, 1...21, "contrast ratio")
        try bounded(cursorBlinkIntervalMS, 50...10000, "cursor blink interval")
        try bounded(selectionCornerRadius, 0...32, "selection corner radius")
        for color in [selectionForeground, selectionBackground].compactMap({ $0 }) {
            guard color.utf8.count == 7, color.first == "#", color.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
                throw TerminalError.invalid("Selection colors must use #RRGGBB")
            }
        }
        if let fallbackFonts {
            guard fallbackFonts.count <= 16, Set(fallbackFonts).count == fallbackFonts.count else { throw TerminalError.invalid("Use distinct fallback fonts") }
            for fallback in fallbackFonts { try font(fallback) }
        }
        guard trustedLinks.count <= 128 else { throw TerminalError.invalid("Too many trusted application links") }
        for rule in trustedLinks {
            guard Self.validScheme(rule.scheme), !Self.deniedSchemes.contains(rule.scheme.lowercased()),
                  rule.port.map({ (1...65535).contains($0) }) ?? true else { throw TerminalError.invalid("Invalid trusted link") }
            if let host = rule.host {
                guard !host.isEmpty, host.utf8.count <= 253,
                      !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) || "/@?#*\\".unicodeScalars.contains($0) }),
                      URLComponents(string: rule.scheme + "://" + host)?.host?.lowercased() == host.lowercased() else {
                    throw TerminalError.invalid("Trusted hosts must be exact host names without credentials or wildcards")
                }
            }
        }
        if let startupCommand {
            guard startupCommand.executable.hasPrefix("/"), startupCommand.executable.utf8.count <= 4096,
                  !startupCommand.executable.utf8.contains(0), startupCommand.arguments.count <= 64,
                  startupCommand.arguments.allSatisfy({ $0.utf8.count <= 65536 && !$0.utf8.contains(0) }),
                  startupCommand.arguments.reduce(0, { $0 + $1.utf8.count }) <= 262144 else {
                throw TerminalError.invalid("Startup command requires an absolute executable and bounded arguments without NUL")
            }
        }
    }

    public func resolved(legacy: TerminalSettings, profileAssigned: Bool = false) -> ResolvedTerminalPreferences {
        var value = ResolvedTerminalPreferences()
        value.fontName = profileAssigned ? legacy.fontName : (fontName ?? legacy.fontName)
        value.fontSize = profileAssigned ? legacy.fontSize : (fontSize ?? legacy.fontSize)
        value.fontStyle = profileAssigned ? nil : fontStyle
        value.fontWeight = profileAssigned ? nil : fontWeight
        value.lineHeight = profileAssigned ? legacy.appearance.lineSpacing : (lineHeight ?? legacy.appearance.lineSpacing)
        let inheritedFallbacks = legacy.appearance.fallbackFontName.isEmpty ? [] : [legacy.appearance.fallbackFontName]
        value.fallbackFonts = profileAssigned ? inheritedFallbacks : (fallbackFonts ?? inheritedFallbacks)
        value.cursorStyle = profileAssigned ? legacy.appearance.cursorStyle : (cursorStyle ?? legacy.appearance.cursorStyle)
        switch profileAssigned ? nil : cursorBlinkSpeed {
        case nil: value.cursorBlinkInterval = legacy.appearance.cursorBlink ? 0.7 : nil
        case .off: value.cursorBlinkInterval = nil
        case .slow: value.cursorBlinkInterval = 1.2
        case .normal: value.cursorBlinkInterval = 0.7
        case .fast: value.cursorBlinkInterval = 0.35
        case .custom: value.cursorBlinkInterval = cursorBlinkIntervalMS / 1000
        }
        value.optionAsMeta = optionKey.map { $0 == .meta } ?? legacy.optionAsMeta ?? false
        value.selectionForeground = profileAssigned ? legacy.appearance.foreground : (selectionForeground ?? legacy.appearance.foreground)
        value.selectionBackground = profileAssigned ? legacy.appearance.selection : (selectionBackground ?? legacy.appearance.selection)
        value.characterSpacing = characterSpacing
        value.ligatures = ligatures
        value.fontStyles = fontStyles
        value.forceFontStyles = forceFontStyles
        value.fontSmoothing = fontSmoothing
        value.minimumContrastRatio = minimumContrastRatio
        value.forceThemePaletteForText = forceThemePaletteForText
        value.useDisplayP3 = useDisplayP3
        value.forceCursorStyle = forceCursorStyle
        value.showKeySequenceHints = showKeySequenceHints
        value.smoothScrolling = smoothScrolling
        value.smoothResizing = smoothResizing
        value.copyOnSelection = copyOnSelection
        value.animateCopy = animateCopy
        value.selectionCornerRadius = selectionCornerRadius
        value.showRecentPaths = showRecentPaths
        value.preferGeneratedTitles = preferGeneratedTitles
        return value
    }

    public mutating func merge(_ draft: TerminalPreferences, from baseline: TerminalPreferences) {
        if draft.fontName != baseline.fontName { fontName = draft.fontName }
        if draft.fontSize != baseline.fontSize { fontSize = draft.fontSize }
        if draft.fontStyle != baseline.fontStyle { fontStyle = draft.fontStyle }
        if draft.fontWeight != baseline.fontWeight { fontWeight = draft.fontWeight }
        if draft.lineHeight != baseline.lineHeight { lineHeight = draft.lineHeight }
        if draft.characterSpacing != baseline.characterSpacing { characterSpacing = draft.characterSpacing }
        if draft.ligatures != baseline.ligatures { ligatures = draft.ligatures }
        if draft.fontStyles != baseline.fontStyles { fontStyles = draft.fontStyles }
        if draft.forceFontStyles != baseline.forceFontStyles { forceFontStyles = draft.forceFontStyles }
        if draft.fontSmoothing != baseline.fontSmoothing { fontSmoothing = draft.fontSmoothing }
        if draft.fallbackFonts != baseline.fallbackFonts { fallbackFonts = draft.fallbackFonts }
        if draft.minimumContrastRatio != baseline.minimumContrastRatio { minimumContrastRatio = draft.minimumContrastRatio }
        if draft.forceThemePaletteForText != baseline.forceThemePaletteForText { forceThemePaletteForText = draft.forceThemePaletteForText }
        if draft.useDisplayP3 != baseline.useDisplayP3 { useDisplayP3 = draft.useDisplayP3 }
        if draft.cursorBlinkSpeed != baseline.cursorBlinkSpeed { cursorBlinkSpeed = draft.cursorBlinkSpeed }
        if draft.cursorBlinkIntervalMS != baseline.cursorBlinkIntervalMS { cursorBlinkIntervalMS = draft.cursorBlinkIntervalMS }
        if draft.cursorStyle != baseline.cursorStyle { cursorStyle = draft.cursorStyle }
        if draft.forceCursorStyle != baseline.forceCursorStyle { forceCursorStyle = draft.forceCursorStyle }
        if draft.showKeySequenceHints != baseline.showKeySequenceHints { showKeySequenceHints = draft.showKeySequenceHints }
        if draft.optionKey != baseline.optionKey { optionKey = draft.optionKey }
        if draft.smoothScrolling != baseline.smoothScrolling { smoothScrolling = draft.smoothScrolling }
        if draft.smoothResizing != baseline.smoothResizing { smoothResizing = draft.smoothResizing }
        if draft.copyOnSelection != baseline.copyOnSelection { copyOnSelection = draft.copyOnSelection }
        if draft.animateCopy != baseline.animateCopy { animateCopy = draft.animateCopy }
        if draft.selectionForeground != baseline.selectionForeground { selectionForeground = draft.selectionForeground }
        if draft.selectionBackground != baseline.selectionBackground { selectionBackground = draft.selectionBackground }
        if draft.selectionCornerRadius != baseline.selectionCornerRadius { selectionCornerRadius = draft.selectionCornerRadius }
        if draft.applicationLinks != baseline.applicationLinks { applicationLinks = draft.applicationLinks }
        if draft.trustedLinks != baseline.trustedLinks { trustedLinks = draft.trustedLinks }
        if draft.showRecentPaths != baseline.showRecentPaths { showRecentPaths = draft.showRecentPaths }
        if draft.preferGeneratedTitles != baseline.preferGeneratedTitles { preferGeneratedTitles = draft.preferGeneratedTitles }
        if draft.startupCommand != baseline.startupCommand { startupCommand = draft.startupCommand }
    }

    public func linkDecision(for url: URL) -> TerminalApplicationLinkDecision {
        guard let scheme = url.scheme?.lowercased(), Self.validScheme(scheme), !Self.deniedSchemes.contains(scheme) else { return .deny }
        if scheme == "http" || scheme == "https" { return url.host?.isEmpty == false ? .open : .deny }
        switch applicationLinks {
        case .never: return .deny
        case .always: return .open
        case .ask:
            return trustedLinks.contains { rule in
                rule.scheme.lowercased() == scheme && rule.host?.lowercased() == url.host?.lowercased() && rule.port == url.port
            } ? .open : .ask
        }
    }

    public func startup(defaultShell: String = "/bin/zsh", defaultArguments: [String] = ["-l"]) -> TerminalStartupCommand {
        startupCommand ?? TerminalStartupCommand(executable: defaultShell, arguments: defaultArguments)
    }

    private static let deniedSchemes: Set<String> = ["javascript", "data", "about", "blob", "vbscript"]
    private static func validScheme(_ value: String) -> Bool {
        value.utf8.count <= 32 && value.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*$", options: .regularExpression) != nil
    }

    private enum CodingKeys: String, CodingKey {
        case fontName, fontSize, fontStyle, fontWeight, lineHeight, characterSpacing, ligatures, fontStyles, forceFontStyles, fontSmoothing, fallbackFonts, minimumContrastRatio, forceThemePaletteForText, useDisplayP3, cursorBlinkSpeed, cursorBlinkIntervalMS, cursorStyle, forceCursorStyle, showKeySequenceHints, optionKey, smoothScrolling, smoothResizing, copyOnSelection, animateCopy, selectionForeground, selectionBackground, selectionCornerRadius, applicationLinks, trustedLinks, showRecentPaths, preferGeneratedTitles, startupCommand
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let box = try decoder.container(keyedBy: CodingKeys.self)
        fontName = try box.decodeIfPresent(String.self, forKey: .fontName)
        fontSize = try box.decodeIfPresent(Double.self, forKey: .fontSize)
        fontStyle = try box.decodeIfPresent(String.self, forKey: .fontStyle)
        fontWeight = try box.decodeIfPresent(Double.self, forKey: .fontWeight)
        lineHeight = try box.decodeIfPresent(Double.self, forKey: .lineHeight)
        characterSpacing = try box.decodeIfPresent(TerminalCharacterSpacing.self, forKey: .characterSpacing) ?? characterSpacing
        ligatures = try box.decodeIfPresent(Bool.self, forKey: .ligatures) ?? ligatures
        fontStyles = try box.decodeIfPresent(TerminalFontStylePolicy.self, forKey: .fontStyles) ?? fontStyles
        forceFontStyles = try box.decodeIfPresent(Bool.self, forKey: .forceFontStyles) ?? forceFontStyles
        fontSmoothing = try box.decodeIfPresent(Bool.self, forKey: .fontSmoothing) ?? fontSmoothing
        fallbackFonts = try box.decodeIfPresent([String].self, forKey: .fallbackFonts)
        minimumContrastRatio = try box.decodeIfPresent(Double.self, forKey: .minimumContrastRatio) ?? minimumContrastRatio
        forceThemePaletteForText = try box.decodeIfPresent(Bool.self, forKey: .forceThemePaletteForText) ?? forceThemePaletteForText
        useDisplayP3 = try box.decodeIfPresent(Bool.self, forKey: .useDisplayP3) ?? useDisplayP3
        cursorBlinkSpeed = try box.decodeIfPresent(TerminalBlinkSpeed.self, forKey: .cursorBlinkSpeed)
        cursorBlinkIntervalMS = try box.decodeIfPresent(Double.self, forKey: .cursorBlinkIntervalMS) ?? cursorBlinkIntervalMS
        cursorStyle = try box.decodeIfPresent(TerminalCursorStyle.self, forKey: .cursorStyle)
        forceCursorStyle = try box.decodeIfPresent(Bool.self, forKey: .forceCursorStyle) ?? forceCursorStyle
        showKeySequenceHints = try box.decodeIfPresent(Bool.self, forKey: .showKeySequenceHints) ?? showKeySequenceHints
        optionKey = try box.decodeIfPresent(TerminalOptionKey.self, forKey: .optionKey)
        smoothScrolling = try box.decodeIfPresent(Bool.self, forKey: .smoothScrolling) ?? smoothScrolling
        smoothResizing = try box.decodeIfPresent(Bool.self, forKey: .smoothResizing) ?? smoothResizing
        copyOnSelection = try box.decodeIfPresent(Bool.self, forKey: .copyOnSelection) ?? copyOnSelection
        animateCopy = try box.decodeIfPresent(Bool.self, forKey: .animateCopy) ?? animateCopy
        selectionForeground = try box.decodeIfPresent(String.self, forKey: .selectionForeground)
        selectionBackground = try box.decodeIfPresent(String.self, forKey: .selectionBackground)
        selectionCornerRadius = try box.decodeIfPresent(Double.self, forKey: .selectionCornerRadius) ?? selectionCornerRadius
        applicationLinks = try box.decodeIfPresent(TerminalApplicationLinkPolicy.self, forKey: .applicationLinks) ?? applicationLinks
        trustedLinks = try box.decodeIfPresent([TerminalTrustedLink].self, forKey: .trustedLinks) ?? trustedLinks
        showRecentPaths = try box.decodeIfPresent(Bool.self, forKey: .showRecentPaths) ?? showRecentPaths
        preferGeneratedTitles = try box.decodeIfPresent(Bool.self, forKey: .preferGeneratedTitles) ?? preferGeneratedTitles
        startupCommand = try box.decodeIfPresent(TerminalStartupCommand.self, forKey: .startupCommand)
    }
}

public struct ResolvedTerminalPreferences: Equatable, Sendable {
    public var fontName = "Menlo-Regular"
    public var fontSize = 14.0
    public var fontStyle: String?
    public var fontWeight: Double?
    public var lineHeight = 1.0
    public var characterSpacing = TerminalCharacterSpacing()
    public var ligatures = true
    public var fontStyles: TerminalFontStylePolicy = .both
    public var forceFontStyles = false
    public var fontSmoothing = false
    public var fallbackFonts = ["AppleSDGothicNeo-Regular"]
    public var minimumContrastRatio = 1.0
    public var forceThemePaletteForText = false
    public var useDisplayP3 = false
    public var cursorBlinkInterval: Double?
    public var cursorStyle: TerminalCursorStyle = .block
    public var forceCursorStyle = false
    public var showKeySequenceHints = true
    public var optionAsMeta = false
    public var smoothScrolling = false
    public var smoothResizing = true
    public var copyOnSelection = false
    public var animateCopy = false
    public var selectionForeground = "#ECECEE"
    public var selectionBackground = "#35594F"
    public var selectionCornerRadius = 0.0
    public var showRecentPaths = true
    public var preferGeneratedTitles = false
    public init() {}
}

public struct TerminalPreferenceStore {
    public let root: URL
    public init(root: URL) { self.root = root }
    public var url: URL { root.appendingPathComponent("terminal-preferences.json") }
    private struct Envelope: Codable {
        let schemaVersion: Int
        let preferences: TerminalPreferences
    }

    public func load() throws -> TerminalPreferences {
        try validateRoot()
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return TerminalPreferences() }
            throw TerminalError.invalid("Cannot read terminal preferences safely")
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_uid == getuid(),
              metadata.st_nlink == 1, metadata.st_mode & 0o077 == 0,
              metadata.st_size >= 0, metadata.st_size <= 1_048_576 else {
            throw TerminalError.invalid("Terminal preferences must be a private, owned regular file up to 1 MiB")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw TerminalError.invalid("Terminal preferences exceed 1 MiB") }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.schemaVersion == 1 else { throw TerminalError.invalid("Unsupported terminal preference schema") }
        try envelope.preferences.validate()
        return envelope.preferences
    }

    public func save(_ preferences: TerminalPreferences) throws {
        try preferences.validate()
        _ = try load()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(schemaVersion: 1, preferences: preferences))
        guard data.count <= 1_048_576 else { throw TerminalError.invalid("Terminal preferences exceed 1 MiB") }
        try TerminalRuntime.atomicWrite(data, to: url)
    }

    public func mergeAndSave(_ draft: TerminalPreferences, from baseline: TerminalPreferences) throws -> TerminalPreferences {
        var current = try load()
        current.merge(draft, from: baseline)
        try save(current)
        return current
    }

    private func validateRoot() throws {
        var metadata = stat()
        guard lstat(root.path, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), metadata.st_uid == getuid(),
              metadata.st_mode & 0o077 == 0 else {
            throw TerminalError.invalid("Terminal preference directory must be private and owned")
        }
    }
}

public struct TerminalRecentPath: Codable, Equatable, Sendable {
    public let path: String
    public let hostID: String?
    public let usedAt: Date
    public init(path: String, hostID: String? = nil, usedAt: Date) { self.path = path; self.hostID = hostID; self.usedAt = usedAt }
}
public struct TerminalPathHistory: Codable, Equatable, Sendable {
    public private(set) var entries: [TerminalRecentPath] = []
    public init() {}
    public mutating func record(_ path: String, hostID: String? = nil, at: Date) throws {
        guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.utf8.contains(0),
              at.timeIntervalSince1970.isFinite,
              hostID.map({ !$0.isEmpty && $0.utf8.count <= 200 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) ?? true else {
            throw TerminalError.invalid("Invalid recent path")
        }
        entries.removeAll { $0.hostID == hostID && $0.path.utf8.elementsEqual(path.utf8) }
        entries.insert(TerminalRecentPath(path: path, hostID: hostID, usedAt: at), at: 0)
        entries.sort { $0.usedAt > $1.usedAt }
        var counts: [String: Int] = [:]
        entries = entries.filter { entry in
            let key = entry.hostID ?? ""
            let count = counts[key, default: 0]
            counts[key] = count + 1
            return count < 20
        }
        entries = Array(entries.prefix(1280))
    }
    public func recent(hostID: String? = nil, enabled: Bool = true) -> [TerminalRecentPath] {
        enabled ? Array(entries.filter { $0.hostID == hostID }.prefix(20)) : []
    }
}
