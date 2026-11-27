#if !SWIFTTERM_EMBEDDED
import Foundation

extension Terminal {
    /// Renders the current terminal state as a byte stream that reproduces it
    /// on a freshly reset terminal of the same size. Hold `terminalLock`.
    /// The stream contains no queries, so replaying it produces no replies.
    public func reattachSnapshot(title: String? = nil) -> [UInt8] {
        var out = "\u{1b}c\u{1b}[0m"
        if let title, !title.isEmpty {
            out += "\u{1b}]2;" + String(String.UnicodeScalarView(title.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 })) + "\u{7}"
        }
        let normal = normalBuffer
        let normalCount = normal.lines.count
        for row in 0..<normalCount {
            if row > 0 { out += "\r\n" }
            out += Self.renderLine(normal.lines[row], cols: cols)
            out += "\u{1b}[0m"
        }
        if isCurrentBufferAlternate {
            out += "\u{1b}[?1049h\u{1b}[H\u{1b}[2J"
            let alt = altBuffer
            for row in 0..<min(rows, alt.lines.count) {
                out += "\u{1b}[\(row + 1);1H" + Self.renderLine(alt.lines[alt.yBase + row < alt.lines.count ? alt.yBase + row : row], cols: cols) + "\u{1b}[0m"
            }
        }
        let active = buffer
        if active.scrollTop != 0 || active.scrollBottom != rows - 1 {
            out += "\u{1b}[\(active.scrollTop + 1);\(active.scrollBottom + 1)r"
        }
        out += "\u{1b}[\(min(active.y, rows - 1) + 1);\(min(active.x, cols - 1) + 1)H"
        if applicationCursor { out += "\u{1b}[?1h" }
        if bracketedPasteMode { out += "\u{1b}[?2004h" }
        if sendFocus { out += "\u{1b}[?1004h" }
        switch mouseMode {
        case .off: break
        case .x10: out += "\u{1b}[?9h"
        case .vt200: out += "\u{1b}[?1000h"
        case .buttonEventTracking: out += "\u{1b}[?1002h"
        case .anyEvent: out += "\u{1b}[?1003h"
        }
        switch mouseProtocol {
        case .x10: break
        case .utf8: out += "\u{1b}[?1005h"
        case .sgr: out += "\u{1b}[?1006h"
        case .urxvt: out += "\u{1b}[?1015h"
        case .sgrPixel: out += "\u{1b}[?1016h"
        }
        let keyboard = keyboardEnhancementFlags.rawValue
        if keyboard != 0 { out += "\u{1b}[>\(keyboard)u" }
        if cursorHidden { out += "\u{1b}[?25l" }
        return Array(out.utf8)
    }

    static func sgr(_ attribute: Attribute) -> String {
        var codes = ["0"]
        let style = attribute.style
        if style.contains(.bold) { codes.append("1") }
        if style.contains(.dim) { codes.append("2") }
        if style.contains(.italic) { codes.append("3") }
        if style.contains(.underline) { codes.append("4") }
        if style.contains(.blink) { codes.append("5") }
        if style.contains(.inverse) { codes.append("7") }
        if style.contains(.invisible) { codes.append("8") }
        if style.contains(.crossedOut) { codes.append("9") }
        switch attribute.fg {
        case .ansi256(let code): codes.append(code < 8 ? "\(30 + Int(code))" : code < 16 ? "\(90 + Int(code) - 8)" : "38;5;\(code)")
        case .trueColor(let r, let g, let b): codes.append("38;2;\(r);\(g);\(b)")
        case .defaultColor, .defaultInvertedColor: break
        }
        switch attribute.bg {
        case .ansi256(let code): codes.append(code < 8 ? "\(40 + Int(code))" : code < 16 ? "\(100 + Int(code) - 8)" : "48;5;\(code)")
        case .trueColor(let r, let g, let b): codes.append("48;2;\(r);\(g);\(b)")
        case .defaultColor, .defaultInvertedColor: break
        }
        return "\u{1b}[" + codes.joined(separator: ";") + "m"
    }

    static func renderLine(_ line: BufferLine, cols: Int) -> String {
        let width = min(cols, line.count)
        var last = width - 1
        while last >= 0 {
            let cell = line[last]
            if cell.code != 0 && cell.getText() != " " { break }
            if cell.attribute.bg != .defaultInvertedColor && cell.attribute.bg != .defaultColor { break }
            if cell.attribute.style.contains(.inverse) { break }
            last -= 1
        }
        guard last >= 0 else { return "" }
        var out = ""
        var current = Attribute.empty
        for column in 0...last {
            let cell = line[column]
            if cell.width == 0 { continue }
            if cell.attribute != current {
                out += sgr(cell.attribute)
                current = cell.attribute
            }
            out += cell.code == 0 ? " " : cell.getText()
        }
        return out
    }
}
#endif

#if !SWIFTTERM_EMBEDDED
extension Terminal {
    /// Returns up to `history` scrollback lines followed by the visible rows of
    /// the active buffer. Trailing empty rows are dropped. Hold `terminalLock`.
    public func captureLines(history: Int, escapes: Bool) -> [String] {
        let active = buffer
        let total = active.lines.count
        let end = min(total, active.yBase + rows)
        let start = max(0, active.yBase - max(0, history))
        var result: [String] = []
        if start < end {
            for row in start..<end {
                if escapes {
                    let text = Self.renderLine(active.lines[row], cols: cols)
                    result.append(text.isEmpty ? "" : text + "\u{1b}[0m")
                } else {
                    result.append(Self.plainLine(active.lines[row], cols: cols))
                }
            }
        }
        while let last = result.last, last.isEmpty { result.removeLast() }
        return result
    }

    static func plainLine(_ line: BufferLine, cols: Int) -> String {
        var out = ""
        for column in 0..<min(cols, line.count) {
            let cell = line[column]
            if cell.width == 0 { continue }
            out += cell.code == 0 ? " " : cell.getText()
        }
        while out.last == " " { out.removeLast() }
        return out
    }
}
#endif
