import Foundation
import CoreFoundation
import CoreGraphics

public enum ThemeImportFormat: String, Codable { case ghostty, itermColors }

public enum ThemeImport {
    public static let maximumBytes = 1_048_576
    public static func parse(data: Data, filename: String, format: ThemeImportFormat? = nil) throws -> ThemePalette {
        guard !data.isEmpty, data.count <= maximumBytes else { throw TerminalError.invalid("Choose a theme file of at most 1 MiB.") }
        let inferred: ThemeImportFormat = filename.lowercased().hasSuffix(".itermcolors") || data.starts(with: Data("bplist".utf8)) ||
            data.starts(with: Data("<?xml".utf8)) ? .itermColors : .ghostty
        var palette = ThemePalette(name: URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent)
        if palette.name.isEmpty { palette.name = "Imported Theme" }
        switch format ?? inferred {
        case .ghostty: try ghostty(data, into: &palette)
        case .itermColors: try iterm(data, into: &palette)
        }
        try palette.validate()
        return palette
    }

    private static func ghostty(_ data: Data, into palette: inout ThemePalette) throws {
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw TerminalError.invalid("Ghostty themes must contain UTF-8 text.") }
        let known: Set<String> = ["background", "foreground", "cursor-color", "cursor-text", "selection-background", "selection-foreground", "palette"]
        var values: [String: String] = [:], count = 0
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count <= 65_536 else { throw TerminalError.invalid("Theme file has too many lines.") }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let separator = line.firstIndex(of: "=") else {
                if known.contains(line) { throw TerminalError.invalid("Theme color is missing a value.") }
                continue
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard known.contains(key) else { continue }
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if key == "palette" {
                guard let equals = value.firstIndex(of: "="), let index = index(String(value[..<equals])), (0...255).contains(index) else {
                    throw TerminalError.invalid("Theme palette indexes must be between 0 and 255.")
                }
                let color = try color(String(value[value.index(after: equals)...]))
                if index < 16 { palette.ansiColors[index] = color } else { palette.indexedColors[index] = color }
            } else {
                if !["cursor-color", "cursor-text", "selection-background", "selection-foreground"].contains(key) || !["cell-background", "cell-foreground"].contains(value) { _ = try color(value) }
                values[key] = value
            }
            count += 1
        }
        guard count > 0 else { throw TerminalError.invalid("No supported theme colors were found.") }
        if let value = values["background"] { palette.background = try color(value) }
        if let value = values["foreground"] { palette.foreground = try color(value) }
        func resolved(_ value: String) throws -> String {
            switch value {
            case "cell-background": return palette.background
            case "cell-foreground": return palette.foreground
            default: return try color(value)
            }
        }
        if let value = values["cursor-color"] { palette.cursor = try resolved(value) }
        if let value = values["cursor-text"] { palette.cursorText = try resolved(value) }
        if let value = values["selection-background"] { palette.selection = try resolved(value) }
        if let value = values["selection-foreground"] { palette.selectionForeground = try resolved(value) }
    }

    private static func index(_ text: String) -> Int? {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where value.hasPrefix(prefix) {
            return Int(value.dropFirst(2), radix: radix)
        }
        return Int(value, radix: 10)
    }

    private static func color(_ text: String) throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = value.hasPrefix("#") ? value : "#" + value
        if AppearancePreferences.isHexColor(hex) { return hex.uppercased() }
        let name = value.lowercased().filter { !$0.isWhitespace }
        if let color = ThemeX11Colors.values[name] { return color }
        throw TerminalError.invalid("Unknown theme color: \(String(value.prefix(80))).")
    }

    private static func iterm(_ data: Data, into palette: inout ThemePalette) throws {
        if !data.starts(with: Data("bplist".utf8)) {
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
                throw TerminalError.invalid("Invalid iTerm color property list.")
            }
            let upper = text.uppercased()
            guard !upper.contains("<!ENTITY") else { throw TerminalError.invalid("Theme files cannot declare XML entities.") }
            if let begin = upper.range(of: "<!DOCTYPE"), let end = upper[begin.lowerBound...].firstIndex(of: ">"),
               upper[begin.lowerBound...end].contains("[") { throw TerminalError.invalid("Theme files cannot declare an XML subset.") }
        }
        guard let colors = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw TerminalError.invalid("An iTerm color theme must be a property-list dictionary.")
        }
        var count = 0
        for (key, value) in colors {
            switch key {
            case "Background Color": palette.background = try itermColor(value)
            case "Foreground Color": palette.foreground = try itermColor(value)
            case "Cursor Color": palette.cursor = try itermColor(value)
            case "Cursor Text Color": palette.cursorText = try itermColor(value)
            case "Selection Color": palette.selection = try itermColor(value)
            case "Selected Text Color": palette.selectionForeground = try itermColor(value)
            default:
                guard key.hasPrefix("Ansi "), key.hasSuffix(" Color") else { continue }
                guard let index = Int(key.dropFirst(5).dropLast(6)), (0...255).contains(index) else {
                    throw TerminalError.invalid("iTerm palette indexes must be between 0 and 255.")
                }
                let color = try itermColor(value)
                if index < 16 { palette.ansiColors[index] = color } else { palette.indexedColors[index] = color }
            }
            count += 1
        }
        guard count > 0 else { throw TerminalError.invalid("No supported iTerm theme colors were found.") }
    }

    private static func itermColor(_ object: Any) throws -> String {
        guard let value = object as? [String: Any] else { throw TerminalError.invalid("Invalid iTerm color components.") }
        var components: [CGFloat] = []
        for key in ["Red Component", "Green Component", "Blue Component"] {
            guard let number = value[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, (0...1).contains(number.doubleValue) else {
                throw TerminalError.invalid("iTerm color components must be finite numbers between 0 and 1.")
            }
            components.append(CGFloat(number.doubleValue))
        }
        guard value["Color Space"] == nil || value["Color Space"] is String else { throw TerminalError.invalid("Invalid iTerm color space.") }
        let space = (value["Color Space"] as? String) ?? "Calibrated"
        switch space.lowercased() {
        case "srgb", "calibrated": break
        case "displayp3", "display p3", "p3":
            guard let source = CGColorSpace(name: CGColorSpace.displayP3), let destination = CGColorSpace(name: CGColorSpace.sRGB),
                  let converted = CGColor(colorSpace: source, components: components + [1])?.converted(to: destination, intent: .relativeColorimetric, options: nil),
                  let result = converted.components, result.count >= 3 else { throw TerminalError.invalid("Cannot convert this iTerm color space.") }
            components = Array(result.prefix(3))
        default: throw TerminalError.invalid("Unsupported iTerm color space.")
        }
        let values = components.map { Int((min(1, max(0, $0)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", values[0], values[1], values[2])
    }
}
