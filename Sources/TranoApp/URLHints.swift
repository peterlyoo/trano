import AppKit
import ObjectiveC
import SwiftTerm
import TerminalCore

@MainActor final class URLHintsController: NSObject {
    weak var view: TranoView?
    private(set) var isActive = false
    private(set) var matches: [URLHintMatch] = []
    private(set) var prefix = ""
    private(set) var overlay: NSView?
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    private var captured: TerminalContentSnapshot?
    private var capturedBounds = NSRect.zero
    private var capturedGrid = NSSize.zero
    private var capturedPane = ""
    private var capturedClient: pid_t = 0
    private weak var capturedWindow: NSWindow?
    private var cellSize = NSSize.zero
    private var timer: Timer?
    private var pointerMonitor: Any?
    private var windowObserver: NSObjectProtocol?

    init(view: TranoView) { self.view = view }
    deinit {
        timer?.invalidate()
        if let pointerMonitor { MainActor.assumeIsolated { NSEvent.removeMonitor(pointerMonitor) } }
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
    }

    @discardableResult func start() -> Bool {
        dismiss()
        guard let view, canPresent, let snapshot = view.terminalContentSnapshot(region: .viewport),
              snapshot.inputState.dimensions.cols > 0, snapshot.inputState.dimensions.rows > 0 else { return false }
        let rows = snapshot.rows.enumerated().map { index, row in
            URLHintRow(row: index, cells: row.cells.map { URLHintCell(text: $0.text, width: $0.width) }, isWrapped: row.isWrapped)
        }
        matches = URLHintMatcher.matches(rows: rows)
        guard !matches.isEmpty else { return false }
        captured = snapshot
        capturedBounds = view.bounds
        capturedGrid = view.getOptimalFrameSize().size
        capturedPane = view.paneID
        capturedClient = view.process.shellPid
        capturedWindow = view.window
        var scrollerWidth: CGFloat = 0
        if let scroller = view.subviews.compactMap({ $0 as? NSScroller }).first,
           !scroller.isHidden, scroller.scrollerStyle == .legacy { scrollerWidth = scroller.frame.width }
        cellSize = NSSize(width: (capturedGrid.width - scrollerWidth) / CGFloat(snapshot.inputState.dimensions.cols),
                          height: capturedGrid.height / CGFloat(snapshot.inputState.dimensions.rows))
        guard cellSize.width > 0, cellSize.height > 0 else { matches = []; return false }
        let overlay = URLHintsOverlay(frame: view.bounds)
        overlay.identifier = NSUserInterfaceItemIdentifier("url-hints-overlay")
        overlay.autoresizingMask = [.width, .height]
        overlay.setAccessibilityLabel("URL Hints")
        self.overlay = overlay
        for match in matches {
            guard let span = match.spans.first else { continue }
            let button = URLHintButton(label: match.label, controller: self)
            let width = max(20, button.attributedTitle.size().width + 8)
            let height = min(cellSize.height, view.bounds.height)
            button.frame = NSRect(x: min(max(0, CGFloat(span.columns.lowerBound) * cellSize.width), max(0, view.bounds.width - width)),
                                  y: max(0, view.bounds.height - CGFloat(span.row + 1) * cellSize.height), width: width, height: height).integral.intersection(view.bounds)
            button.setAccessibilityLabel(match.label + ": " + match.url)
            overlay.addSubview(button)
        }
        view.addSubview(overlay, positioned: .above, relativeTo: nil)
        isActive = true
        pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return event }
                if event.window !== self.capturedWindow || event.type == .scrollWheel || event.type == .rightMouseDown { self.dismiss() }
                return event
            }
        }
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: view.window, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshValidity() } }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        return true
    }

    func dismiss() {
        timer?.invalidate(); timer = nil
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor); self.pointerMonitor = nil }
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver); self.windowObserver = nil }
        overlay?.removeFromSuperview(); overlay = nil
        captured = nil; matches = []; prefix = ""; isActive = false
    }

    func handle(_ event: NSEvent) -> Bool {
        guard isActive else { return false }
        guard event.window === capturedWindow else { dismiss(); return false }
        guard canPresent else { dismiss(); return false }
        guard valid else { dismiss(); return event.type == .keyDown }
        if event.type == .leftMouseDown {
            guard let view else { dismiss(); return false }
            let point = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(point) else { dismiss(); return false }
            let overlayPoint = overlay?.convert(point, from: view) ?? point
            if let button = overlay?.subviews.compactMap({ $0 as? URLHintButton }).first(where: {
                !$0.isHidden && $0.frame.contains(overlayPoint)
            }) { choose(button.label) }
            else if let match = matches.first(where: { match in
                match.label.hasPrefix(prefix) && match.spans.contains { rect(for: $0).contains(point) }
            }) { choose(match.label) }
            else { dismiss() }
            return true
        }
        guard event.type == .keyDown else { return false }
        if event.keyCode == 53 { dismiss(); return true }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if !modifiers.isEmpty {
            let configured = try? TerminalKeySequenceMap(overrides: view?.store?.state.settings.keyBindings ?? [:])
            let binding = NativeKeyBinding.binding(for: event)
            let toggles = binding.flatMap { configured?.singles.action(for: $0) }?.rawValue == "terminal.url_hints"
            if toggles && event.isARepeat { return true }
            dismiss()
            return toggles
        }
        if event.isARepeat { return true }
        if [51, 117].contains(event.keyCode) {
            if !prefix.isEmpty { prefix.removeLast(); updateLabels() }
            return true
        }
        if [36, 76, 49].contains(event.keyCode) {
            let visible = matches.filter { $0.label.hasPrefix(prefix) }
            if visible.count == 1 { choose(visible[0].label) }
            return true
        }
        let characters = (event.charactersIgnoringModifiers ?? event.characters ?? "").lowercased()
        let latin = characters.count == 1 && characters.unicodeScalars.allSatisfy { (97...122).contains($0.value) }
        guard let text = latin ? characters : Self.physicalLetters[event.keyCode] else { return true }
        let next = prefix + text
        guard matches.contains(where: { $0.label.hasPrefix(next) }) else { return true }
        prefix = next
        if let exact = matches.first(where: { $0.label == prefix }) { choose(exact.label) }
        else { updateLabels() }
        return true
    }

    func refreshValidity() { if isActive && !valid { dismiss() } }

    fileprivate func choose(_ label: String) {
        guard valid, let match = matches.first(where: { $0.label == label }),
              let url = URL(string: match.url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else { dismiss(); return }
        let action = openURL
        dismiss()
        action(url)
    }

    private var canPresent: Bool {
        guard let view, let window = view.window, window.isVisible, !view.isHiddenOrHasHiddenAncestor,
              !view.bounds.isEmpty, !view.hasMarkedText(),
              (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true,
              window.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
        guard let store = view.store else { return true }
        return store.focusedID == view.paneID && store.terminalViews[view.paneID] === view &&
            !store.loading && store.picker == nil && store.decisionPaneID == nil && store.followUpPaneID == nil &&
            !store.showSettings && !store.showVoice && !store.showRemoteHosts && !store.showAccounts &&
            !store.showExtensions && store.remotePathRequest == nil
    }

    private var valid: Bool {
        guard isActive, canPresent, let view, let captured else { return false }
        return view.window === capturedWindow && view.paneID == capturedPane && view.process.shellPid == capturedClient &&
            view.bounds == capturedBounds && view.getOptimalFrameSize().size == capturedGrid &&
            view.terminalContentSnapshot(region: .viewport) == captured
    }

    private func rect(for span: URLHintSpan) -> NSRect {
        NSRect(x: CGFloat(span.columns.lowerBound) * cellSize.width,
               y: capturedBounds.height - CGFloat(span.row + 1) * cellSize.height,
               width: CGFloat(span.columns.count) * cellSize.width, height: cellSize.height)
    }

    private func updateLabels() {
        for case let button as URLHintButton in overlay?.subviews ?? [] { button.isHidden = !button.label.hasPrefix(prefix) }
    }

    private static let physicalLetters: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b",
        12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 31: "o", 32: "u", 34: "i", 35: "p",
        37: "l", 38: "j", 40: "k", 45: "n", 46: "m"
    ]
}

@MainActor private final class URLHintsOverlay: NSView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
}

@MainActor private final class URLHintButton: NSButton {
    let label: String
    weak var controller: URLHintsController?
    init(label: String, controller: URLHintsController) {
        self.label = label; self.controller = controller
        super.init(frame: .zero)
        title = label; isBordered = false
        font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        attributedTitle = NSAttributedString(string: label, attributes: [.font: font!, .foregroundColor: NSColor.black])
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.96, green: 0.83, blue: 0.4, alpha: 1).cgColor
        layer?.cornerRadius = 2
        target = self; action = #selector(activate)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func activate() { controller?.choose(label) }
}

@MainActor private var urlHintsAssociationKey: UInt8 = 0

extension TranoView {
    var urlHints: URLHintsController {
        if let controller = objc_getAssociatedObject(self, &urlHintsAssociationKey) as? URLHintsController { return controller }
        let controller = URLHintsController(view: self)
        objc_setAssociatedObject(self, &urlHintsAssociationKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return controller
    }
}
