import AppKit
import SwiftUI
import TerminalCore

enum PessimisticTwinPresentation {
    static func title(_ mode: TwinReviewMode) -> String {
        switch mode {
        case .codeReview: return "Code Review"
        case .securityReview: return "Security Review"
        case .generalReview: return "General Review"
        }
    }
    static func title(_ phase: TwinPhase) -> String {
        switch phase {
        case .waitingForSource: return "Waiting for Source"
        case .snapshotting: return "Snapshotting"
        case .launching: return "Starting Twin"
        case .reviewing: return "Reviewing"
        case .awaitingDecision: return "Decision Required"
        case .waitingForMerge: return "Merge Scheduled"
        case .merging: return "Merging"
        case .forwarding: return "Sending Feedback"
        case .awaitingSourceResponse: return "Waiting for Response"
        case .cleaning: return "Cleaning Up"
        case .finished: return "Finished"
        case .needsReview: return "Review Needed"
        case .conflict: return "Merge Conflict"
        }
    }
    static func title(_ reason: TwinExitReason) -> String {
        switch reason {
        case .agentAgreement: return "Agents Agree"
        case .noopCap: return "No Further Improvement"
        case .roundCap: return "Round Limit Reached"
        case .userInterrupt: return "Stopped"
        case .agentUnavailable: return "Agent Unavailable"
        case .invalidAgentOutput: return "Invalid Review Output"
        }
    }
    static func summary(_ run: TwinRun) -> String {
        let phase = run.phase == .finished ? run.exitReason.map(title) ?? title(run.phase) : title(run.phase)
        return "\(title(run.mode)) · \(phase) · Round \(run.currentRound)/\(run.roundCap)"
    }
    static func needsAttention(_ run: TwinRun) -> Bool {
        [.needsReview, .conflict, .awaitingDecision].contains(run.phase)
    }
    static func visibleRuns(_ runs: [TwinRun]) -> [TwinRun] {
        Array(runs.sorted {
            if $0.isActive != $1.isActive { return $0.isActive }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }.prefix(12))
    }
}

struct PessimisticTwinMenuTarget: Equatable {
    let paneID: String
    let identity: [String]
    let canStart: Bool
    let activeRunID: String?

    static func startable(local: Bool, alive: Bool, backendPID: Int32, launcherPID: Int32?, providerPID: Int32?,
                          provider: AgentKind?, conversationID: String?) -> Bool {
        local && alive && backendPID > 1 && (launcherPID ?? 0) > 1 && (providerPID ?? 0) > 1 &&
            provider != nil && provider != .shell && conversationID.flatMap(UUID.init(uuidString:)) != nil
    }

    @MainActor static func capture(store: AppStore, paneID: String) -> Self {
        let session = store.sessions.first { $0.id == paneID }
        let launches = store.state.agentLaunches.filter { $0.paneID == paneID && $0.lifecycle == .active }
        let launch = launches.count == 1 ? launches.first : nil
        let run = store.currentTwin(paneID: paneID).flatMap { $0.isActive ? $0 : nil }
        let canStart = startable(local: session?.remote == nil, alive: session?.alive == true,
            backendPID: session?.pid ?? 0, launcherPID: launch?.processID, providerPID: launch?.providerPID,
            provider: launch?.provider, conversationID: launch?.providerSessionID)
        let identity = [String(describing: ObjectIdentifier(store)), session?.id ?? "", String(session?.pid ?? 0),
            session?.alive.description ?? "", session?.remote == nil ? "local" : "remote", session?.cwd ?? "",
            launch?.id ?? "", launch?.provider.rawValue ?? "", launch?.providerSessionID ?? "",
            String(launch?.processID ?? 0), String(launch?.providerPID ?? 0), launch?.cwd ?? "", launch?.configurationRoot ?? "", launch?.accountID ?? "", launch?.organizationBindingID ?? "", launch?.bootID ?? ""]
        return Self(paneID: paneID, identity: identity, canStart: canStart, activeRunID: run?.id)
    }
}

@MainActor final class PessimisticTwinNativeButton: NSButton {
    var menuTarget: PessimisticTwinMenuTarget?
    var run: TwinRun?
    var currentTarget: () -> PessimisticTwinMenuTarget? = { nil }
    var enable: (TwinReviewMode) -> Void = { _ in }
    var stop: (String) -> Void = { _ in }
    var windowReady: (NSWindow) -> Bool = { window in
        NSApp.isActive && window.isVisible && window.isKeyWindow && !window.isMiniaturized &&
            window.attachedSheet == nil && NSApp.modalWindow == nil
    }
    var menuPresenter: (NSMenu, NSView) -> Void = { menu, view in
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.minY - 3), in: view)
    }
    var schedule: (@escaping () -> Void) -> Void = { task in DispatchQueue.main.async { task() } }
    private var pendingPresentation: UUID?
    private var pendingConsumption: (() -> Void)?
    private var presenting = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        target = self
        action = #selector(invoke(_:))
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        symbolConfiguration = .init(pointSize: 11, weight: .regular)
        setAccessibilityLabel("Pessimistic Twin")
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 22) }

    @objc func invoke(_ sender: Any?) {
        pendingPresentation = nil
        let consume = pendingConsumption
        pendingConsumption = nil
        consume?()
        guard let captured = menuTarget, let owner = window else { return }
        present(captured, owner: owner)
    }
    func requestPresentation(isCurrent: @escaping () -> Bool, consume: @escaping () -> Void) {
        guard pendingPresentation == nil, !presenting else { return }
        let ticket = UUID(), captured = menuTarget, owner = window
        pendingPresentation = ticket
        pendingConsumption = { if isCurrent() { consume() } }
        schedule { [weak self, weak owner] in
            guard let self, self.pendingPresentation == ticket else { return }
            self.pendingPresentation = nil
            self.pendingConsumption = nil
            guard isCurrent() else { return }
            consume()
            guard let captured, let owner else { return }
            self.present(captured, owner: owner)
        }
    }
    private func permitted(_ captured: PessimisticTwinMenuTarget, owner: NSWindow) -> Bool {
        window === owner && isEnabled && !isHiddenOrHasHiddenAncestor && windowReady(owner) &&
            menuTarget == captured && currentTarget() == captured &&
            (owner.firstResponder as? NSTextInputClient)?.hasMarkedText() != true
    }
    private func present(_ captured: PessimisticTwinMenuTarget, owner: NSWindow) {
        guard !presenting, permitted(captured, owner: owner), captured.canStart || captured.activeRunID != nil else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, enabled: Bool, selected: Bool = false, action: @escaping () -> Void) {
            let item = PessimisticTwinMenuItem(title: title, action: #selector(PessimisticTwinMenuItem.invoke(_:)), keyEquivalent: "")
            item.target = item
            item.state = selected ? .on : .off
            item.isEnabled = enabled
            item.onAction = { [weak self, weak owner] in
                guard let self, let owner, self.permitted(captured, owner: owner) else { return }
                action()
            }
            menu.addItem(item)
        }
        for mode in TwinReviewMode.allCases {
            add(PessimisticTwinPresentation.title(mode), enabled: captured.canStart && captured.activeRunID == nil,
                selected: captured.activeRunID != nil && run?.mode == mode) { [weak self] in self?.enable(mode) }
        }
        if let runID = captured.activeRunID {
            menu.addItem(.separator())
            let status = run.map { "\(PessimisticTwinPresentation.title($0.phase)) · Round \($0.currentRound)/\($0.roundCap)" } ?? "Active Twin"
            add(status, enabled: false, action: {})
            add("Stop Twin", enabled: true) { [weak self] in self?.stop(runID) }
        }
        presenting = true
        defer { presenting = false }
        menuPresenter(menu, self)
    }
}

@MainActor private final class PessimisticTwinMenuItem: NSMenuItem {
    var onAction: (() -> Void)?
    @objc func invoke(_ sender: Any?) { if isEnabled { onAction?() } }
}

struct PessimisticTwinButton: NSViewRepresentable {
    @ObservedObject var store: AppStore
    let paneID: String

    func makeNSView(context: Context) -> PessimisticTwinNativeButton {
        let button = PessimisticTwinNativeButton(frame: .zero)
        updateNSView(button, context: context)
        return button
    }
    func updateNSView(_ button: PessimisticTwinNativeButton, context: Context) {
        let captured = PessimisticTwinMenuTarget.capture(store: store, paneID: paneID)
        let run = store.currentTwin(paneID: paneID).flatMap { $0.isActive ? $0 : nil }
        button.menuTarget = captured
        button.run = run
        button.identifier = NSUserInterfaceItemIdentifier("pessimistic-twin-button-" + paneID)
        button.image = NSImage(systemSymbolName: run == nil ? "person.2" : "person.2.fill", accessibilityDescription: nil)
        button.contentTintColor = run.map(PessimisticTwinPresentation.needsAttention) == true ? .systemOrange :
            run == nil ? .secondaryLabelColor : NSColor(red: 133/255, green: 215/255, blue: 193/255, alpha: 1)
        button.toolTip = "Pessimistic Twin · Local managed Claude or Codex conversations only" + (run.map { " · " + PessimisticTwinPresentation.summary($0) } ?? "")
        button.setAccessibilityValue(run.map(PessimisticTwinPresentation.summary) ?? "Off")
        button.isEnabled = context.environment.isEnabled && (captured.canStart || run != nil)
        button.currentTarget = { [weak store] in store.map { PessimisticTwinMenuTarget.capture(store: $0, paneID: paneID) } }
        button.enable = { [weak store] mode in store?.enableTwin(paneID: paneID, mode: mode) }
        button.stop = { [weak store] id in store?.stopTwin(id: id) }
        if store.twinModePickerPaneID == paneID {
            button.requestPresentation(isCurrent: { [weak store] in store?.twinModePickerPaneID == paneID }, consume: { [weak store] in
                if store?.twinModePickerPaneID == paneID { store?.twinModePickerPaneID = nil }
            })
        }
    }
}

struct PessimisticTwinActivitySection: View {
    @ObservedObject var store: AppStore
    private var runs: [TwinRun] { PessimisticTwinPresentation.visibleRuns(store.pessimisticTwinRuns) }
    var body: some View {
        if !runs.isEmpty || store.twinActionError != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Pessimistic Twins").font(.system(size: 10, weight: .semibold))
                    Spacer()
                    Text("\(runs.filter(\.isActive).count)").font(.system(size: 10, design: .monospaced))
                }.foregroundStyle(.secondary)
                if let error = store.twinActionError {
                    Text(error).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(3)
                }
                ForEach(runs) { run in
                    HStack(alignment: .top, spacing: 10) {
                        AgentLogo(agent: run.source.provider).frame(width: 18, height: 18)
                            .overlay(alignment: .topTrailing) {
                                if PessimisticTwinPresentation.needsAttention(run) {
                                    Circle().fill(Color.orange).frame(width: 5, height: 5).offset(x: 2, y: -1)
                                }
                            }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(PessimisticTwinPresentation.title(run.mode)).font(.system(size: 12, weight: .medium))
                            HStack(spacing: 5) {
                                Text(run.phase == .finished ? run.exitReason.map(PessimisticTwinPresentation.title) ?? "Finished" : PessimisticTwinPresentation.title(run.phase))
                                Text("·")
                                Text("Round \(run.currentRound)/\(run.roundCap)")
                            }.font(.system(size: 10)).foregroundStyle(PessimisticTwinPresentation.needsAttention(run) ? Color.orange : Color.secondary)
                            Text(URL(fileURLWithPath: run.source.cwd).lastPathComponent).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).help(run.source.cwd)
                            if let reason = run.message ?? run.latestRound?.message, !reason.isEmpty {
                                Text(reason).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                            }
                            if run.isActive {
                                Button("Stop Twin") {
                                    guard (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true,
                                          store.pessimisticTwinRuns.contains(where: { $0.id == run.id && $0.isActive }) else { return }
                                    store.stopTwin(id: run.id)
                                }.font(.system(size: 10)).buttonStyle(.borderless)
                            }
                        }
                        Spacer(minLength: 0)
                    }.padding(.vertical, 5).accessibilityElement(children: .contain)
                        .accessibilityLabel(PessimisticTwinPresentation.summary(run))
                }
            }
        }
    }
}
