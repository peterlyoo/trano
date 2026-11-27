import Foundation

public struct KeyboardLayoutSearch: Sendable {
    public enum Match: Int, CaseIterable, Sendable {
        case literalExact, literal, alternateExact, alternate
    }

    private let query: String
    private let alternateQuery: String?

    public init(query: String) {
        self.query = query
        alternateQuery = Self.latinKeystrokes(for: query)
    }

    public func match(title: String, detail: String = "") -> Match? {
        if query.isEmpty { return .literal }
        if title.caseInsensitiveCompare(query) == .orderedSame { return .literalExact }
        let text = title + " " + detail
        if text.localizedCaseInsensitiveContains(query) { return .literal }
        guard let alternateQuery else { return nil }
        if title.caseInsensitiveCompare(alternateQuery) == .orderedSame { return .alternateExact }
        return text.localizedCaseInsensitiveContains(alternateQuery) ? .alternate : nil
    }

    public static func latinKeystrokes(for text: String) -> String? {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var converted = false
        for scalar in text.unicodeScalars {
            let value = Int(scalar.value)
            switch value {
            case 0xAC00...0xD7A3:
                let syllable = value - 0xAC00
                result += initial[syllable / 588]
                result += vowel[(syllable % 588) / 28]
                result += trailing[syllable % 28]
            case 0x1100...0x1112: result += initial[value - 0x1100]
            case 0x1161...0x1175: result += vowel[value - 0x1161]
            case 0x11A8...0x11C2: result += trailing[value - 0x11A7]
            case 0x3131...0x314E: result += consonant[value - 0x3131]
            case 0x314F...0x3163: result += vowel[value - 0x314F]
            default:
                result.unicodeScalars.append(scalar)
                continue
            }
            converted = true
        }
        return converted ? result : nil
    }

    private static let initial = ["r", "R", "s", "e", "E", "f", "a", "q", "Q", "t", "T", "d", "w", "W", "c", "z", "x", "v", "g"]
    private static let vowel = ["k", "o", "i", "O", "j", "p", "u", "P", "h", "hk", "ho", "hl", "y", "n", "nj", "np", "nl", "b", "m", "ml", "l"]
    private static let trailing = ["", "r", "R", "rt", "s", "sw", "sg", "e", "f", "fr", "fa", "fq", "ft", "fx", "fv", "fg", "a", "q", "qt", "t", "T", "d", "w", "c", "z", "x", "v", "g"]
    private static let consonant = ["r", "R", "rt", "s", "sw", "sg", "e", "E", "f", "fr", "fa", "fq", "ft", "fx", "fv", "fg", "a", "q", "Q", "qt", "t", "T", "d", "w", "W", "c", "z", "x", "v", "g"]
}
