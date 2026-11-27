import Foundation

public struct TerminalProgramNotice: Equatable {
    public let title: String
    public let body: String
    public init(title: String, body: String) { self.title = title; self.body = body }
}

public struct TerminalNotificationScanner {
    private var phase = 0
    private var bytes = Data()
    private var discarded = false
    public var retainedByteCount: Int { bytes.count }
    public init() {}
    public mutating func feed(_ data: Data) -> [TerminalProgramNotice] {
        guard phase != 0 || data.contains(27) else { return [] }
        var result: [TerminalProgramNotice] = []
        for byte in data {
            switch phase {
            case 0: if byte == 27 { phase = 1 }
            case 1:
                if byte == 93 { phase = 2; bytes.removeAll(keepingCapacity: true); discarded = false }
                else if byte != 27 { phase = 0 }
            case 2:
                if byte == 7 { finish(into: &result) }
                else if byte == 27 { phase = 3 }
                else if bytes.count < 4096 { bytes.append(byte) }
                else { discarded = true }
            default:
                if byte == 92 { finish(into: &result) }
                else if byte == 93 { phase = 2; bytes.removeAll(keepingCapacity: true); discarded = false }
                else { discarded = true; phase = byte == 27 ? 3 : 2 }
            }
        }
        return result
    }
    private mutating func finish(into result: inout [TerminalProgramNotice]) {
        defer { phase = 0; bytes.removeAll(keepingCapacity: true); discarded = false }
        guard result.count < 32, !discarded, let raw = String(data: bytes, encoding: .utf8) else { return }
        let title: String, body: String
        if raw.hasPrefix("9;"), !raw.hasPrefix("9;4;") {
            title = "Terminal"; body = String(raw.dropFirst(2))
        } else {
            let parts = raw.split(separator: ";", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4, parts[0] == "777", parts[1] == "notify" else { return }
            title = String(parts[2]); body = String(parts[3])
        }
        let bounded = NotificationMessage(identifier: "terminal", kind: .terminal, title: title, body: body)
        guard !bounded.body.isEmpty || !bounded.title.isEmpty else { return }
        result.append(TerminalProgramNotice(title: bounded.title, body: bounded.body))
    }
}

public struct TerminalNotificationGate {
    private var lastAllowed: TimeInterval?
    public init() {}
    public mutating func allow(now: TimeInterval, enabled: Bool) -> Bool {
        guard enabled, now.isFinite, lastAllowed.map({ now - $0 >= 5 }) ?? true else { return false }
        lastAllowed = now
        return true
    }
}
