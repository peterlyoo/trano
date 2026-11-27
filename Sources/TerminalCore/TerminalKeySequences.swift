import Foundation

public struct TerminalKeySequenceHint: Equatable, Sendable {
    public let binding: String
    public let title: String
    public let action: ActionID
    public init(binding: String, title: String, action: ActionID) {
        self.binding = binding; self.title = title; self.action = action
    }
}

public struct TerminalKeySequenceMap {
    public let singles: KeyBindingMap
    public let bindings: [String: [String]]
    private let sequences: [(strokes: [String], action: ActionID)]

    public init(overrides: [String: [String]] = [:]) throws {
        var singleOverrides: [String: [String]] = [:]
        var canonicalOverrides: [String: [String]] = [:]
        var sequences: [(strokes: [String], action: ActionID)] = []
        for (id, bindings) in overrides {
            guard let action = ActionID(rawValue: id), bindings.count <= 4 else { throw TerminalError.invalid("Invalid keyboard sequence action") }
            singleOverrides[id] = []
            canonicalOverrides[id] = []
            for binding in bindings {
                if let canonical = try? KeyBindingMap.normalize(binding) {
                    singleOverrides[id, default: []].append(canonical)
                    canonicalOverrides[id, default: []].append(canonical)
                    continue
                }
                guard binding.utf8.count <= 160 else { throw TerminalError.invalid("Use two or three keyboard strokes") }
                var strokes: [String] = []
                var pending: String?
                for part in binding.split(separator: ",", omittingEmptySubsequences: false) {
                    let candidate = pending.map { $0 + "," + part } ?? String(part)
                    pending = candidate
                    if let canonical = try? KeyBindingMap.normalize(candidate.trimmingCharacters(in: .whitespaces)) {
                        strokes.append(canonical)
                        pending = nil
                    }
                }
                guard pending == nil, (2...3).contains(strokes.count) else { throw TerminalError.invalid("Use two or three keyboard strokes") }
                guard strokes.allSatisfy({ !KeyBindingMap.reserved.contains($0) }) else { throw TerminalError.invalid("Keyboard sequence contains a reserved shortcut") }
                sequences.append((strokes, action))
                canonicalOverrides[id, default: []].append(strokes.joined(separator: ","))
            }
        }
        for action in [ActionID.activity, .goToDirectory] where overrides[action.rawValue] == nil {
            guard let command = ActionCatalog.all.first(where: { $0.action == action }) else { continue }
            let prefixes = Set(sequences.map { $0.strokes[0] })
            let available = command.bindings.filter { !prefixes.contains($0) }
            if available != command.bindings { singleOverrides[command.id] = available }
        }
        let singles = try KeyBindingMap(overrides: singleOverrides)
        for (index, candidate) in sequences.enumerated() {
            guard singles.action(for: candidate.strokes[0]) == nil else { throw TerminalError.invalid("Sequence prefix is assigned to a single shortcut") }
            for previous in sequences.prefix(index) {
                guard !candidate.strokes.starts(with: previous.strokes), !previous.strokes.starts(with: candidate.strokes) else {
                    throw TerminalError.invalid("Keyboard sequences have an ambiguous prefix")
                }
            }
        }
        self.singles = singles; self.sequences = sequences
        var fullBindings = singles.bindings
        for (id, values) in canonicalOverrides {
            var seen = Set<String>()
            fullBindings[id] = values.filter { seen.insert($0).inserted }
        }
        bindings = fullBindings
    }

    public func hints(after prefix: [String]) -> [TerminalKeySequenceHint] {
        sequences.filter { $0.strokes.count > prefix.count && $0.strokes.starts(with: prefix) }.map { binding in
            TerminalKeySequenceHint(binding: binding.strokes.dropFirst(prefix.count).joined(separator: ","),
                                    title: ActionCatalog.all.first { $0.action == binding.action }?.title ?? binding.action.rawValue,
                                    action: binding.action)
        }.sorted { $0.title == $1.title ? $0.binding < $1.binding : $0.title < $1.title }
    }
    public func action(for sequence: [String]) -> ActionID? { sequences.first { $0.strokes == sequence }?.action }
    public func hasPrefix(_ sequence: [String]) -> Bool { sequences.contains { $0.strokes.count > sequence.count && $0.strokes.starts(with: sequence) } }
}

public enum TerminalKeySequenceResult: Equatable, Sendable {
    case unhandled
    case pending([TerminalKeySequenceHint])
    case action(ActionID)
    case cancelled
}

public struct TerminalKeySequenceTracker {
    public private(set) var prefix: [String] = []
    private var lastStrokeAt: TimeInterval?
    public init() {}
    public mutating func consume(_ stroke: String, map: TerminalKeySequenceMap,
                                 showHints: Bool, now: TimeInterval,
                                 composing: Bool = false) -> TerminalKeySequenceResult {
        guard !composing, now.isFinite else { cancel(); return .unhandled }
        if let lastStrokeAt, now < lastStrokeAt || now - lastStrokeAt > 1.5 { cancel() }
        if !prefix.isEmpty, stroke == "escape" { cancel(); return .cancelled }
        guard let normalized = try? KeyBindingMap.normalize(stroke) else {
            let pending = !prefix.isEmpty
            cancel()
            return pending ? .cancelled : .unhandled
        }
        let pending = !prefix.isEmpty
        let candidate = prefix + [normalized]
        if let action = map.action(for: candidate) { cancel(); return .action(action) }
        if map.hasPrefix(candidate) {
            prefix = candidate; lastStrokeAt = now
            return .pending(showHints ? map.hints(after: candidate) : [])
        }
        cancel()
        return pending ? .cancelled : .unhandled
    }
    public mutating func cancel() { prefix = []; lastStrokeAt = nil }
}
