import AppKit
import TerminalCore

enum TerminalLocalFileLink {
    private static let locationSuffix = try! NSRegularExpression(pattern: #"(?::[0-9]+(?::[0-9]+)?|#L[0-9]+(?:C[0-9]+)?(?:-L[0-9]+)?)$"#)

    static func isFileReference(_ text: String) -> Bool {
        guard let url = URL(string: text), let scheme = url.scheme else { return true }
        if scheme.lowercased() == "file" { return true }
        if text.hasPrefix("/") || text.hasPrefix("./") || text.hasPrefix("../") || text.hasPrefix("~/") { return true }
        guard !text.contains("://"), let match = locationSuffix.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return false }
        let prefix = text[..<range.lowerBound]
        return prefix.contains(".") || prefix.contains("/")
    }

    static func resolve(_ text: String, cwd: String) -> URL? {
        guard text.utf8.count <= 16_384, text.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        var path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        if path.lowercased().hasPrefix("file:") {
            guard let url = URL(string: path), url.isFileURL,
                  url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
                  url.user == nil, url.password == nil, url.query == nil,
                  url.fragment == nil || url.fragment?.range(of: #"^L[0-9]+(?:C[0-9]+)?(?:-L[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
            path = url.path
        }
        func existing(_ value: String) -> URL? {
            let expanded = value.hasPrefix("~/") ? (value as NSString).expandingTildeInPath : value
            guard expanded.hasPrefix("/") || cwd.hasPrefix("/") else { return nil }
            let file = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent(expanded)
            let normalized = file.standardizedFileURL
            return FileManager.default.fileExists(atPath: normalized.path) ? normalized : nil
        }
        if let file = existing(path) { return file }
        guard let match = locationSuffix.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
              let range = Range(match.range, in: path) else { return nil }
        return existing(String(path[..<range.lowerBound]))
    }
}

@MainActor protocol TerminalApplicationLinkPromptPresenting: AnyObject {
    func present(_ alert: NSAlert, in window: NSWindow,
                 completion: @escaping (NSApplication.ModalResponse) -> Void) -> () -> Void
}

@MainActor final class NativeTerminalApplicationLinkPromptPresenter: TerminalApplicationLinkPromptPresenting {
    func present(_ alert: NSAlert, in window: NSWindow,
                 completion: @escaping (NSApplication.ModalResponse) -> Void) -> () -> Void {
        alert.beginSheetModal(for: window, completionHandler: completion)
        return { [weak window, weak alert] in
            guard let window, let alert, alert.window.sheetParent === window else { return }
            window.endSheet(alert.window, returnCode: .cancel)
        }
    }
}

typealias TerminalTrustedRuleSaveCompletion = @MainActor (Result<Void, Error>) -> Void
typealias TerminalAsyncTrustedRuleWriter = (TerminalTrustedLink, Bool, TerminalInteractionOwner, @escaping TerminalTrustedRuleSaveCompletion) -> Void

@MainActor final class TerminalApplicationLinkHandler {
    private struct Pending {
        let id: UUID
        let owner: TerminalInteractionOwner
        let alert: NSAlert
        let url: URL
        var cancel: (() -> Void)?
        var saving = false
    }
    private let preferences: () -> TerminalPreferences
    private let owner: () -> TerminalInteractionOwner?
    private let opener: (URL) -> Void
    private let presenter: any TerminalApplicationLinkPromptPresenting
    private let synchronousWriter: ((TerminalTrustedLink, Bool, TerminalInteractionOwner) throws -> Void)?
    private let saveTrustedRule: TerminalAsyncTrustedRuleWriter
    private var pending: Pending?

    init(preferences: @escaping () -> TerminalPreferences, owner: @escaping () -> TerminalInteractionOwner?,
         opener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
         presentPrompt: (any TerminalApplicationLinkPromptPresenting)? = nil,
         setTrustedRule: @escaping (TerminalTrustedLink, Bool, TerminalInteractionOwner) throws -> Void) {
        self.preferences = preferences
        self.owner = owner
        self.opener = opener
        presenter = presentPrompt ?? NativeTerminalApplicationLinkPromptPresenter()
        synchronousWriter = setTrustedRule
        saveTrustedRule = { rule, enabled, owner, completion in
            completion(Result { try setTrustedRule(rule, enabled, owner) })
        }
    }

    init(preferences: @escaping () -> TerminalPreferences, owner: @escaping () -> TerminalInteractionOwner?,
         opener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
         presentPrompt: (any TerminalApplicationLinkPromptPresenting)? = nil,
         saveTrustedRule: @escaping TerminalAsyncTrustedRuleWriter) {
        self.preferences = preferences
        self.owner = owner
        self.opener = opener
        presenter = presentPrompt ?? NativeTerminalApplicationLinkPromptPresenter()
        synchronousWriter = nil
        self.saveTrustedRule = saveTrustedRule
    }

    func revoke(_ rule: TerminalTrustedLink, completion: @escaping TerminalTrustedRuleSaveCompletion) {
        guard let capturedOwner = owner() else {
            completion(.failure(TerminalError.invalid("Terminal owner changed"))); return
        }
        saveTrustedRule(rule, false, capturedOwner) { [weak self] result in
            guard self?.owner() == capturedOwner else {
                completion(.failure(TerminalError.invalid("Terminal owner changed"))); return
            }
            completion(result)
        }
    }

    func requestOpen(_ url: URL, in window: NSWindow) {
        cancelIfOwnerChanged()
        guard let capturedOwner = owner(), capturedOwner.windowID == ObjectIdentifier(window) else { return }
        let decision = preferences().linkDecision(for: url)
        guard owner() == capturedOwner else { return }
        switch decision {
        case .deny: return
        case .open:
            openIfAllowed(url, owner: capturedOwner)
        case .ask:
            guard pending == nil, window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Open Link in App?"
            let scheme = url.scheme?.lowercased() ?? ""
            let origin = scheme + ":" + (url.host.map { "//" + $0.lowercased() } ?? "")
                + (url.port.map { ":" + String($0) } ?? "")
            alert.informativeText = "Open an application for “" + origin + "”?"
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Always Open")
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
            let id = UUID()
            pending = Pending(id: id, owner: capturedOwner, alert: alert, url: url)
            let cancel = presenter.present(alert, in: window) { [weak self] response in
                self?.complete(id: id, url: url, owner: capturedOwner, response: response)
            }
            if pending?.id == id { pending?.cancel = cancel }
        }
    }

    func preferencesDidChange() {
        guard let request = pending else { return }
        if owner() != request.owner || preferences().linkDecision(for: request.url) == .deny { cancelPending() }
    }

    func cancelIfOwnerChanged() {
        if let pending, owner() != pending.owner { cancelPending() }
    }

    func cancelPending() {
        let request = pending
        pending = nil
        withExtendedLifetime(request) { request?.cancel?() }
    }

    @discardableResult
    func revoke(_ rule: TerminalTrustedLink) -> Bool {
        guard let capturedOwner = owner(), let synchronousWriter else { return false }
        do {
            try synchronousWriter(rule, false, capturedOwner)
            return owner() == capturedOwner
        } catch { return false }
    }

    private func complete(id: UUID, url: URL, owner capturedOwner: TerminalInteractionOwner,
                          response: NSApplication.ModalResponse) {
        guard let request = pending, request.id == id, !request.saving else { return }
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn,
              owner() == capturedOwner, preferences().linkDecision(for: url) != .deny,
              owner() == capturedOwner else { pending = nil; return }
        if response == .alertFirstButtonReturn {
            pending = nil
            openIfAllowed(url, owner: capturedOwner, approvedAsk: true)
            return
        }
        guard let scheme = url.scheme?.lowercased() else { pending = nil; return }
        let rule = TerminalTrustedLink(scheme: scheme, host: url.host?.lowercased(), port: url.port)
        var validation = TerminalPreferences()
        validation.trustedLinks = [rule]
        do { try validation.validate() }
        catch { pending = nil; return }
        guard owner() == capturedOwner else { pending = nil; return }
        pending?.saving = true
        pending?.cancel = nil
        saveTrustedRule(rule, true, capturedOwner) { [weak self] result in
            guard let self, self.pending?.id == id, self.pending?.saving == true else { return }
            self.pending = nil
            guard case .success = result else { return }
            self.openIfAllowed(url, owner: capturedOwner, approvedAsk: true)
        }
    }

    private func openIfAllowed(_ url: URL, owner capturedOwner: TerminalInteractionOwner, approvedAsk: Bool = false) {
        guard owner() == capturedOwner else { return }
        let currentDecision = preferences().linkDecision(for: url)
        guard currentDecision == .open || (approvedAsk && currentDecision == .ask),
              owner() == capturedOwner else { return }
        opener(url)
    }
}
