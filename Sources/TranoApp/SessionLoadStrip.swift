import SwiftUI
import TerminalCore

struct SessionLoadStrip: View {
    let snapshot: SessionLoadSnapshot?
    var showHook = false

    var body: some View {
        let display = SessionLoadPresentation(snapshot: snapshot, showHook: showHook)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(display.cpu)
                Text(display.memory)
                if let hook = display.hook { Text(hook) }
                Spacer(minLength: 0)
            }
            .font(.system(size: 9, design: .monospaced))
            .lineLimit(1)
            .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Canvas { context, size in
                    let samples = display.historyFractions
                    guard !samples.isEmpty else { return }
                    let step = size.width / 60
                    for (index, sample) in samples.enumerated() {
                        guard let sample else { continue }
                        let height = max(sample * size.height, 0.5)
                        let rect = CGRect(x: Double(index) * step, y: size.height - height,
                                          width: max(step - 1, 0.5), height: height)
                        context.fill(Path(rect), with: .color(.secondary.opacity(0.65)))
                    }
                }
                .frame(height: 8)
                if let status = display.status {
                    Text(status).font(.system(size: 8)).foregroundStyle(.tertiary).fixedSize()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.accessibilityLabel)
        .help("CPU uses one logical core as 100%. Resident memory may include shared pages. Hook p99 covers individual Claude Stop hooks over 30 minutes.")
    }
}

struct CachedSessionLoadStrip: View {
    @ObservedObject var cache: SessionLoadClientCache
    let paneID: String
    var showHook = false
    var body: some View { SessionLoadStrip(snapshot: cache.byPane[paneID], showHook: showHook) }
}
