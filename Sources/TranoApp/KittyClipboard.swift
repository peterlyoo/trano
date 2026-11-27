import AppKit
import SwiftTerm
import UniformTypeIdentifiers

@MainActor final class KittyClipboardHost {
    private weak var view: TranoView?
    private let pasteboard: NSPasteboard
    private let permission: ((KittyClipboardPermissionRequest) -> KittyClipboardPermissionResult)?
    private let availability: (() -> Bool)?
    private var active = true

    init(view: TranoView, pasteboard: NSPasteboard = .general,
         permission: ((KittyClipboardPermissionRequest) -> KittyClipboardPermissionResult)? = nil,
         availability: (() -> Bool)? = nil) {
        self.view = view
        self.pasteboard = pasteboard
        self.permission = permission
        self.availability = availability
    }

    private var available: Bool {
        guard active else { return false }
        if let availability { return availability() }
        guard let view, let window = view.window, window.isVisible, !view.isHiddenOrHasHiddenAncestor,
              let store = view.store, store.terminalViews[view.paneID] === view,
              store.focusedID == view.paneID, !view.inputBlocked,
              store.sessions.contains(where: { $0.id == view.paneID && $0.alive }) else { return false }
        return true
    }

    func capabilities(source: TerminalView) -> KittyClipboardCapabilities {
        source === view && active ? .standard : []
    }

    func revokePermissions(in terminal: TerminalView) {
        active = false
        terminal.refreshKittyClipboardCapabilities()
        active = true
        terminal.refreshKittyClipboardCapabilities()
    }

    func mimeTypes(location: KittyClipboardLocation) -> [String]? {
        guard location == .standard else { return nil }
        guard available else { return [] }
        var names: [String] = []
        for type in pasteboard.types ?? [] {
            guard let mime = Self.mime(for: type), !names.contains(mime) else { continue }
            names.append(mime)
        }
        return names
    }

    func read(location: KittyClipboardLocation, mimeType: String) -> KittyClipboardReadResult {
        guard location == .standard else { return .unavailable }
        guard available else { return .denied }
        guard let type = pasteboard.types?.first(where: { Self.mime(for: $0)?.caseInsensitiveCompare(mimeType) == .orderedSame }),
              let data = pasteboard.data(forType: type) else { return .unavailable }
        return .data(data)
    }

    func write(location: KittyClipboardLocation, content: KittyClipboardWriteContent) -> KittyClipboardWriteResult {
        guard location == .standard else { return .unsupported }
        guard available else { return .denied }
        let representations = content.flattened
        let types = representations.compactMap { Self.type(for: $0.mimeType) }
        guard types.count == representations.count else { return .invalidData }
        var declared = Set(types)
        let item = NSPasteboardItem()
        for (representation, type) in zip(representations, types) {
            guard item.setData(representation.data, forType: type) else { return .ioError }
            if type.rawValue.hasPrefix(Self.exactMIMEPrefix),
               let canonical = UTType(mimeType: representation.mimeType),
               declared.insert(NSPasteboard.PasteboardType(canonical.identifier)).inserted {
                guard item.setData(representation.data, forType: NSPasteboard.PasteboardType(canonical.identifier)) else { return .ioError }
            }
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item]) ? .success : .ioError
    }

    func requestPermission(_ request: KittyClipboardPermissionRequest) -> KittyClipboardPermissionResult {
        guard request.location == .standard, available else { return .deny }
        let clientPID = view?.process.shellPid
        let pane = view?.paneID
        let backendPID = view.flatMap { view in view.store?.sessions.first { $0.id == view.paneID }?.pid }
        let result = decidePermission(request)
        guard available, view?.process.shellPid == clientPID, view?.paneID == pane,
              view.flatMap({ view in view.store?.sessions.first { $0.id == view.paneID }?.pid }) == backendPID else { return .deny }
        return result
    }

    private func decidePermission(_ request: KittyClipboardPermissionRequest) -> KittyClipboardPermissionResult {
        if let permission { return permission(request) }
        if request.direction == .write { return .allow(rememberPassword: false) }
        guard view?.window?.attachedSheet == nil, NSApp.modalWindow == nil else { return .deny }
        let alert = NSAlert()
        alert.messageText = "Allow Clipboard Read?"
        let name = String(request.name.filter { !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }.prefix(80))
        alert.informativeText = name.isEmpty ? "A program in this terminal wants to read the clipboard." : "“\(name)” wants to read the clipboard."
        alert.addButton(withTitle: "Deny")
        alert.addButton(withTitle: "Allow Once")
        if request.canRememberPassword { alert.addButton(withTitle: "Allow for Session") }
        switch alert.runModal() {
        case .alertSecondButtonReturn: return .allow(rememberPassword: false)
        case .alertThirdButtonReturn where request.canRememberPassword: return .allow(rememberPassword: true)
        default: return .deny
        }
    }

    private static let exactMIMEPrefix = "dev.trano.clipboard.mime."

    private static func mime(for type: NSPasteboard.PasteboardType) -> String? {
        if type.rawValue.hasPrefix(exactMIMEPrefix) {
            let encoded = Array(type.rawValue.dropFirst(exactMIMEPrefix.count).utf8)
            guard !encoded.isEmpty, encoded.count.isMultiple(of: 2) else { return nil }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(encoded.count / 2)
            for index in stride(from: 0, to: encoded.count, by: 2) {
                guard let byte = UInt8(String(decoding: encoded[index..<index + 2], as: UTF8.self), radix: 16) else { return nil }
                bytes.append(byte)
            }
            guard let decoded = String(bytes: bytes, encoding: .utf8), validMIME(decoded) else { return nil }
            return decoded.lowercased()
        }
        if type == .string { return "text/plain" }
        let raw = UTType(type.rawValue)?.preferredMIMEType ?? type.rawValue
        let bare = String(raw.prefix { $0 != ";" }).trimmingCharacters(in: .whitespaces).lowercased()
        return validMIME(bare) ? bare : nil
    }

    private static func type(for mime: String) -> NSPasteboard.PasteboardType? {
        guard validMIME(mime) else { return nil }
        if mime.caseInsensitiveCompare("text/plain") == .orderedSame { return .string }
        if let type = UTType(mimeType: mime),
           Self.mime(for: NSPasteboard.PasteboardType(type.identifier))?.caseInsensitiveCompare(mime) == .orderedSame {
            return NSPasteboard.PasteboardType(type.identifier)
        }
        let encoded = mime.lowercased().utf8.map { String(format: "%02x", $0) }.joined()
        return NSPasteboard.PasteboardType(exactMIMEPrefix + encoded)
    }

    private static func validMIME(_ mime: String) -> Bool {
        let parts = mime.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~")
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }
    }
}

extension TerminalBridge {
    func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities {
        kittyClipboard.capabilities(source: source)
    }
    func kittyClipboardAvailableMimeTypes(source: TerminalView, location: KittyClipboardLocation) -> [String]? {
        kittyClipboard.mimeTypes(location: location)
    }
    func kittyClipboardRead(source: TerminalView, location: KittyClipboardLocation, mimeType: String) -> KittyClipboardReadResult? {
        kittyClipboard.read(location: location, mimeType: mimeType)
    }
    func kittyClipboardWrite(source: TerminalView, location: KittyClipboardLocation, content: KittyClipboardWriteContent) -> KittyClipboardWriteResult {
        kittyClipboard.write(location: location, content: content)
    }
    func kittyClipboardRequestPermission(source: TerminalView, request: KittyClipboardPermissionRequest) -> KittyClipboardPermissionResult {
        kittyClipboard.requestPermission(request)
    }
}

extension TranoView {
    static func makeClipboardTerminal(frame: NSRect) -> TranoView {
        var options = TerminalOptions.default
        options.kittyClipboardPolicy = .all
        return TranoView(frame: frame, options: options)
    }
}

enum NativeKittyPasteGate {
    private static let key = "dev.trano.kitty-native-paste"
    private final class Attempt {
        let owner: ObjectIdentifier
        var eventSent = false
        init(owner: ObjectIdentifier) { self.owner = owner }
    }

    @MainActor static func perform(owner: ObjectIdentifier, nativePaste: () -> Void) -> Bool {
        let previous = Thread.current.threadDictionary[key]
        let attempt = Attempt(owner: owner)
        Thread.current.threadDictionary[key] = attempt
        defer {
            if let previous { Thread.current.threadDictionary[key] = previous }
            else { Thread.current.threadDictionary.removeObject(forKey: key) }
        }
        nativePaste()
        return attempt.eventSent
    }

    // Only sends produced synchronously by this paste may bypass Trano's safe fallback.
    static func suppressFallback(owner: ObjectIdentifier, source: Terminal, data: ArraySlice<UInt8>) -> Bool {
        guard let attempt = Thread.current.threadDictionary[key] as? Attempt, attempt.owner == owner else { return false }
        if data.starts(with: Array("\u{1b}]5522;".utf8)) {
            if source.kittyPasteEventsEnabled, data.starts(with: Array("\u{1b}]5522;type=read:status=OK".utf8)) {
                attempt.eventSent = true
            }
            return false
        }
        return true
    }
}
