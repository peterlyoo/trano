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

@MainActor final class TranoView: LocalProcessTerminalView, TerminalInteractionInvalidating {
    var paneID = "" { didSet { if paneID != oldValue { cancelTerminalInputRelay(); invalidateTerminalInteractions() } } }
    weak var store: AppStore? { didSet { if store !== oldValue { cancelTerminalInputRelay(); invalidateTerminalInteractions() } } }
    var started = false
    private var attachedPID: Int32?
    private var pendingReconnect = false
    private var inputRelay: TerminalInputRelay?
    private var inputRelayBinding: TerminalInputBinding?
    private var inputRecoveryPending = false
    private var inputRelayGeneration = UUID()
    var interruptHandoffProbe: ((TerminalShellHandoffRequest, @escaping (TerminalShellHandoffStatus) -> Void) -> Void)?
    var interruptHandoffReplay: ((NSEvent) -> Void)?
    var interruptHandoffApplicationActive: () -> Bool = { NSApp.isActive }
    let interruptInputAdmission = TerminalInterruptInputAdmission()
    lazy var interruptHandoff: TerminalInterruptHandoff = {
        let handoff = TerminalInterruptHandoff()
        handoff.capture = { [weak self] in self?.captureInterruptHandoff() }
        handoff.replay = { [weak self] event in
            guard let self else { return }
            if let replay = self.interruptHandoffReplay { replay(event) }
            else if event.type == .keyUp { self.keyUp(with: event) }
            else { self.keyDown(with: event) }
        }
        handoff.report = { [weak self] message in self?.store?.message = message }
        return handoff
    }()
    private var historyWheel = TerminalHistoryWheelAccumulator()
    private var pendingHistoryLines = 0
    private var historyScrollWork: DispatchWorkItem?
    private var historyScrollInFlight = false
    private var historyInputBinding: (owner: TerminalInteractionOwner, lease: TerminalInteractionLease, input: TerminalInputBinding)?
    private var historyReturnInFlight = false
    private var pendingHistoryInputs: [() -> Void] = []
    private var historyInputOverflowed = false
    static let historyInputLimit = 256
    var terminalContextAction: ((ActionID) -> Bool)?
    var terminalContextSupports: ((ActionID) -> Bool)?

    var terminalInteractionPasteboard: NSPasteboard?
    var terminalInteractionOpener: ((URL) -> Void)?
    var terminalPastePromptPresenter: (any TerminalDraftPastePromptPresenting)?
    var terminalLinkPromptPresenter: (any TerminalApplicationLinkPromptPresenting)?
    private var interactionGeneration = UUID()
    private var currentInteractionLease: TerminalInteractionLease?
    private var interactionWindowObservers: [NSObjectProtocol] = []
    private var selectionController: TerminalSelectionController?
    private var linkHandler: TerminalApplicationLinkHandler?
    private struct MouseSelectionAttempt {
        let owner: TerminalInteractionOwner
        let before: String?
        let press: NSPoint
        var dragged = false
        var expected: String?
        let multipleClick: Bool
    }
    private var mouseSelectionAttempt: MouseSelectionAttempt?

    func interactionOwner() -> TerminalInteractionOwner? {
        guard let store, store.terminalViews[paneID] === self, let window,
              window.isVisible, !window.isMiniaturized, !isHiddenOrHasHiddenAncestor,
              let pane = store.sessions.first(where: { $0.id == paneID }),
              !inputBlocked, !hasMarkedText() else {
            if currentInteractionLease != nil { invalidateTerminalInteractions() }
            return nil
        }
        let windowID = ObjectIdentifier(window)
        if let lease = currentInteractionLease,
           lease.owner.paneID == paneID, lease.owner.windowID == windowID,
           lease.sessionPID == pane.pid, lease.hostID == pane.remote?.hostID, lease.isValid { return lease.owner }
        invalidateTerminalInteractions()
        let owner = TerminalInteractionOwner(paneID: paneID, windowID: windowID, generation: interactionGeneration)
        currentInteractionLease = TerminalInteractionLease(owner: owner, sessionPID: pane.pid, hostID: pane.remote?.hostID)
        return owner
    }

    func interactionLease(for owner: TerminalInteractionOwner) -> TerminalInteractionLease? {
        guard interactionOwner() == owner else { return nil }
        return currentInteractionLease
    }

    func retainsInterruptInput(owner: TerminalInteractionOwner, lease: TerminalInteractionLease) -> Bool {
        currentInteractionLease === lease && lease.isValid && interactionGeneration == owner.generation
    }

    func invalidateTerminalInteractions() {
        interruptHandoff.cancel()
        cancelHistoryWheel()
        if let binding = historyInputBinding, let store {
            let runtime = store.runtime, id = binding.owner.paneID, pid = binding.lease.sessionPID
            store.queue.async { _ = try? runtime.cancelTerminalHistory(id, expectedPID: pid) }
        }
        historyInputBinding = nil
        historyReturnInFlight = false
        historyScrollInFlight = false
        historyInputOverflowed = false
        pendingHistoryInputs.removeAll()
        currentInteractionLease?.invalidate()
        currentInteractionLease = nil
        interactionGeneration = UUID()
        mouseSelectionAttempt = nil
        selectionController?.ownerDidChange()
        linkHandler?.cancelPending()
    }

    func terminalInteractionPreferencesDidChange() {
        selectionController?.preferencesDidChange()
        linkHandler?.preferencesDidChange()
    }

    private var interactionPreferences: TerminalPreferences {
        store?.terminalPreferences ?? configuredTerminalPreferences ?? TerminalPreferences()
    }

    private func terminalSelectionController() -> TerminalSelectionController {
        if let selectionController { return selectionController }
        let controller = TerminalSelectionController(pasteboard: terminalInteractionPasteboard ?? .general,
            preferences: { [weak self] in self?.interactionPreferences ?? TerminalPreferences() },
            owner: { [weak self] in self?.interactionOwner() })
        selectionController = controller
        return controller
    }

    private func terminalLinkHandler() -> TerminalApplicationLinkHandler {
        if let linkHandler { return linkHandler }
        let handler = TerminalApplicationLinkHandler(
            preferences: { [weak self] in self?.interactionPreferences ?? TerminalPreferences() },
            owner: { [weak self] in self?.interactionOwner() },
            opener: { [weak self] url in
                guard let self else { return }
                if let opener = self.terminalInteractionOpener { opener(url) }
                else if !NSWorkspace.shared.open(url) { self.store?.message = "The link could not be opened by its default application." }
            }, presentPrompt: terminalLinkPromptPresenter,
            saveTrustedRule: { [weak self] rule, enabled, owner, completion in
                guard let store = self?.store else { completion(.failure(TerminalError.invalid("Terminal owner changed"))); return }
                store.saveTerminalTrustedRule(rule, enabled: enabled, owner: owner, completion: completion)
            })
        linkHandler = handler
        return handler
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window, newWindow !== window, window.firstResponder === self,
           store?.focusedID == paneID {
            store?.restoreTerminalFocus(returningTo: window)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in interactionWindowObservers { NotificationCenter.default.removeObserver(observer) }
        interactionWindowObservers.removeAll()
        invalidateTerminalInteractions()
        guard let window else { return }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.willCloseNotification] {
            interactionWindowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] notification in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if notification.name == NSWindow.willCloseNotification || window?.isVisible != true || window?.isMiniaturized == true {
                        self.invalidateTerminalInteractions()
                    }
                }
            })
        }
        DispatchQueue.main.async { [weak self] in self?.store?.completePendingTerminalFocus() }
    }

    override func viewDidHide() {
        super.viewDidHide()
        invalidateTerminalInteractions()
    }

    deinit {
        inputRelay?.cancel()
        for observer in interactionWindowObservers { NotificationCenter.default.removeObserver(observer) }
    }

    private func cancelHistoryWheel() {
        historyScrollWork?.cancel()
        historyScrollWork = nil
        pendingHistoryLines = 0
        historyWheel.reset()
    }

    func handleHistoryScrollWheel(_ event: NSEvent) -> Bool {
        guard !inputBlocked, !hasMarkedText(), store?.safeInterfaceNavigation != false else { cancelHistoryWheel(); return true }
        guard let store, let session = store.sessions.first(where: { $0.id == paneID }),
              session.alive, session.remote != nil,
              let input = terminalInputStateSnapshot(), input.isAlternateBuffer,
              input.mouseMode == .off || !allowMouseReporting,
              event.modifierFlags.intersection([.shift, .option]).isEmpty,
              let owner = interactionOwner(), let lease = interactionLease(for: owner) else {
            cancelHistoryWheel()
            return false
        }
        if historyReturnInFlight { return true }
        let cellHeight = getOptimalFrameSize().height / CGFloat(max(1, terminalDimensions.rows))
        let lines = historyWheel.take(delta: Double(event.scrollingDeltaY * scrollSensitivity),
            precise: event.hasPreciseScrollingDeltas, cellHeight: Double(cellHeight))
        guard lines != 0 else { return true }
        if historyInputBinding == nil {
            guard let input = currentHistoryTerminalInputBinding(store: store) else {
                cancelHistoryWheel()
                store.message = "The agent changed or is not ready. Buffered input was not sent; please retry in the current terminal."
                return true
            }
            historyInputBinding = (owner, lease, input)
        }
        pendingHistoryLines = max(-1000, min(1000, pendingHistoryLines + lines))
        scheduleHistoryScroll(store: store, owner: owner, lease: lease)
        return true
    }

    private func scheduleHistoryScroll(store: AppStore, owner: TerminalInteractionOwner, lease: TerminalInteractionLease) {
        guard historyScrollWork == nil, !historyScrollInFlight, !historyReturnInFlight else { return }
        let runtime = store.runtime
        let queue = store.queue
        let id = owner.paneID
        let pid = lease.sessionPID
        let work = DispatchWorkItem { [weak self, weak store] in
            guard let self, let store, self.interactionOwner() == owner, lease.isValid else { return }
            self.historyScrollWork = nil
            let amount = self.pendingHistoryLines
            self.pendingHistoryLines = 0
            guard amount != 0 else { return }
            self.historyScrollInFlight = true
            let finished: @MainActor @Sendable () -> Void = { [weak self, weak store] in
                guard let self, let store, self.historyInputBinding?.owner == owner else { return }
                self.historyScrollInFlight = false
                if self.pendingHistoryLines != 0 && !self.historyReturnInFlight && lease.isValid {
                    self.scheduleHistoryScroll(store: store, owner: owner, lease: lease)
                }
            }
            queue.async {
                if lease.isValid {
                    do { try runtime.scrollTerminalHistory(id, expectedPID: pid, lines: amount) }
                    catch {
                        let failure = String(describing: error)
                        DispatchQueue.main.async { [weak self, weak store] in
                            guard let self, let store, lease.isValid, self.interactionOwner() == owner,
                                  self.historyInputBinding?.owner == owner else { return }
                            store.message = "Could not scroll terminal history: " + failure
                        }
                    }
                }
                DispatchQueue.main.async { finished() }
            }
        }
        historyScrollWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(18), execute: work)
    }

    private func currentHistoryTerminalInputBinding(store: AppStore) -> TerminalInputBinding? {
        guard let pane = store.sessions.first(where: { $0.id == paneID }), pane.alive, pane.pid > 1 else { return nil }
        let active = store.state.agentLaunches.filter { $0.paneID == paneID && $0.lifecycle == .active }
        guard active.count <= 1 else { return nil }
        if let launch = active.first {
            guard !launch.id.isEmpty, let providerPID = launch.providerPID, providerPID > 1 else { return nil }
            return TerminalInputBinding(paneID: paneID, backendPID: pane.pid, generation: launch.id, providerPID: providerPID)
        }
        return TerminalInputBinding(paneID: paneID, backendPID: pane.pid, generation: "terminal:\(pane.pid)")
    }

    private func historyInputMayReplay(_ binding: (owner: TerminalInteractionOwner, lease: TerminalInteractionLease, input: TerminalInputBinding), store: AppStore) -> Bool {
        guard let window else { return false }
        return binding.lease.isValid && currentInteractionLease === binding.lease &&
            paneID == binding.owner.paneID && ObjectIdentifier(window) == binding.owner.windowID &&
            window.isVisible && !window.isMiniaturized && !isHiddenOrHasHiddenAncestor &&
            TerminalHistoryReplayFocus.ownsInput(self, in: window) &&
            store.terminalViews[paneID] === self && store.focusedID == paneID &&
            store.sessions.first(where: { $0.id == paneID })?.pid == binding.lease.sessionPID &&
            currentHistoryTerminalInputBinding(store: store) == binding.input &&
            !inputBlocked && store.headerMenuAllowsActions && window.attachedSheet == nil && NSApp.modalWindow == nil
    }

    private func returnFromTerminalHistory(_ input: @escaping () -> Void) -> Bool {
        guard let binding = historyInputBinding, let store else { return false }
        if pendingHistoryInputs.count < Self.historyInputLimit { pendingHistoryInputs.append(input) }
        else { historyInputOverflowed = true }
        guard !historyReturnInFlight else { return true }
        historyReturnInFlight = true
        cancelHistoryWheel()
        let runtime = store.runtime
        let id = binding.owner.paneID
        let pid = binding.lease.sessionPID
        let finished: @MainActor @Sendable (String?, Bool) -> Void = { [weak self, weak store] failure, stale in
            guard let self, let store, self.historyInputBinding?.owner == binding.owner else { return }
            self.historyReturnInFlight = false
            guard self.currentHistoryTerminalInputBinding(store: store) == binding.input else {
                self.historyInputBinding = nil
                self.pendingHistoryInputs.removeAll()
                self.historyInputOverflowed = false
                store.message = "The agent changed or is not ready. Buffered input was not sent; please retry in the current terminal."
                return
            }
            if let failure {
                if stale {
                    self.historyInputBinding = nil
                    self.invalidateTerminalInteractions()
                }
                store.message = "Could not return to the live terminal: " + failure
                return
            }
            guard self.historyInputMayReplay(binding, store: store) else {
                self.historyInputBinding = nil
                self.pendingHistoryInputs.removeAll()
                return
            }
            self.historyInputBinding = nil
            let pending = self.pendingHistoryInputs
            self.pendingHistoryInputs.removeAll()
            let overflowed = self.historyInputOverflowed
            self.historyInputOverflowed = false
            for action in pending {
                guard self.historyInputMayReplay(binding, store: store) else {
                    if self.currentHistoryTerminalInputBinding(store: store) != binding.input {
                        store.message = "The agent changed or is not ready. Remaining buffered input was not sent; please retry in the current terminal."
                        return
                    }
                    break
                }
                action()
            }
            if overflowed { store.message = "Some input was not sent because scrollback was busy. Please retry the remaining input." }
        }
        store.queue.async {
            guard binding.lease.isValid else { return }
            do {
                let matched = try runtime.cancelTerminalHistory(id, expectedPID: pid)
                DispatchQueue.main.async {
                    finished(matched ? nil : "The terminal session changed or could not return to live input.", !matched)
                }
            } catch {
                let failure = String(describing: error)
                DispatchQueue.main.async { finished(failure, false) }
            }
        }
        return true
    }

    func handleHistoryKeyDown(_ event: NSEvent, replay: ((NSEvent) -> Void)? = nil) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.intersection([.command, .control]).isEmpty, !hasMarkedText(),
              !inputBlocked, store?.safeInterfaceNavigation == true, store?.focusedID == paneID,
              let binding = historyInputBinding, interactionOwner() == binding.owner else { return false }
        return returnFromTerminalHistory { [weak self] in
            guard let self, event.keyCode != 53 else { return }
            if let replay { replay(event) }
            else { self.keyDown(with: event) }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard HeaderContextInteraction.accepts(event), let store, store.safeInterfaceNavigation,
              let owner = interactionOwner(), let lease = interactionLease(for: owner) else { return nil }
        let pasteboard = terminalInteractionPasteboard ?? .general
        return TerminalContextMenu.make(hasSelection: !(getSelection() ?? "").isEmpty,
            canPaste: pasteboard.canReadItem(withDataConformingToTypes: ["public.utf8-plain-text", "public.png", "public.tiff"]),
            supports: { [weak self] in self?.supportsTerminalContextCommand($0) == true },
            canAct: { [weak self, weak store] in
                guard let self, let store else { return false }
                return lease.isValid && self.interactionOwner() == owner && store.safeInterfaceNavigation
            }, perform: { [weak self, weak store] command in
                guard let self, let store else { return }
                guard self.supportsTerminalContextCommand(command), let window = self.window,
                      ObjectIdentifier(window) == owner.windowID else { return }
                if store.externalPanePolicy == nil { store.focus(owner.paneID) }
                guard store.focusedID == owner.paneID else { return }
                window.makeKeyAndOrderFront(nil)
                guard window.makeFirstResponder(self) else { return }
                switch command {
                case .action(let action):
                    if store.externalPanePolicy == nil {
                        store.execute(action)
                    } else {
                        switch action {
                        case .copy: self.copy(self)
                        case .paste: self.paste(self)
                        case .selectAll: self.selectAllWithTerminalPreferences(self)
                        case .clear: self.clearScrollback()
                        default: _ = self.terminalContextAction?(action)
                        }
                    }
                case .reset:
                    if !self.returnFromTerminalHistory({ [weak self] in self?.resetToInitialState() }) { self.resetToInitialState() }
                }
            })
    }

    private func supportsTerminalContextCommand(_ command: TerminalContextCommand) -> Bool {
        guard let store else { return false }
        guard store.externalPanePolicy != nil else { return true }
        switch command {
        case .reset: return true
        case .action(let action):
            switch action {
            case .copy, .paste, .selectAll, .clear: return true
            case .increaseFont, .decreaseFont, .resetFont, .closePane: return terminalContextAction != nil && terminalContextSupports?(action) == true
            default: return false
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48,
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .shift,
           !inputBlocked, !hasMarkedText(), interactionOwner() != nil,
           keyboardEnhancementFlags.isEmpty {
            selectNone()
            send(txt: "\u{1b}[Z")
            return
        }
        if [UInt16(36), 76].contains(event.keyCode),
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .shift,
           !inputBlocked, !hasMarkedText(), interactionOwner() != nil,
           keyboardEnhancementFlags.isEmpty,
           let program = store?.sessions.first(where: { $0.id == paneID })?.displayProgram,
           program == .claude || program == .codex {
            selectNone()
            send(txt: "\u{1b}\r")
            return
        }
        // Claude Code reads Control-Return (send the queued message now) from
        // the xterm modifyOtherKeys form when no keyboard protocol is active.
        if [UInt16(36), 76].contains(event.keyCode),
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .control,
           !inputBlocked, !hasMarkedText(), interactionOwner() != nil,
           keyboardEnhancementFlags.isEmpty,
           store?.sessions.first(where: { $0.id == paneID })?.displayProgram == .claude {
            selectNone()
            send(txt: "\u{1b}[27;5;13~")
            return
        }
        super.keyDown(with: event)
    }


    override func mouseDown(with event: NSEvent) {
        let owner = interactionOwner()
        let before = getSelection()
        super.mouseDown(with: event)
        guard let owner, interactionOwner() == owner else { mouseSelectionAttempt = nil; return }
        mouseSelectionAttempt = MouseSelectionAttempt(owner: owner, before: before,
            press: event.locationInWindow, expected: event.clickCount > 1 ? getSelection() : nil,
            multipleClick: event.clickCount > 1)
    }

    override func mouseDragged(with event: NSEvent) {
        let reporting = allowMouseReporting
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if modifiers.isEmpty, let attempt = mouseSelectionAttempt, interactionOwner() == attempt.owner,
           let program = store?.sessions.first(where: { $0.id == paneID })?.displayProgram,
           program == .claude || program == .codex {
            allowMouseReporting = false
        }
        defer { allowMouseReporting = reporting }
        super.mouseDragged(with: event)
        guard let attempt = mouseSelectionAttempt, interactionOwner() == attempt.owner else { mouseSelectionAttempt = nil; return }
        mouseSelectionAttempt?.dragged = true
        mouseSelectionAttempt?.expected = getSelection()
    }

    override func mouseUp(with event: NSEvent) {
        let attempt = mouseSelectionAttempt
        let beforeRelease = getSelection()
        super.mouseUp(with: event)
        mouseSelectionAttempt = nil
        guard let attempt, interactionOwner() == attempt.owner else { return }
        let selected = getSelection()
        let releaseMoved = hypot(event.locationInWindow.x - attempt.press.x, event.locationInWindow.y - attempt.press.y) >= 3
        let releaseChanged = !Self.sameSelection(beforeRelease, selected)
        let expected = releaseMoved && releaseChanged ? selected : attempt.expected
        guard attempt.dragged || attempt.multipleClick || releaseMoved,
              let selected, !selected.isEmpty, !Self.sameSelection(attempt.before, selected),
              Self.sameSelection(expected, selected) else { return }
        terminalSelectionController().selectionChanged(text: selected, intent: .userCompleted,
            isComposing: hasMarkedText(), hostView: self)
    }

    override func copy(_ sender: Any) {
        guard !inputBlocked, !hasMarkedText(), interactionOwner() != nil else { return }
        terminalSelectionController().copy(text: getSelection() ?? "", isComposing: hasMarkedText(), hostView: self)
    }

    func selectAllWithTerminalPreferences(_ sender: Any?) {
        let owner = interactionOwner()
        let before = getSelection()
        super.selectAll(sender)
        guard let owner, interactionOwner() == owner, let selected = getSelection(),
              !Self.sameSelection(before, selected) else { return }
        terminalSelectionController().selectionChanged(text: selected, intent: .userCompleted,
            isComposing: hasMarkedText(), hostView: self)
    }

    private static func sameSelection(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): return true
        case (.some(let left), .some(let right)): return left.utf8.elementsEqual(right.utf8)
        default: return false
        }
    }

    private var coordinator: PaneDelegate?
    private var terminalBridge: TerminalBridge?
    private var historyLimit: Int?
    private var configuredSettings: TerminalSettings?
    private var configuredThemeApplication: ThemeApplication?
    var backgroundUsesImage: Bool { (configuredThemeApplication?.settings ?? configuredSettings)?.appearance.backgroundImagePath != nil }
    private(set) var configuredTerminalPreferences: TerminalPreferences?
    private var configuredResolvedTerminalPreferences: ResolvedTerminalPreferences?
    private var configuredProfileAssigned = false
    private var configuredReduceMotion: Bool?
    private var configuredBackingScale: CGFloat?
    var inputBlocked: Bool { store?.followUpPaneID != nil || store?.decisionPaneID != nil || store?.conversationResume != nil }

    nonisolated override func send(source: Terminal, data: ArraySlice<UInt8>) {
        guard !NativeKittyPasteGate.suppressFallback(owner: ObjectIdentifier(self), source: source, data: data) else { return }
        super.send(source: source, data: data)
    }

    nonisolated override func sendUserInput(source: Terminal, data: ArraySlice<UInt8>) {
        guard !NativeKittyPasteGate.suppressFallback(owner: ObjectIdentifier(self), source: source, data: data) else { return }
        super.sendUserInput(source: source, data: data)
    }

    func installTerminalInputRelay(store: AppStore, id: String, expectedPID: Int32, authoritativeBinding: TerminalInputBinding? = nil) {
        let launch = store.state.agentLaunches.first { $0.paneID == id && $0.lifecycle == .active }
        let binding = authoritativeBinding ?? TerminalInputBinding(paneID: id, backendPID: expectedPID,
            generation: launch?.id ?? "terminal:\(expectedPID)", providerPID: launch?.providerPID)
        guard inputRelayBinding != binding else { return }
        cancelTerminalInputRelay()
        inputRelayBinding = binding
        let relayGeneration = inputRelayGeneration
        let runtime = store.runtime
        let admission = interruptInputAdmission
        let relay = TerminalInputRelay(deliver: { bytes, segments, write, completion in
            runtime.deliverTerminalInput(paneID: id, expectedPID: expectedPID, expectedBinding: binding, bytes: bytes,
                segments: segments, write: write, completion: completion)
        }, invalidated: { [weak self, weak store] reason in
            try? runtime.markTerminalInputUncertain(paneID: id, expectedPID: expectedPID, expectedBinding: binding)
            DispatchQueue.main.async {
                guard let self, let store, self.store === store, self.paneID == id,
                      self.inputRelayGeneration == relayGeneration, self.inputRelayBinding == binding,
                      store.terminalViews[id] === self else { return }
                store.message = reason
            }
        })
        inputRelay = relay
        setProcessInputHandler { bytes, origin, write in
            let user: Bool
            switch origin { case .user: user = true; case .response: user = false }
            let writer: TerminalInputRelay.Writer = { bytes, completion in
                write(bytes) { result in completion(result.mapError { $0 as Error }) }
            }
            if user {
                let guarded = admission.guardWriter(runtime: runtime, paneID: id, backendPID: expectedPID, write: writer)
                relay.send(bytes, user: true, coalescingKey: guarded.coalescingKey, write: guarded.writer)
            } else { relay.send(bytes, user: false, write: writer) }
        }
    }

    func cancelTerminalInputRelay() {
        inputRelayGeneration = UUID()
        inputRelay?.cancel(); inputRelay = nil; inputRelayBinding = nil
        let relayGeneration = inputRelayGeneration, id = paneID
        setProcessInputHandler { [weak self, weak store] _, origin, _ in
            guard case .user = origin else { return }
            DispatchQueue.main.async {
                guard let self, let store, self.store === store, self.paneID == id,
                      self.inputRelayGeneration == relayGeneration, self.inputRelayBinding == nil,
                      store.terminalViews[id] === self else { return }
                self.recoverTerminalInput(store: store, id: id)
            }
        }
    }

    static let reconnectingMessage = "Terminal is reconnecting. Try input again when it is ready."

    // Nothing else re-synchronizes an idle pane, so rejected input must drive the reconnect itself.
    private func recoverTerminalInput(store: AppStore, id: String) {
        guard !inputRecoveryPending else { return }
        inputRecoveryPending = true
        store.perform(restoringContext: false, holdingTransaction: false, completion: { [weak self, weak store] _ in
            guard let self else { return }
            self.inputRecoveryPending = false
            guard let store, self.store === store, self.paneID == id, store.terminalViews[id] === self else { return }
            self.synchronize(store: store, id: id)
            if self.inputRelayBinding != nil {
                if store.message == Self.reconnectingMessage { store.message = nil }
            } else if !self.pendingReconnect { store.message = Self.reconnectingMessage }
        }) { _ in }
    }

    func tryNativeKittyPaste(_ sender: Any) -> Bool {
        NativeKittyPasteGate.perform(owner: ObjectIdentifier(self)) { super.paste(sender) }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard !inputBlocked else { return }
        super.insertText(string, replacementRange: replacementRange)
    }

    func configure(_ settings: TerminalSettings, preferences: TerminalPreferences = TerminalPreferences(),
                   themeApplication: ThemeApplication? = nil, profileAssigned: Bool = false) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let preferencesChanged = configuredTerminalPreferences != preferences
        if configuredSettings != settings || configuredThemeApplication != themeApplication || preferencesChanged ||
            configuredProfileAssigned != profileAssigned || configuredReduceMotion != reduceMotion ||
            configuredBackingScale != backingScale {
            do {
                let resolved = try TerminalPreferenceRenderer.apply(preferences, legacy: settings,
                    themeApplication: themeApplication, profileAssigned: profileAssigned,
                    previousResolved: configuredResolvedTerminalPreferences, reduceMotion: reduceMotion, to: self)
                configuredSettings = settings
                configuredThemeApplication = themeApplication
                configuredTerminalPreferences = preferences
                configuredResolvedTerminalPreferences = resolved
                configuredProfileAssigned = profileAssigned
                configuredReduceMotion = reduceMotion
                configuredBackingScale = backingScale
                if historyLimit != settings.scrollbackLines {
                    changeScrollback(settings.scrollbackLines)
                    historyLimit = settings.scrollbackLines
                }
                if preferencesChanged { terminalInteractionPreferencesDidChange() }
            } catch {
                let description = String(describing: error)
                if store?.message != description { store?.message = description }
            }
        }
        if terminalBridge == nil { let bridge = TerminalBridge(view: self); terminalBridge = bridge; terminalDelegate = bridge }
    }

    override func viewDidChangeBackingProperties() {
        if let settings = configuredSettings, let preferences = configuredTerminalPreferences {
            configure(settings, preferences: preferences, themeApplication: configuredThemeApplication,
                      profileAssigned: configuredProfileAssigned)
        }
        super.viewDidChangeBackingProperties()
    }

    private func hasAppearanceProfile(store: AppStore, id: String) -> Bool {
        store.state.settings.paneAppearanceProfiles[id].map { profileID in
            store.state.settings.appearanceProfiles.contains { $0.id == profileID }
        } ?? false
    }

    override func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
        guard source === self, !inputBlocked, !hasMarkedText(), let owner = interactionOwner(),
              let store, let pane = store.sessions.first(where: { $0.id == paneID }), let window else { return }
        if TerminalLocalFileLink.isFileReference(link) {
            guard pane.host == "local", pane.remote == nil else {
                store.message = "This file is on a remote host and cannot be opened as a local file."
                return
            }
            guard let file = TerminalLocalFileLink.resolve(link, cwd: pane.cwd) else {
                store.message = "The linked file could not be found."
                return
            }
            guard interactionOwner() == owner else { return }
            terminalLinkHandler().requestOpen(file, in: window)
        } else if let url = URL(string: link) {
            terminalLinkHandler().requestOpen(url, in: window)
        }
    }

    override func paste(_ sender: Any) {
        guard !inputBlocked else { return }
        if returnFromTerminalHistory({ [weak self] in self?.paste(sender) }) { return }
        if tryNativeKittyPaste(sender) { return }
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

    func pasteDraft(_ text: String, ownership: DeferredTerminalInputOwnership? = nil, didInsert: @escaping () -> Void = {}) {
        guard !inputBlocked else { return }
        let originalOwner: DeferredTerminalInputOwnership
        if let ownership { originalOwner = ownership }
        else {
            guard let store, let target = DeferredTerminalInputTarget.capture(store: store, paneID: paneID) else { return }
            originalOwner = target.ownership()
        }
        let presenter = terminalPastePromptPresenter ?? NativeTerminalDraftPastePromptPresenter()
        TerminalDraftPaste(text: text, ownership: originalOwner,
            history: { [weak self] input in self?.returnFromTerminalHistory(input) ?? false },
            bracketed: { [weak self] in self?.terminalInputStateSnapshot()?.bracketedPasteMode == true },
            confirm: { presenter.confirm($0, bracketed: $1) }, report: { [weak self] in self?.store?.message = $0 },
            insert: { [weak self] in self?.pasteText($0) }, didInsert: didInsert).perform()
    }

    func connect(store: AppStore, id: String) {
        guard !started else { return }
        invalidateTerminalInteractions()
        if attachedPID != nil { terminalBridge?.kittyClipboard.revokePermissions(in: self) }
        started = true
        self.store = store
        paneID = id
        attachedPID = store.sessions.first { $0.id == id }?.pid
        installTerminalInputRelay(store: store, id: id, expectedPID: attachedPID ?? 0)
        registerForDraggedTypes([.fileURL])
        coordinator = PaneDelegate(store: store)
        processDelegate = coordinator
        let theme = store.themeApplication(for: id)
        configure(theme.settings, preferences: store.terminalPreferences, themeApplication: theme,
                  profileAssigned: hasAppearanceProfile(store: store, id: id))
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TMUX")
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TRANO_SESSION"] = id
        environment["TRANO_DATA_DIR"] = store.runtime.root.path
        do {
            let attach = try store.runtime.attachCommand(id)
            startProcess(executable: attach.executable, args: attach.arguments, environment: environment.map { "\($0.key)=\($0.value)" })
            if store.focusedID == id { store.restoreTerminalFocus() }
        } catch { feed(text: "\r\n\(error.localizedDescription)\r\n") }
    }

    func synchronize(store: AppStore, id: String) {
        let theme = store.themeApplication(for: id)
        configure(theme.settings, preferences: store.terminalPreferences, themeApplication: theme,
                  profileAssigned: hasAppearanceProfile(store: store, id: id))
        guard let pane = store.sessions.first(where: { $0.id == id }), pane.alive else { cancelTerminalInputRelay(); invalidateTerminalInteractions(); return }
        if attachedPID != nil && attachedPID != pane.pid { cancelTerminalInputRelay(); invalidateTerminalInteractions() }
        if started && attachedPID == pane.pid && process.running {
            installTerminalInputRelay(store: store, id: id, expectedPID: pane.pid)
            return
        }
        if process.running || process.windingDown {
            cancelTerminalInputRelay()
            pendingReconnect = true
            terminate()
            return
        }
        started = false
        connect(store: store, id: id)
    }

    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        cancelTerminalInputRelay()
        invalidateTerminalInteractions()
        started = false
        super.processTerminated(source, exitCode: exitCode)
        if pendingReconnect, let store, store.terminalViews[paneID] === self {
            pendingReconnect = false
            synchronize(store: store, id: paneID)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !inputBlocked else { return [] }
        guard store?.sessions.first(where: { $0.id == paneID })?.host == "local" else { return [] }
        return sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !inputBlocked else { return false }
        guard store?.sessions.first(where: { $0.id == paneID })?.host == "local",
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
        do { pasteText(try PathInsertion.text(paths: urls.map(\.path))); return true }
        catch { store?.message = error.localizedDescription; return false }
    }

}

@MainActor final class TerminalBridge: TerminalViewDelegate {
    weak var view: TranoView?
    let kittyClipboard: KittyClipboardHost
    init(view: TranoView, kittyClipboard: KittyClipboardHost? = nil) {
        self.view = view
        self.kittyClipboard = kittyClipboard ?? KittyClipboardHost(view: view)
    }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { view?.send(source: source, data: data) }
    func sendUserInput(source: TerminalView, data: ArraySlice<UInt8>) { view?.sendUserInput(source: source, data: data) }
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
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) { store?.terminalTitleChanged(source: source) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { store?.refresh() }
    func processFailedToStart(source: TerminalView, error: LocalProcessError) { store?.message = String(describing: error) }
}

struct TerminalPane: NSViewRepresentable {
    @ObservedObject var store: AppStore
    let id: String
    var interfacePresentation: InterfacePresentation? = nil

    func makeNSView(context: Context) -> DeveloperTerminalContainer {
        if let existing = store.terminalViews[id] { return container(for: existing) }
        let terminal = TranoView.makeClipboardTerminal(frame: .zero)
        terminal.paneID = id
        terminal.store = store
        let theme = store.themeApplication(for: id)
        terminal.configure(theme.settings, preferences: store.terminalPreferences, themeApplication: theme,
            profileAssigned: store.state.settings.paneAppearanceProfiles[id].map { profileID in
                store.state.settings.appearanceProfiles.contains { $0.id == profileID }
            } ?? false)
        terminal.suspendsRenderingWhenNotVisible = !CommandLine.arguments.contains("--snapshot") && !CommandLine.arguments.contains("--benchmark-readiness")
        terminal.setAccessibilityLabel("Terminal · " + (store.sessions.first { $0.id == id }?.title ?? "Shell"))
        store.terminalViews[id] = terminal
        DispatchQueue.main.async { terminal.connect(store: store, id: id) }
        return container(for: terminal)
    }

    func updateNSView(_ container: DeveloperTerminalContainer, context: Context) {
        guard let view = container.terminal as? TranoView else { return }
        view.setAccessibilityLabel("Terminal · " + (store.sessions.first { $0.id == id }?.title ?? "Shell"))
        view.synchronize(store: store, id: id)
        view.applyInterfacePresentation(interfacePresentation ?? store.interfacePresentation(for: id, in: view.window))
        configure(container, terminal: view)
    }

    private func container(for terminal: TranoView) -> DeveloperTerminalContainer {
        let container = (terminal.superview as? DeveloperTerminalContainer)
            ?? DeveloperTerminalContainer(terminal: terminal, rowHeight: { [weak terminal] in
                guard let terminal else { return 0 }
                return terminal.getOptimalFrameSize().height / CGFloat(max(1, terminal.terminalDimensions.rows))
            })
        configure(container, terminal: terminal)
        return container
    }

    private func configure(_ container: DeveloperTerminalContainer, terminal: TranoView) {
        container.anchoring = store.developerPreferences.effectiveAnchoring
        container.backgroundColor = terminal.nativeBackgroundColor
        container.cursorOverlay.caretFrame = { [weak terminal] in terminal?.caretFrame ?? .zero }
        container.cursorOverlay.color = terminal.caretColor
        container.cursorOverlay.active = { [weak terminal] in
            guard let terminal, let store = terminal.store else { return false }
            return store.focusedID == terminal.paneID && terminal.window?.firstResponder === terminal
                && !terminal.hasMarkedText() && !terminal.inputBlocked
        }
        container.cursorOverlay.style = store.developerPreferences.effectiveCursorEffect
        container.cursorOverlay.reconcileTimer()
        container.needsLayout = true
    }

    static func dismantleNSView(_ container: DeveloperTerminalContainer, coordinator: ()) {
        container.cursorOverlay.stop()
        guard let view = container.terminal as? TranoView else { return }
        view.invalidateTerminalInteractions()
        view.store?.floatingPanes.rendererDetached(view)
    }
}
