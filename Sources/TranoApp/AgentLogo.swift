import SwiftUI
import TerminalCore

struct AgentLogo: View {
    let agent: AgentKind
    var body: some View {
        Group {
            switch agent {
            case .shell: Image(systemName: "terminal")
            case .claude:
                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    let radius = min(size.width, size.height) * 0.45
                    for index in 0..<12 {
                        let angle = Double(index) * .pi / 6
                        let outer = radius * (index.isMultiple(of: 3) ? 0.86 : 1)
                        var ray = Path()
                        ray.move(to: CGPoint(x: center.x + cos(angle) * radius * 0.22, y: center.y + sin(angle) * radius * 0.22))
                        ray.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
                        context.stroke(ray, with: .color(Color(red: 0.87, green: 0.58, blue: 0.44)), style: StrokeStyle(lineWidth: max(1.5, radius * 0.22), lineCap: .square))
                    }
                }.frame(width: 14, height: 14)
            case .codex:
                HStack(alignment: .bottom, spacing: 1) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                    Rectangle().frame(width: 5, height: 1.5).padding(.bottom, 1)
                }.foregroundStyle(.primary).frame(width: 14, height: 14)
            }
        }.accessibilityLabel(agent == .shell ? "Shell" : agent.rawValue.capitalized)
    }
}
