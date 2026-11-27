import AppKit
import SwiftUI
import TerminalCore

enum NativeKeyBinding {
    static func binding(for event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard flags.contains(.command) || flags.contains(.control) else { return nil }
        let special: [UInt16: String] = [123: "left", 124: "right", 125: "down", 126: "up", 36: "enter", 76: "enter", 48: "tab", 24: "=", 27: "-", 53: "escape", 49: "space", 116: "pageup", 121: "pagedown", 115: "home", 119: "end"]
        var key = special[event.keyCode] ?? event.charactersIgnoringModifiers?.lowercased() ?? ""
        if key == "{" { key = "[" }; if key == "}" { key = "]" }
        var parts: [String] = []
        if flags.contains(.command) { parts.append("cmd") }
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("alt") }
        if flags.contains(.shift) { parts.append("shift") }
        return try? KeyBindingMap.normalize((parts + [key]).joined(separator: "+"))
    }

    static func menuEquivalent(_ binding: String) -> (String, NSEvent.ModifierFlags) {
        guard let canonical = try? KeyBindingMap.normalize(binding) else { return ("", []) }
        let parts = canonical.split(separator: "+").map(String.init)
        let names: [String: String] = ["left": String(UnicodeScalar(NSLeftArrowFunctionKey)!), "right": String(UnicodeScalar(NSRightArrowFunctionKey)!), "up": String(UnicodeScalar(NSUpArrowFunctionKey)!), "down": String(UnicodeScalar(NSDownArrowFunctionKey)!), "enter": "\r", "tab": "\t", "escape": "\u{1b}", "space": " ", "pageup": String(UnicodeScalar(NSPageUpFunctionKey)!), "pagedown": String(UnicodeScalar(NSPageDownFunctionKey)!), "home": String(UnicodeScalar(NSHomeFunctionKey)!), "end": String(UnicodeScalar(NSEndFunctionKey)!)]
        var flags: NSEvent.ModifierFlags = []
        if parts.contains("cmd") { flags.insert(.command) }
        if parts.contains("ctrl") { flags.insert(.control) }
        if parts.contains("alt") { flags.insert(.option) }
        if parts.contains("shift") { flags.insert(.shift) }
        let key = parts.last ?? ""
        return (names[key] ?? key, flags)
    }
}

enum ShortcutRecordingMode: Hashable {
    case single, sequence(length: Int)
    var length: Int { if case .sequence(let length) = self { return length }; return 1 }
}

struct KeyboardShortcutRecorder: NSViewRepresentable {
    var value: String?
    var mode: ShortcutRecordingMode = .single
    var onChange: (String) -> Void
    func makeNSView(context: Context) -> ShortcutButton {
        let button = ShortcutButton()
        button.bezelStyle = .rounded
        button.target = button; button.action = #selector(ShortcutButton.beginRecording)
        return button
    }
    func updateNSView(_ button: ShortcutButton, context: Context) {
        button.appearance = context.environment.toolPanelTheme.appearance
        button.font = .systemFont(ofSize: ToolPanelMetrics.bodySize)
        button.controlSize = .small
        button.mode = mode
        button.binding = value; button.onChange = onChange
        if !button.recording { button.title = value.map(KeyBindingMap.display) ?? "Record…" }
    }
}

final class ShortcutButton: NSButton {
    var binding: String?
    var onChange: ((String) -> Void)?
    var mode: ShortcutRecordingMode = .single {
        didSet { if oldValue != mode { cancelRecording() } }
    }
    private(set) var recording = false
    private var strokes: [String] = []
    override var acceptsFirstResponder: Bool { true }
    @objc func beginRecording() {
        guard (1...3).contains(mode.length) else { return }
        recording = true
        strokes = []
        title = mode.length == 1 ? "Press shortcut…" : "Stroke 1 of \(mode.length)…"
        window?.makeFirstResponder(self)
        setAccessibilityLabel("Record keyboard shortcut. Press Escape to cancel.")
    }
    override func resignFirstResponder() -> Bool {
        cancelRecording()
        return super.resignFirstResponder()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        capture(event); return true
    }
    override func keyDown(with event: NSEvent) {
        if recording { capture(event) } else { super.keyDown(with: event) }
    }
    func capture(_ event: NSEvent) {
        guard recording, !event.isARepeat else { return }
        if event.keyCode == 53 { cancelRecording(); window?.makeFirstResponder(nil); return }
        guard let stroke = NativeKeyBinding.binding(for: event), !KeyBindingMap.reserved.contains(stroke) else {
            title = "Use Command or Control"
            return
        }
        strokes.append(stroke)
        guard strokes.count == mode.length else {
            title = KeyBindingMap.display(strokes.joined(separator: ",")) + " → Stroke \(strokes.count + 1)"
            return
        }
        let value = strokes.joined(separator: ",")
        binding = value
        cancelRecording()
        onChange?(value)
        window?.makeFirstResponder(nil)
    }
    private func cancelRecording() {
        recording = false
        strokes = []
        title = binding.map(KeyBindingMap.display) ?? "Record…"
    }
}
