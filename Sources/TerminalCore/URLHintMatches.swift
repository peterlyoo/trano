import Foundation

public struct URLHintCell: Sendable, Equatable {
    public let text: String
    public let width: Int
    public init(text: String, width: Int = 1) { self.text = text; self.width = width }
}

public struct URLHintRow: Sendable, Equatable {
    public let row: Int
    public let cells: [URLHintCell]
    public let isWrapped: Bool
    public init(row: Int, cells: [URLHintCell], isWrapped: Bool = false) {
        self.row = row; self.cells = cells; self.isWrapped = isWrapped
    }
}

public struct URLHintSpan: Sendable, Equatable {
    public let row: Int
    public let columns: Range<Int>
    public init(row: Int, columns: Range<Int>) { self.row = row; self.columns = columns }
}

public struct URLHintMatch: Sendable, Equatable {
    public let label: String
    public let url: String
    public let spans: [URLHintSpan]
    public init(label: String, url: String, spans: [URLHintSpan]) {
        self.label = label; self.url = url; self.spans = spans
    }
}

public enum URLHintMatcher {
    private static let expression = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])https?://[^\s<>"'`\x00-\x1f]+"#, options: .caseInsensitive)
    private static let alphabet = Array("asdfghjklqwertyuiopzxcvbnm")

    /// Hangul glued to an ASCII letter, digit or closing bracket is a Korean particle (`…/pull/61에서`), not part of
    /// the link; Hangul right after a path or query delimiter (`/wiki/대한민국`) stays.
    private static func isHangul(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            (0xAC00...0xD7A3).contains($0.value) || (0x1100...0x11FF).contains($0.value) || (0x3130...0x318F).contains($0.value)
        }
    }

    public static func matches(rows: [URLHintRow], maximumMatches: Int = 256) -> [URLHintMatch] {
        let limit = min(256, max(0, maximumMatches))
        guard limit > 0 else { return [] }
        var found: [(String, [URLHintSpan])] = []
        var text = ""
        var positions: [URLHintSpan] = []

        func collect() {
            guard found.count < limit else { return }
            let source = text as NSString
            for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                guard found.count < limit else { break }
                var candidate = source.substring(with: match.range)
                guard candidate.utf8.count <= 8192 else { continue }
                let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]
                var counts: [Character: Int] = [:]
                for character in candidate where "()[]{}".contains(character) { counts[character, default: 0] += 1 }
                while let last = candidate.last {
                    if ".,:;!?*".contains(last) { candidate.removeLast(); continue }
                    if isHangul(last) {
                        let run = candidate.reversed().prefix(while: isHangul).count
                        let before = candidate.dropLast(run).last
                        if let before, before.isASCII, before.isLetter || before.isNumber || before == ")" || before == "]" {
                            candidate.removeLast(run); continue
                        }
                    }
                    if let opening = pairs[last], counts[last, default: 0] > counts[opening, default: 0] {
                        counts[last, default: 0] -= 1
                        candidate.removeLast(); continue
                    }
                    break
                }
                guard candidate.utf8.count <= 8192, let url = URL(string: candidate),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else { continue }
                let end = match.range.location + (candidate as NSString).length
                guard end <= positions.count else { continue }
                var spans: [URLHintSpan] = []
                for position in positions[match.range.location..<end] {
                    if let last = spans.last, last.row == position.row, last.columns.upperBound >= position.columns.lowerBound {
                        spans[spans.count - 1] = URLHintSpan(row: last.row, columns: last.columns.lowerBound..<max(last.columns.upperBound, position.columns.upperBound))
                    } else { spans.append(position) }
                }
                guard !spans.isEmpty else { continue }
                found.append((candidate, spans))
            }
        }

        for row in rows {
            if !row.isWrapped {
                collect()
                text = ""; positions.removeAll(keepingCapacity: true)
            }
            guard found.count < limit else { break }
            let last = row.cells.lastIndex { !$0.text.isEmpty && $0.text != "\u{0}" } ?? -1
            for (column, cell) in row.cells.enumerated() where column <= last && cell.width > 0 {
                let value = cell.text.isEmpty || cell.text == "\u{0}" ? " " : cell.text
                guard positions.count + value.utf16.count <= 1_048_576 else { break }
                text += value
                positions += Array(repeating: URLHintSpan(row: row.row, columns: column..<(column + max(1, cell.width))), count: value.utf16.count)
            }
        }
        collect()
        var digits = 1, capacity = alphabet.count
        while capacity < found.count { digits += 1; capacity *= alphabet.count }
        return found.enumerated().map { index, value in
            var number = index
            var characters = Array(repeating: alphabet[0], count: digits)
            for place in (0..<digits).reversed() { characters[place] = alphabet[number % alphabet.count]; number /= alphabet.count }
            return URLHintMatch(label: String(characters), url: value.0, spans: value.1)
        }
    }
}
