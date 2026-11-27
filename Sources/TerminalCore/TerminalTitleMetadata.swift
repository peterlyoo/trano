import Foundation

enum TerminalTitleMetadata {
    private static let maximumBytes = 8192

    static func normalize(_ value: String?) -> String? {
        guard let value, value.utf8.count <= maximumBytes else { return nil }
        let title = String(String.UnicodeScalarView(value.unicodeScalars.filter {
            $0.value >= 32 && !(127...159).contains($0.value) && !CharacterSet.newlines.contains($0)
        }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return String(title.prefix(200))
    }
}
