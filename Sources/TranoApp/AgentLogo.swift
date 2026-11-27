import SwiftUI
import TerminalCore

struct AgentLogo: View {
    let agent: AgentKind
    var tint: Color? = nil
    var body: some View {
        Group {
            switch agent {
            case .shell: ShellLogo(tint: tint)
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
                        context.stroke(ray, with: .color(tint ?? Color(red: 0.87, green: 0.58, blue: 0.44)), style: StrokeStyle(lineWidth: max(1.5, radius * 0.22), lineCap: .square))
                    }
                }.frame(width: 14, height: 14)
            case .codex:
                HStack(alignment: .bottom, spacing: 1) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                    Rectangle().frame(width: 5, height: 1.5).padding(.bottom, 1)
                }.foregroundStyle(tint ?? .primary).frame(width: 14, height: 14)
            }
        }.accessibilityLabel(agent == .shell ? "Shell" : agent.rawValue.capitalized)
    }
}

private struct ShellLogo: View {
    var tint: Color?

    var body: some View {
        Canvas { context, _ in
            let body = Path(roundedRect: CGRect(x: 0.5, y: 1, width: 13, height: 12), cornerRadius: 3)
            context.fill(body, with: .linearGradient(
                Gradient(colors: [Color(white: 0.23), Color(white: 0.06)]),
                startPoint: CGPoint(x: 7, y: 1), endPoint: CGPoint(x: 7, y: 13)))
            context.stroke(body, with: .color(Color(white: 0.43)), lineWidth: 0.65)

            var prompt = Path()
            prompt.move(to: CGPoint(x: 3.2, y: 4.3))
            prompt.addLine(to: CGPoint(x: 5.6, y: 6.7))
            prompt.addLine(to: CGPoint(x: 3.2, y: 9.1))
            prompt.move(to: CGPoint(x: 7.2, y: 9.1))
            prompt.addLine(to: CGPoint(x: 10.6, y: 9.1))
            context.stroke(prompt, with: .color(tint ?? Color(red: 0.48, green: 0.91, blue: 0.55)),
                           style: StrokeStyle(lineWidth: 1.15, lineCap: .round, lineJoin: .round))
        }.frame(width: 14, height: 14)
    }
}
