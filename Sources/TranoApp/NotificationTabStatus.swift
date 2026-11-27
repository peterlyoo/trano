import SwiftUI
import TerminalCore

struct NotificationTabStatus: View {
    let state: ActivityState
    var body: some View {
        Circle().fill(color).frame(width: 5, height: 5)
            .overlay { Circle().stroke(Color(NSColor.windowBackgroundColor), lineWidth: 1) }
            .accessibilityLabel(state == .running ? "Working" : state.rawValue.capitalized)
    }
    private var color: Color {
        switch state {
        case .running: return .yellow
        case .blocked: return .orange
        case .error: return .red
        case .done: return .green
        default: return .secondary
        }
    }
}
