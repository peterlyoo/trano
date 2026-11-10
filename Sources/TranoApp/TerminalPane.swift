import AppKit
import SwiftUI
import SwiftTerm
import TerminalCore

extension NSColor {
    convenience init(hex: String) {
        let text = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(text, radix: 16) ?? 0x0B0B0C
        self.init(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
    }
}

@MainActor final class TranoView: LocalProcessTerminalView {
    var paneID = ""
    weak var store: AppStore?
    var started = false
    private var attachedPID: Int32?
    private var pendingReconnect = false

    private var coordinator: PaneDelegate?
    private var terminalBridge: TerminalBridge?
    private var historyLimit: Int?
    private var configuredSettings: TerminalSettings?

    func configure(_ settings: TerminalSettings) {
        guard configuredSettings != settings else { return }
        configuredSettings = settings
        let baseFont = NSFont(name: settings.fontName, size: settings.fontSize) ?? NSFont.monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
        let desired: NSFont
        if let fallback = NSFont(name: settings.appearance.fallbackFontName, size: settings.fontSize) {
            let descriptor = baseFont.fontDescriptor.addingAttributes([.cascadeList: [fallback.fontDescriptor]])
            desired = NSFont(descriptor: descriptor, size: settings.fontSize) ?? baseFont
        } else { desired = baseFont }
        if font != desired { font = desired }
        optionAsMetaKey = settings.optionAsMeta ?? false
        let appearance = (try? settings.appearance.validate()) != nil ? settings.appearance : AppearancePreferences()
        if lineSpacing != appearance.lineSpacing { lineSpacing = appearance.lineSpacing }
        nativeBackgroundColor = NSColor(hex: settings.background).withAlphaComponent(appearance.backgroundImagePath == nil ? appearance.opacity : 0)
        nativeForegroundColor = NSColor(hex: appearance.foreground)
        caretColor = NSColor(hex: appearance.cursor)
        selectedTextBackgroundColor = NSColor(hex: appearance.selection)
        selectedTextForegroundColor = NSColor(hex: appearance.foreground)
        let blink = appearance.cursorBlink && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        switch appearance.cursorStyle {
        case .block: setCursorStyle(blink ? .blinkBlock : .steadyBlock)
        case .beam: setCursorStyle(blink ? .blinkBar : .steadyBar)
        case .underline: setCursorStyle(blink ? .blinkUnderline : .steadyUnderline)
        }
        installColors(appearance.ansiColors.map { hex in
            let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
            return SwiftTerm.Color(red8: UInt16((value >> 16) & 255), green8: UInt16((value >> 8) & 255), blue8: UInt16(value & 255))
        })
        if historyLimit != settings.scrollbackLines { changeScrollback(settings.scrollbackLines); historyLimit = settings.scrollbackLines }
        if terminalBridge == nil { let bridge = TerminalBridge(view: self); terminalBridge = bridge; terminalDelegate = bridge }
    }

    override func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }

    override func paste(_ sender: Any) {
        let clipboard = NSPasteboard.general
        if let text = clipboard.string(forType: .string), !text.isEmpty { pasteDraft(text); return }
        if let data = clipboard.data(forType: .png) ?? clipboard.data(forType: .tiff) {
            guard data.count <= 20 * 1024 * 1024, let bitmap = NSBitmapImageRep(data: data),
                  bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
                  bitmap.pixelsWide <= 8192, bitmap.pixelsHigh <= 8192,
                  bitmap.pixelsWide * bitmap.pixelsHigh <= 16_777_216,
                  let png = bitmap.representation(using: .png, properties: [:]), let store else {
                store?.message = "Image is unavailable or too large (20 MiB / 16 megapixels maximum)."; return
            }
            store.insertImage(png, paneID: paneID)
            return
        }
        guard let text = clipboard.string(forType: .string) else { super.paste(sender); return }
        pasteDraft(text)
    }

    func pasteDraft(_ text: String) {
        guard text.utf8.count <= 1_048_576 else { store?.message = "Paste is limited to 1 MiB."; return }
        if text.contains("\n") || text.contains("\r") {
            guard terminalInputStateSnapshot()?.bracketedPasteMode == true else {
                store?.message = "This program has not enabled bracketed paste. Paste one line at a time to avoid executing multiline input."; return
            }
            let alert = NSAlert()
            alert.messageText = "Paste multiple lines?"
            alert.informativeText = "Review the input before inserting it. Press Return in the terminal when you are ready to run it."
            let preview = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
            preview.string = text
            preview.isEditable = false
            preview.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            let scroll = NSScrollView(frame: preview.frame)
            scroll.documentView = preview; scroll.hasVerticalScroller = true
            alert.accessoryView = scroll
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Paste")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            guard terminalInputStateSnapshot()?.bracketedPasteMode == true else { store?.message = "The receiving program changed. Paste cancelled."; return }
        }
        pasteText(text)
    }

    func connect(store: AppStore, id: String) {
        guard !started else { return }
        started = true
        self.store = store
        paneID = id
        attachedPID = store.sessions.first { $0.id == id }?.pid
        registerForDraggedTypes([.fileURL])
        coordinator = PaneDelegate(store: store)
        processDelegate = coordinator
        configure(store.state.settings.resolvedAppearance(for: id))
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TMUX")
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TRANO_SESSION"] = id
        environment["TRANO_DATA_DIR"] = store.runtime.root.path
        do {
            let args = try store.runtime.attachArguments(id)
            startProcess(executable: store.runtime.executable, args: args, environment: environment.map { "\($0.key)=\($0.value)" })
            if store.focusedID == id && window?.isKeyWindow == true { window?.makeFirstResponder(self) }
        } catch { feed(text: "\r\n\(error.localizedDescription)\r\n") }
    }

    func synchronize(store: AppStore, id: String) {
        configure(store.state.settings.resolvedAppearance(for: id))
        guard let pane = store.sessions.first(where: { $0.id == id }), pane.alive else { return }
        if started && attachedPID == pane.pid && process.running { return }
        if process.running || process.windingDown {
            pendingReconnect = true
            terminate()
            return
        }
        started = false
        connect(store: store, id: id)
    }

    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        started = false
        super.processTerminated(source, exitCode: exitCode)
        if pendingReconnect, let store, store.terminalViews[paneID] === self {
            pendingReconnect = false
            synchronize(store: store, id: paneID)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard store?.sessions.first(where: { $0.id == paneID })?.host == "local" else { return [] }
        return sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard store?.sessions.first(where: { $0.id == paneID })?.host == "local",
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
        do { pasteText(try PathInsertion.text(paths: urls.map(\.path))); return true }
        catch { store?.message = error.localizedDescription; return false }
    }

}

@MainActor final class TerminalBridge: TerminalViewDelegate {
    weak var view: TranoView?
    init(view: TranoView) { self.view = view }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { view?.send(source: source, data: data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { view?.sizeChanged(source: source, newCols: newCols, newRows: newRows) }
    func setTerminalTitle(source: TerminalView, title: String) { view?.setTerminalTitle(source: source, title: title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { view?.hostCurrentDirectoryUpdate(source: source, directory: directory) }
    func scrolled(source: TerminalView, position: Double) { view?.scrolled(source: source, position: position) }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) { view?.rangeChanged(source: source, startY: startY, endY: endY) }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { view?.requestOpenLink(source: source, link: link, params: params) }
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
}

@MainActor final class PaneDelegate: LocalProcessTerminalViewDelegate {
    weak var store: AppStore?
    init(store: AppStore) { self.store = store }
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { store?.refresh() }
    func processFailedToStart(source: TerminalView, error: LocalProcessError) { store?.message = String(describing: error) }
}

struct TerminalPane: NSViewRepresentable {
    @ObservedObject var store: AppStore
    let id: String

    func makeNSView(context: Context) -> TranoView {
        if let existing = store.terminalViews[id] { return existing }
        let terminal = TranoView(frame: .zero)
        terminal.paneID = id
        terminal.store = store
        terminal.configure(store.state.settings.resolvedAppearance(for: id))
        terminal.suspendsRenderingWhenNotVisible = !CommandLine.arguments.contains("--snapshot") && !CommandLine.arguments.contains("--benchmark-readiness")
        terminal.setAccessibilityLabel("Terminal · " + (store.sessions.first { $0.id == id }?.title ?? "Shell"))
        store.terminalViews[id] = terminal
        DispatchQueue.main.async { terminal.connect(store: store, id: id) }
        return terminal
    }

    func updateNSView(_ view: TranoView, context: Context) {
        view.setAccessibilityLabel("Terminal · " + (store.sessions.first { $0.id == id }?.title ?? "Shell"))
        view.synchronize(store: store, id: id)
    }
}
