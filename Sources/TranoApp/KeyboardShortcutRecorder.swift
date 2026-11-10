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
        let parts = binding.split(separator: "+").map(String.init)
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

struct KeyboardShortcutRecorder: NSViewRepresentable {
    var value: String?
    var onChange: (String) -> Void
    func makeNSView(context: Context) -> ShortcutButton {
        let button = ShortcutButton()
        button.bezelStyle = .rounded
        button.target = button; button.action = #selector(ShortcutButton.beginRecording)
        return button
    }
    func updateNSView(_ button: ShortcutButton, context: Context) {
        button.binding = value; button.onChange = onChange
        if !button.recording { button.title = value.map(KeyBindingMap.display) ?? "Record…" }
    }
}

final class ShortcutButton: NSButton {
    var binding: String?
    var onChange: ((String) -> Void)?
    private(set) var recording = false
    override var acceptsFirstResponder: Bool { true }
    @objc func beginRecording() {
        recording = true; title = "Press shortcut…"; window?.makeFirstResponder(self)
        setAccessibilityLabel("Record keyboard shortcut. Press Escape to cancel.")
    }
    override func resignFirstResponder() -> Bool {
        recording = false; title = binding.map(KeyBindingMap.display) ?? "Record…"
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
        if event.keyCode == 53 { window?.makeFirstResponder(nil); return }
        guard let binding = NativeKeyBinding.binding(for: event) else { NSSound.beep(); return }
        recording = false; onChange?(binding); window?.makeFirstResponder(nil)
    }
}
