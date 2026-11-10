import Foundation

public struct KeyBindingMap {
    public let bindings: [String: [String]]
    private let actions: [String: ActionID]
    public static let reserved = Set(["cmd+q", "cmd+h", "cmd+alt+h", "cmd+m"] + (1...9).map { "cmd+\($0)" })

    public init(overrides: [String: [String]] = [:]) throws {
        guard overrides.count <= ActionCatalog.all.count else { throw TerminalError.invalid("Too many keyboard overrides.") }
        for id in overrides.keys where ActionID(rawValue: id) == nil { throw TerminalError.invalid("Unknown keyboard action: \(id)") }
        var result: [String: [String]] = [:]
        var resolved: [String: ActionID] = [:]
        for action in ActionCatalog.all {
            let keys = overrides[action.id] ?? action.bindings
            guard keys.count <= 4 else { throw TerminalError.invalid("Use at most four shortcuts per action.") }
            let canonical = try keys.map(Self.normalize)
            for key in canonical {
                guard !Self.reserved.contains(key) else { throw TerminalError.invalid("\(Self.display(key)) is reserved by macOS or tab selection.") }
                if let existing = resolved[key], existing != action.action {
                    let title = ActionCatalog.all.first { $0.action == existing }?.title ?? existing.rawValue
                    throw TerminalError.invalid("\(Self.display(key)) is already assigned to \(title).")
                }
                resolved[key] = action.action
            }
            result[action.id] = Array(NSOrderedSet(array: canonical)) as? [String] ?? canonical
        }
        bindings = result; actions = resolved
    }

    public func action(for binding: String) -> ActionID? {
        guard let key = try? Self.normalize(binding) else { return nil }
        return actions[key]
    }

    public static func normalize(_ binding: String) throws -> String {
        guard binding.utf8.count <= 80 else { throw TerminalError.invalid("Keyboard shortcut is too long.") }
        let components = binding.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        let modifiers = ["cmd", "ctrl", "alt", "shift"]
        guard let key = components.last, components.count >= 2, components.count <= 5,
              key.count == 1 && !key.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) || ["left", "right", "up", "down", "enter", "tab", "escape", "space", "pageup", "pagedown", "home", "end"].contains(key) else {
            throw TerminalError.invalid("Use a shortcut such as cmd+shift+p or ctrl+tab.")
        }
        let flags = Array(components.dropLast())
        guard Set(flags).count == flags.count, flags.allSatisfy(modifiers.contains), flags.contains("cmd") || flags.contains("ctrl") else {
            throw TerminalError.invalid("Shortcuts require Command or Control and valid, unique modifiers.")
        }
        return (modifiers.filter(flags.contains) + [key]).joined(separator: "+")
    }

    public static func display(_ binding: String) -> String {
        binding.replacingOccurrences(of: "cmd+", with: "⌘").replacingOccurrences(of: "ctrl+", with: "⌃")
            .replacingOccurrences(of: "alt+", with: "⌥").replacingOccurrences(of: "shift+", with: "⇧")
            .replacingOccurrences(of: "left", with: "←").replacingOccurrences(of: "right", with: "→")
            .replacingOccurrences(of: "up", with: "↑").replacingOccurrences(of: "down", with: "↓").uppercased()
    }
}
