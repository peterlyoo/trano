import Foundation

/// A CSS-style hex color written in terminal text, with the physical columns it occupies.
public struct HexColorMatch: Equatable {
    public let text: String
    public let columns: Range<Int>
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double
}

public enum HexColorMatcher {
    private static let expression = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Za-z_&#])#(?:[0-9A-Fa-f]{8}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{4}|[0-9A-Fa-f]{3})(?![0-9A-Za-z_])"#)

    /// Returns the hex color covering `column` in one terminal row. Short forms made only of digits
    /// (`#204`, `#1234`) are issue or PR numbers far more often than colors, so they are not matched.
    public static func match(cells: [URLHintCell], column: Int) -> HexColorMatch? {
        var text = ""
        var spans: [Range<Int>] = []
        for (index, cell) in cells.enumerated() where cell.width > 0 {
            let value = cell.text.isEmpty || cell.text == "\u{0}" ? " " : cell.text
            text += value
            spans += Array(repeating: index..<(index + cell.width), count: value.utf16.count)
        }
        let source = text as NSString
        for result in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard result.range.location + result.range.length <= spans.count else { continue }
            let columns = spans[result.range.location].lowerBound..<spans[result.range.location + result.range.length - 1].upperBound
            guard columns.contains(column) else { continue }
            let token = source.substring(with: result.range)
            let digits = Array(token.dropFirst())
            if digits.count <= 4, digits.allSatisfy(\.isNumber) { return nil }
            let expanded = digits.count <= 4 ? digits.flatMap { [$0, $0] } : digits
            func channel(_ index: Int) -> Double {
                Double(Int(String(expanded[index * 2..<index * 2 + 2]), radix: 16) ?? 0) / 255
            }
            return HexColorMatch(text: token, columns: columns, red: channel(0), green: channel(1), blue: channel(2),
                                 alpha: expanded.count == 8 ? channel(3) : 1)
        }
        return nil
    }
}
