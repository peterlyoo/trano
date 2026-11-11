import AppKit

@MainActor final class CommandKeyHints {
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> () -> Void

    private(set) var isVisible = false
    private let schedule: Schedule
    private let onChange: (Bool) -> Void
    private var pending: (() -> Void)?
    private var generation = 0
    private var commandDown = false
    private var suppressed = false

    init(schedule: Schedule? = nil, onChange: @escaping (Bool) -> Void) {
        self.schedule = schedule ?? { delay, action in
            let work = DispatchWorkItem(block: action)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return { work.cancel() }
        }
        self.onChange = onChange
    }

    func flagsChanged(_ flags: NSEvent.ModifierFlags, eligible: @escaping () -> Bool) {
        let modifiers = flags.intersection([.command, .control, .option, .shift, .function])
        guard modifiers.contains(.command) else { cancel(); return }
        commandDown = true
        guard modifiers == .command else { interrupt(); return }
        guard !suppressed, eligible() else { stop(); return }
        guard pending == nil, !isVisible else { return }
        generation += 1
        let current = generation
        pending = schedule(0.4) { [weak self] in
            guard let self, self.generation == current, self.commandDown, !self.suppressed else { return }
            self.pending = nil
            guard eligible() else { self.cancel(); return }
            self.setVisible(true)
        }
    }

    func interrupt() {
        guard commandDown else { return }
        suppressed = true
        stop()
    }

    func cancel() {
        commandDown = false
        suppressed = false
        stop()
    }

    private func stop() {
        guard pending != nil || isVisible else { return }
        generation += 1
        pending?()
        pending = nil
        setVisible(false)
    }

    private func setVisible(_ value: Bool) {
        guard isVisible != value else { return }
        isVisible = value
        onChange(value)
    }

    static func label(for index: Int, count: Int) -> String? {
        guard index >= 0, index < count else { return nil }
        if index < 8 { return "⌘\(index + 1)" }
        return index == count - 1 ? "⌘9" : nil
    }
}
