import Foundation

public struct SessionLoadPresentation: Equatable {
    public let cpu: String
    public let memory: String
    public let hook: String?
    public let status: String?
    public let cpuFraction: Double?
    public let historyFractions: [Double?]
    public let accessibilityLabel: String

    public init(snapshot: SessionLoadSnapshot?, showHook: Bool = false) {
        let live = snapshot?.status == .available || snapshot?.status == .warmingUp
        let percent = live ? Self.valid(snapshot?.cpuPercent) : nil
        let percentText = percent.map { Self.decimal($0, precision: $0 > 0 && $0 < 10 ? 1 : 0) }
        cpu = percentText.map { "CPU " + $0 + "%" } ?? "CPU —"
        cpuFraction = percent.map { min($0 / 100, 1) }
        memory = live ? snapshot?.residentBytes.map(Self.memoryText) ?? "— MiB" : "— MiB"
        switch snapshot?.status {
        case .available: status = nil
        case .warmingUp: status = "Sampling"
        case .stale: status = "Stale"
        case .stopped: status = "Stopped"
        case .remoteUnavailable: status = "Remote"
        case .unavailable, nil: status = "Unavailable"
        }
        let latency = snapshot?.hook
        let p99 = latency?.status == .available ? Self.valid(latency?.p99Milliseconds) : nil
        let p99Text = p99.map { Self.decimal($0, precision: 1) }
        if showHook {
            if latency?.status == .stale { hook = "p99 stale" }
            else { hook = p99Text.map { "p99 " + $0 + " ms" } ?? "p99 —" }
        } else { hook = nil }
        let history = Array((snapshot?.history ?? []).suffix(60))
        let ceiling = max(100, history.compactMap { Self.valid($0.cpuPercent) }.max() ?? 100)
        historyFractions = history.map { point in Self.valid(point.cpuPercent).map { min($0 / ceiling, 1) } }
        var accessibility = [percentText.map { $0 + " percent CPU" } ?? "CPU unavailable", memory + " resident memory"]
        if showHook {
            if let p99Text {
                accessibility.append("Stop hook p99 " + p99Text + " milliseconds from \(latency?.sampleCount ?? 0) individual Stop hooks")
            } else { accessibility.append(latency?.status == .stale ? "Stop hook p99 stale" : "Stop hook p99 unavailable") }
        }
        if let status { accessibility.append(status) }
        accessibilityLabel = accessibility.joined(separator: ", ")
    }

    private static func valid(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func decimal(_ value: Double, precision: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1e", locale: Locale(identifier: "en_US_POSIX"), value) }
        let scale = precision == 0 ? 1.0 : 10.0
        let rounded = (value * scale).rounded(.toNearestOrAwayFromZero) / scale
        return String(format: precision == 0 ? "%.0f" : "%.1f", locale: Locale(identifier: "en_US_POSIX"), rounded)
    }

    private static func memoryText(_ bytes: UInt64) -> String {
        let mib = Double(bytes) / 1_048_576
        if mib >= 1_048_576 { return decimal(mib / 1_048_576, precision: 1) + " TiB" }
        if mib >= 1024 { return decimal(mib / 1024, precision: 1) + " GiB" }
        return decimal(mib, precision: mib > 0 && mib < 10 ? 1 : 0) + " MiB"
    }
}
