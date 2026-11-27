import AppKit
import Combine
import SwiftUI
import SwiftTerm
import TerminalCore
import UserNotifications

@MainActor final class AppStore: ObservableObject {
    enum ActivityIndicatorKey: Hashable {
        case pane(String, String)
        case worktree(String, String)
    }
    @Published private var seenActivityEvents: [ActivityIndicatorKey: Date] = [:]
    @Published var state = RuntimeState()
    @Published var conversationResume: ConversationResumeModel?
    var conversationResumeLease: ConversationResumeCancellation?
    weak var conversationResumeOwner: NSWindow?
    var conversationResumeLivePanes: [String: String] = [:]

    @Published var themePreferences = ThemePreferences()
    @Published var terminalPreferences = TerminalPreferences() {
        didSet {
            guard terminalPreferences != oldValue else { return }
            for view in terminalViews.values { view.terminalInteractionPreferencesDidChange() }
        }
    }
    @Published var developerPreferences = DeveloperPreferences()
    @Published var serverPreferences = ServerPreferences()
    @Published var integrationsPreferences = IntegrationsPreferences()
    @Published var pessimisticTwinRuns: [TwinRun] = []
    @Published var twinModePickerPaneID: String?
    @Published var twinActionError: String?
    @Published var twinBusy: Set<String> = []
    @Published var worktreeCleanupRecords: [WorktreeCleanupRecord] = []
    @Published var worktreeCleanupError: String?
    @Published var worktreeCleanupActionError: String?
    @Published var worktreeCleanupBusy: Set<String> = []
    @Published var notificationPreferences = NotificationPreferences()
    private var notificationPreferenceRefreshPending = false
    @Published var sessions: [TerminalSession] = []
    @Published var message: String? { didSet { if message != nil { commandKeyHints.cancel() } } }
    @Published var picker: PickerKind? { didSet { if picker != nil { commandKeyHints.cancel() } } }
    @Published var activitySelectionID: String?
    @Published var activityFilter = "" {
        didSet { if activityFilter != oldValue { activitySelectionID = activityRows.first?.id } }
    }
    @Published var showActivity = false {
        didSet {
            if showActivity {
                commandKeyHints.cancel()
                if !oldValue { activityFilter = ""; activitySelectionID = activityRows.first?.id }
            } else if oldValue { activityFilter = "" }
        }
    }

    var activitySections: [ActivityInbox.Section] {
        let sections = ActivityInbox.sections(NotificationActivityProjection.rows(layout: state.layout, sessions: sessions, preferences: notificationPreferences), readAt: state.activityReadAt)
        let layout = state.layout, preferGenerated = terminalPreferences.preferGeneratedTitles
        return ActivityInbox.filter(sections, query: activityFilter) { session in
            let workspace = layout.tabs.first(where: { $0.panes.contains(session.id) })
                .flatMap { tab in layout.workspaces.first(where: { $0.id == tab.workspaceID })?.title } ?? ""
            return (session.displayTitle(preferGeneratedTitles: preferGenerated),
                    [session.activity.reason, workspace, URL(fileURLWithPath: session.cwd).lastPathComponent].joined(separator: " "))
        }
    }

    var activityRows: [TerminalSession] { activitySections.flatMap(\.sessions) }

    var selectedActivityID: String? {
        activityRows.first(where: { $0.id == activitySelectionID })?.id ?? activityRows.first?.id
    }

    func moveActivitySelection(_ delta: Int) {
        let rows = activityRows
        guard !rows.isEmpty else { activitySelectionID = nil; return }
        let index = rows.firstIndex(where: { $0.id == selectedActivityID }) ?? 0
        activitySelectionID = rows[((index + delta) % rows.count + rows.count) % rows.count].id
    }

    func activateActivitySelection() {
        guard showActivity, let id = selectedActivityID else { return }
        openActivityPane(id)
    }

    func openActivityPane(_ id: String) {
        guard activityRows.contains(where: { $0.id == id }) else { return }
        activitySelectionID = id
        showActivity = false
        attach(id)
    }
    @Published var interfacePreferences = InterfacePreferences()
    @Published var windowOpacityPreview: WindowOpacityPreview?
    @Published var interfaceToolbarHovered = false
    @Published var interfaceToolbarRevealed = false
    @Published var interfaceProgramBackgrounds: [String: String] = [:]
    @Published var interfaceAlternateScreens: Set<String> = []
    var interfaceMagnification: Double = 0
    var interfaceMagnificationHandled = false
    @Published var showSessionsSidebar = false
    @Published var showSettings = false { didSet { if showSettings { commandKeyHints.cancel() } } }
    var voiceInputRecovery = VoiceInputRecoveryDraft()
    var voiceInputInitialDraft = ""
    var voiceInputPresentationID: UUID?
    var voiceInputTarget: DeferredTerminalInputTarget?
    let attachmentAdmission = AttachmentAdmissionBudget()
    let attachmentQueue = DispatchQueue(label: "trano.attachments", qos: .utility)
    @Published var showVoice = false {
        didSet {
            if showVoice {
                commandKeyHints.cancel()
                if !oldValue {
                    voiceInputInitialDraft = voiceInputRecovery.reviewOnNextOpen(currentID: voiceInputPresentationID) ?? ""
                    voiceInputPresentationID = UUID()
                    voiceInputTarget = focusedID.flatMap { DeferredTerminalInputTarget.capture(store: self, paneID: $0, preparingVoice: true) }
                }
            }
        }
    }
    @Published var showRemoteHosts = false { didSet { if showRemoteHosts { commandKeyHints.cancel() } } }
    @Published var showAccounts = false { didSet { if showAccounts { commandKeyHints.cancel() } } }
    @Published var showExtensions = false { didSet { if showExtensions { commandKeyHints.cancel() } } }
    @Published var remotePathRequest: RemotePathRequest? { didSet { if remotePathRequest != nil { commandKeyHints.cancel() } } }
    @Published var followUpPaneID: String? { didSet { if followUpPaneID != nil { commandKeyHints.cancel() } } }
    @Published var followUpDraft = "" { didSet { followUpDraftRevision += 1 } }
    @Published var followUpEditingID: String?
    @Published var followUpSaving = false
    @Published var followUpError: String?
    @Published var followUpComposing = false
    weak var followUpEditor: NSTextView?
    private var followUpDraftRevision = 0
    private var followUpPresentationID = UUID()

    @Published var decisionEntries: [DecisionInboxEntry] = []
    @Published var decisionPaneID: String? { didSet { if decisionPaneID != nil { commandKeyHints.cancel() } } }
    @Published var decisionSaving = false
    @Published var decisionError: String?
    @Published var decisionDrafts: [String: DecisionDraft] = [:]
    @Published var preferredDecisionID: String?
    private var presentedDecisionIDs: Set<String> = []
    private var decisionArrivalCard = false
    @Published var accountUsageSnapshots: [AccountUsageSnapshot] = []
    @Published var sessionLoadByPane: [String: SessionLoadSnapshot] = [:]
    private var sessionLoadClient: SessionLoadClientCache?
    private var sessionLoadSubscription: AnyCancellable?
    @Published var tabShortcutHintsVisible = false
    @Published var zoomed = false
    @Published var floatingPaneIDs: Set<String> = []
    @Published var loading = true
    let runtime: TerminalRuntime
    private let initialWorkspaceID: String?
    let externalPanePolicy: ExternalTerminalPanePolicy?
    @Published var unisessionPresented = false
    weak var unisessionAnchor: NSView?
    var onUnisessionAnchor: ((NSView) -> Void)?
    var onToggleSupervisor: (() -> Void)?
    var onRevealSupervisor: (() -> Void)?
    var onPaneDetachedWindow: ((String, NSPoint) -> Void)?
    let queue = DispatchQueue(label: "trano.runtime", qos: .userInitiated)
    private var watcher: DispatchSourceFileSystemObject?
    private var refreshWork: DispatchWorkItem?
    private var titleRefreshPending = false
    private var titleRefreshGeneration: UInt = 0
    private var foregroundProgramTimer: DispatchSourceTimer?
    private var foregroundProgramRefreshPending = false
    var terminalViews: [String: TranoView] = [:] {
        didSet {
            for (id, view) in oldValue where terminalViews[id] !== view {
                view.cancelTerminalInputRelay()
                view.invalidateTerminalInteractions()
            }
        }
    }
    private var selection = WindowSelection()
    private var pendingTerminalFocusID: String?
    private var pendingTerminalFocusReturnWindow: ObjectIdentifier?
    var preferredWorkspaceID: String? { externalPanePolicy == nil ? selection.workspaceID : nil }
    var isActiveWindow: () -> Bool = { true }
    lazy var commandKeyHints = CommandKeyHints { [weak self] value in self?.tabShortcutHintsVisible = value }
    lazy var floatingPanes = FloatingPaneController(store: self)
    var onFloatingWindowChange: ((NSWindow, Bool) -> Void)?

    var canShowTabShortcutHints: Bool {
        !loading && conversationResume == nil && !state.layout.currentTabs.isEmpty && decisionPaneID == nil && followUpPaneID == nil && picker == nil && message == nil && !showActivity && !showSettings && !showVoice && !showRemoteHosts && !showAccounts && !showExtensions && remotePathRequest == nil
    }

    var tabShortcutHints: [String: String] {
        guard tabShortcutHintsVisible else { return [:] }
        let tabs = state.layout.currentTabs
        return Dictionary(uniqueKeysWithValues: tabs.enumerated().compactMap { index, tab in
            CommandKeyHints.label(for: index, count: tabs.count).map { (tab.id, $0) }
        })
    }

    enum PickerKind: String, Identifiable { case sessions, commands, anything, movePane; var id: String { rawValue } }
    var selectedTab: TerminalTab? { externalPanePolicy == nil ? state.layout.tabs.first { $0.id == state.layout.selectedTabID } : nil }
    var focusedID: String? { externalPanePolicy?.paneID ?? state.layout.focusedPaneID }
    var currentDirectory: String { sessions.first { $0.id == focusedID }?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path }

    init(runtime: TerminalRuntime, bootstrapIfEmpty: Bool = false, initialWorkspaceID: String? = nil, recoverOnStartup: Bool = true,
         externalBinding: SupervisorBinding? = nil, unisessionBinding: UnisessionBinding? = nil, startServices: Bool = true) {
        self.runtime = runtime
        externalPanePolicy = unisessionBinding.map(ExternalTerminalPanePolicy.unisession) ?? externalBinding.map(ExternalTerminalPanePolicy.supervisor)
        self.initialWorkspaceID = externalPanePolicy == nil ? initialWorkspaceID : nil
        if externalPanePolicy != nil || !startServices { loading = false; return }
        let fd = open(runtime.root.path, O_EVTONLY | O_CLOEXEC)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
            source.setEventHandler { [weak self] in self?.scheduleRefresh() }
            source.setCancelHandler { close(fd) }
            source.resume()
            watcher = source
        }
        WorkspaceOwners.register(self)
        let loadClient = SessionLoadClientCache.shared(root: runtime.root)
        sessionLoadClient = loadClient
        sessionLoadSubscription = loadClient.$byPane.sink { [weak self] snapshots in self?.sessionLoadByPane = snapshots }
        reloadInterfacePreferences()
        reloadWorktreeCleanup()
        reloadPessimisticTwins()
        perform(restoringContext: false, holdingTransaction: false) { if recoverOnStartup { _ = try $0.migrateLegacyTmuxPanes(); _ = try $0.recoverSessions(automatic: true) }; if bootstrapIfEmpty { _ = try $0.ensureInitialWorkspace() } }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.refreshInterfaceProgramColors(); self?.refreshForegroundPrograms() } }
        timer.resume()
        foregroundProgramTimer = timer
    }

    deinit { foregroundProgramTimer?.cancel() }

    func refreshForegroundPrograms() {
        guard !loading, !foregroundProgramRefreshPending else { return }
        let local = sessions.filter { $0.alive && $0.remote == nil }
        guard !local.isEmpty else { return }
        foregroundProgramRefreshPending = true
        let runtime = runtime
        let pids = Dictionary(local.map { ($0.id, $0.pid) }, uniquingKeysWith: { first, _ in first })
        queue.async { [weak self] in
            let programs = runtime.foregroundPrograms(for: local)
            DispatchQueue.main.async {
                guard let self else { return }
                self.foregroundProgramRefreshPending = false
                let next = self.sessions.map { session in
                    guard session.remote == nil, session.alive, pids[session.id] == session.pid else { return session }
                    var value = session
                    value.foregroundProgram = programs[session.id]
                    return value
                }
                if self.sessions != next { self.sessions = next }
            }
        }
    }

    func perform(restoringContext: Bool = true, holdingTransaction: Bool = true,
                 publishingSelectionBeforeObservation: Bool = false, restoringFocus: Bool = false,
                 validateBeforeWork: (@MainActor () -> Bool)? = nil, completion: ((Error?) -> Void)? = nil,
                 _ work: @escaping (TerminalRuntime) throws -> Void) {
        let runtime = runtime
        let context = preferredWorkspaceID
        queue.async { [weak self] in
            do {
                if let validateBeforeWork {
                    let allowed = DispatchQueue.main.sync { MainActor.assumeIsolated { validateBeforeWork() } }
                    guard allowed else { return }
                }
                let operation = { () throws -> RuntimeState? in
                    if restoringContext, let context, try runtime.state().layout.selectedWorkspaceID != context {
                        try runtime.update { state in
                            if state.layout.workspaces.contains(where: { $0.id == context && !$0.closed }) {
                                try state.layout.selectWorkspace(context)
                            }
                        }
                    }
                    try work(runtime)
                    return publishingSelectionBeforeObservation ? try runtime.state() : nil
                }
                let confirmedSelection = try holdingTransaction ? runtime.transaction(operation) : operation()
                if let confirmedSelection {
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.apply(confirmedSelection, sessions: self.sessions, takeSelection: restoringContext)
                        if restoringFocus { self.restoreTerminalFocus() }
                    }
                }
                let (state, sessions, decisions, usage, themes, terminal, developer, server, integrations) =
                    (try runtime.state(), try runtime.list(), try runtime.decisionInbox(), (try? runtime.accountUsage()) ?? [], try? runtime.themePreferences(),
                     try? runtime.terminalPreferences(), try? DeveloperSettingsStore(root: runtime.root).load(),
                     try? runtime.serverPreferences(), try? runtime.integrationsPreferences())
                DispatchQueue.main.async {
                    self?.decisionEntries = decisions
                    if let themes, self?.themePreferences != themes { self?.themePreferences = themes }
                    if let terminal, self?.terminalPreferences != terminal { self?.terminalPreferences = terminal }
                    if let developer, self?.developerPreferences != developer {
                        self?.developerPreferences = developer
                        UpdateController.shared.applyDeveloperPreferences(developer)
                    }
                    if let server, self?.serverPreferences != server { self?.serverPreferences = server }
                    if let integrations, self?.integrationsPreferences != integrations { self?.integrationsPreferences = integrations }
                    if self?.accountUsageSnapshots != usage { self?.accountUsageSnapshots = usage }
                    self?.apply(state, sessions: sessions, takeSelection: restoringContext)
                    if restoringFocus { self?.restoreTerminalFocus() }
                    completion?(nil)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let routing = error as? UnisessionNavigationError, case .requiresOverlay = routing, let reveal = self.onRevealSupervisor { reveal() }
                    else if let routing = error as? SupervisorNavigationError, case .requiresPanel = routing,
                       let reveal = self.onRevealSupervisor { reveal() }
                    else { self.message = error.localizedDescription }
                    self.loading = false
                    completion?(error)
                }
            }
        }
    }

    func refresh() { reloadInterfacePreferences(); reloadWorktreeCleanup(); reloadPessimisticTwins(); perform(restoringContext: false, holdingTransaction: false) { _ in } }

    func terminalTitleChanged(source: LocalProcessTerminalView) {
        guard externalPanePolicy == nil else { return }
        guard let view = source as? TranoView, terminalViews[view.paneID] === view else { return }
        titleRefreshGeneration &+= 1
        scheduleTitleRefresh()
    }

    private func scheduleTitleRefresh() {
        guard !titleRefreshPending else { return }
        titleRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            guard let self else { return }
            let generation = self.titleRefreshGeneration
            let runtime = self.runtime
            self.queue.async { [weak self] in
                let metadata = try? runtime.list()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.titleRefreshPending = false
                    defer { if self.titleRefreshGeneration != generation { self.scheduleTitleRefresh() } }
                    guard let metadata else { return }
                    let byID = Dictionary(metadata.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    let next = self.sessions.map { session in
                        guard let update = byID[session.id], update.pid == session.pid else { return session }
                        var value = session
                        value.terminalTitle = update.terminalTitle
                        return value
                    }
                    if self.sessions != next { self.sessions = next }
                }
            }
        }
    }

    func performHeaderAction(context: HeaderMenuContext, takeSelection: Bool, requiresUnmarkedInput: Bool = false,
                             _ work: @escaping (TerminalRuntime) throws -> Void) {
        guard headerMenuAllowsActions, context.matches(state.layout) else { return }
        if requiresUnmarkedInput {
            queue.async { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.headerInputCanNavigate else { return }
                    self.performHeaderAction(context: context, takeSelection: takeSelection, work)
                }
            }
            return
        }
        let runtime = runtime
        commandKeyHints.cancel()
        queue.async { [weak self] in
            do {
                let performed = try runtime.transaction {
                    guard context.matches(try runtime.state().layout) else { return false }
                    try work(runtime)
                    return true
                }
                let result = try performed ? (runtime.state(), runtime.list(), runtime.decisionInbox(), (try? runtime.accountUsage()) ?? []) : nil
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard let (state, sessions, decisions, usage) = result else { self.refresh(); return }
                    self.decisionEntries = decisions
                    if self.accountUsageSnapshots != usage { self.accountUsageSnapshots = usage }
                    let mayTakeSelection = takeSelection && self.headerInputCanNavigate
                    self.apply(state, sessions: sessions, takeSelection: mayTakeSelection)
                    if mayTakeSelection { self.zoomed = false; self.restoreTerminalFocus() }
                }
            } catch { DispatchQueue.main.async { self?.message = error.localizedDescription } }
        }
    }

    func finishWorkspaceTransfer(snapshot: RuntimeState, sessions: [TerminalSession], paneIDs: [String], destinationWorkspaceID: String) {
        guard externalPanePolicy == nil else { return }
        apply(snapshot, sessions: sessions, takeSelection: false)
        if preferredWorkspaceID != destinationWorkspaceID {
            for id in paneIDs where !floatingPaneIDs.contains(id) {
                if let view = terminalViews.removeValue(forKey: id) {
                    view.invalidateTerminalInteractions()
                    view.isHidden = true
                    view.terminate()
                }
            }
        }
        refresh()
    }
    private func scheduleRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
    }

    private var inputHasMarkedText: Bool {
        guard let id = focusedID, let window = terminalViews[id]?.window else { return false }
        return (window.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
    }

    private var inputHasNativeModal: Bool {
        let window = focusedID.flatMap { terminalViews[$0]?.window }
        return window?.attachedSheet != nil || NSApp.modalWindow != nil
    }

    private var headerInputCanNavigate: Bool {
        headerMenuAllowsActions && !inputHasMarkedText && !inputHasNativeModal
    }

    var safeInterfaceNavigation: Bool { headerInputCanNavigate }

    var canDragWorkspace: Bool { !loading && !inputHasMarkedText && !inputHasNativeModal }

    func applyExternalSnapshot(_ snapshot: RuntimeState, sessions: [TerminalSession]) {
        guard let policy = externalPanePolicy else { return }
        state = policy.project(snapshot)
        self.sessions = policy.sessions(sessions)
        decisionEntries = decisionEntries.filter { $0.paneID == policy.paneID }
        loading = false
        reconcileTerminalInteractionOwners()
    }

    func applyCapturedNavigation(_ snapshot: RuntimeState, sessions: [TerminalSession]) {
        apply(snapshot, sessions: sessions, takeSelection: true)
    }

    private func apply(_ snapshot: RuntimeState, sessions: [TerminalSession], takeSelection: Bool) {
        if externalPanePolicy != nil { applyExternalSnapshot(snapshot, sessions: sessions); return }
        var snapshot = snapshot
        let initialLoad = loading
        if loading, let initialWorkspaceID,
           snapshot.layout.workspaces.contains(where: { $0.id == initialWorkspaceID && !$0.closed }) {
            try? snapshot.layout.selectWorkspace(initialWorkspaceID)
        }
        let preserveInput = inputHasMarkedText || inputHasNativeModal
        let oldWorkspace = state.layout.selectedWorkspaceID
        let oldTab = state.layout.selectedTabID, oldPane = focusedID
        var next = selection.resolve(snapshot, ownAction: takeSelection && !preserveInput, acceptsRequests: isActiveWindow() && !preserveInput)
        if preserveInput, let oldTab, let tab = next.layout.tabs.first(where: { $0.id == oldTab }),
           next.layout.workspaces.contains(where: { $0.id == tab.workspaceID && !$0.closed }) {
            try? next.layout.selectTab(oldTab)
            if let oldPane, tab.panes.contains(oldPane) { try? next.layout.focusPane(oldPane) }
        }
        self.state = next
        refreshNotificationPreferences()
        self.sessions = sessions
        loading = false
        if oldWorkspace != next.layout.selectedWorkspaceID, let id = next.layout.selectedWorkspaceID {
            acknowledgeWorkspaceActivity(id)
        }
        let pendingIDs = Set(pendingDecisions.map(\.id))
        if decisionDrafts.keys.contains(where: { !pendingIDs.contains($0) }) {
            decisionDrafts = decisionDrafts.filter { pendingIDs.contains($0.key) }
        }
        if let id = preferredDecisionID, !pendingIDs.contains(id) { preferredDecisionID = nil }
        presentArrivedDecisions(initialLoad: initialLoad)
        floatingPanes.synchronize()
        let closed = Set(next.layout.workspaces.filter(\.closed).map(\.id))
        let attached = Set(next.layout.tabs.filter { !closed.contains($0.workspaceID ?? "") }.flatMap(\.panes))
        for (id, terminal) in terminalViews where !attached.contains(id) {
            terminal.invalidateTerminalInteractions()
            terminal.terminate()
            terminalViews.removeValue(forKey: id)
        }
        reconcileTerminalInteractionOwners()
        if takeSelection && !preserveInput { restoreTerminalFocus() }
    }

    var followUpItems: [FollowUpInput] {
        guard let paneID = followUpPaneID else { return [] }
        return state.followUpInputs.filter { $0.paneID == paneID }
    }

    var focusedFollowUpCount: Int { state.followUpInputs.filter { $0.paneID == focusedID }.count }
    var queuedInputShortcut: String {
        let binding = (try? TerminalKeySequenceMap(overrides: state.settings.keyBindings))?.bindings[ActionID.queuedInput.rawValue]?.first
        return binding.map(KeyBindingMap.display) ?? ""
    }
    var followUpPaneTitle: String { sessions.first { $0.id == followUpPaneID }?.title ?? "Pane" }
    var canSaveFollowUpDraft: Bool {
        followUpPaneID != nil && !followUpSaving && !followUpComposing && !followUpDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func toggleFollowUps(paneID: String? = nil) {
        if followUpPaneID != nil { dismissFollowUps() }
        else { openFollowUps(paneID: paneID) }
    }

    func openFollowUps(paneID: String? = nil) {
        if decisionPaneID != nil { dismissDecisions(); guard decisionPaneID == nil else { return } }
        guard followUpPaneID == nil else { focusFollowUpEditor(); return }
        guard let id = paneID ?? focusedID, selectedTab?.panes.contains(id) == true else { return }
        commandKeyHints.cancel()
        picker = nil
        showActivity = false
        followUpPresentationID = UUID()
        followUpEditingID = nil
        followUpDraft = ""
        followUpError = nil
        followUpComposing = false
        followUpPaneID = id
        terminalViews[id]?.window?.makeFirstResponder(nil)
        focusFollowUpEditor()
    }

    func dismissFollowUps() {
        guard followUpEditor?.hasMarkedText() != true else { return }
        followUpPresentationID = UUID()
        followUpPaneID = nil
        followUpEditingID = nil
        followUpDraft = ""
        followUpError = nil
        followUpComposing = false
        restoreTerminalFocus()
    }

    func cancelFollowUpDraft() {
        guard !followUpSaving, followUpEditor?.hasMarkedText() != true else { return }
        followUpEditingID = nil
        followUpDraft = ""
        followUpError = nil
        focusFollowUpEditor()
    }

    func editFollowUp(_ item: FollowUpInput) {
        guard item.paneID == followUpPaneID, item.status != .sending, !followUpSaving,
              followUpEditor?.hasMarkedText() != true else { return }
        followUpEditingID = item.id
        followUpDraft = item.text
        followUpError = nil
        focusFollowUpEditor()
    }

    func saveFollowUpDraft() {
        guard let paneID = followUpPaneID, !followUpSaving, followUpEditor?.hasMarkedText() != true else { return }
        let text = followUpDraft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            followUpError = "Enter a queued input."
            return
        }
        let editingID = followUpEditingID
        let revision = followUpDraftRevision
        mutateFollowUps({ runtime in
            if let editingID { _ = try runtime.updateFollowUp(id: editingID, text: text) }
            else { _ = try runtime.addFollowUp(paneID: paneID, text: text) }
        }) { store in
            if store.followUpDraftRevision == revision && store.followUpEditingID == editingID {
                store.followUpEditingID = nil
                store.followUpDraft = ""
            }
            store.focusFollowUpEditor()
        }
    }

    func removeFollowUp(_ item: FollowUpInput) {
        guard item.paneID == followUpPaneID, item.status != .sending, !followUpSaving,
              followUpEditor?.hasMarkedText() != true else { return }
        mutateFollowUps({ try $0.removeFollowUp(id: item.id) }) { store in
            if store.followUpEditingID == item.id {
                store.followUpEditingID = nil
                store.followUpDraft = ""
            }
        }
    }

    func resumeReviewedFollowUp(_ item: FollowUpInput) {
        guard item.paneID == followUpPaneID, item.status == .needsReview, !followUpSaving,
              followUpEditor?.hasMarkedText() != true else { return }
        mutateFollowUps({ try $0.reviewFollowUp(id: item.id) }) { store in store.dismissFollowUps() }
    }

    private func mutateFollowUps(_ mutation: @escaping (TerminalRuntime) throws -> Void, completion: @escaping (AppStore) -> Void) {
        let presentationID = followUpPresentationID
        let runtime = runtime
        followUpSaving = true
        followUpError = nil
        queue.async { [weak self] in
            do {
                let result = try runtime.transaction {
                    try mutation(runtime)
                    return (try runtime.state(), try runtime.list())
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.apply(result.0, sessions: result.1, takeSelection: false)
                    self.followUpSaving = false
                    if self.followUpPresentationID == presentationID { completion(self) }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.followUpSaving = false
                    if self.followUpPresentationID == presentationID { self.followUpError = error.localizedDescription }
                }
            }
        }
    }

    func focusFollowUpEditor() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.followUpPaneID != nil, !self.followUpSaving,
                  let editor = self.followUpEditor, let window = editor.window,
                  window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
            window.makeFirstResponder(editor)
        }
    }

    var pendingDecisions: [DecisionInboxEntry] { decisionEntries.filter { $0.status == "pending" } }
    var focusedDecisionCount: Int { pendingDecisions.filter { $0.paneID == focusedID }.count }
    var visibleDecisions: [DecisionInboxEntry] { pendingDecisions.filter { $0.paneID == decisionPaneID } }

    func openDecisions() {
        guard let id = pendingDecisions.first(where: { $0.paneID == focusedID })?.paneID ?? pendingDecisions.first?.paneID ?? focusedID else { return }
        if followUpPaneID != nil { dismissFollowUps(); guard followUpPaneID == nil else { return } }
        commandKeyHints.cancel()
        picker = nil
        showActivity = false
        decisionError = nil
        decisionArrivalCard = false
        decisionPaneID = id
        (focusedID.flatMap { terminalViews[$0]?.window } ?? NSApp.keyWindow)?.makeFirstResponder(nil)
    }

    // An agent that polls for the answer never ends its turn, so a card that waits for a click stays unseen.
    private func presentArrivedDecisions(initialLoad: Bool) {
        let pending = pendingDecisions
        // Questions that predate this window are reached through the Decisions button; opening them in every new window would cover it.
        if initialLoad { presentedDecisionIDs = Set(pending.map(\.id)); return }
        presentedDecisionIDs.formIntersection(pending.map(\.id))
        guard let entry = pending.last(where: { !presentedDecisionIDs.contains($0.id) }),
              isActiveWindow(), !decisionNavigationBusy, conversationResume == nil,
              !inputHasMarkedText, !inputHasNativeModal else { return }
        presentedDecisionIDs.formUnion(pending.map(\.id))
        preferredDecisionID = entry.id
        openDecisions()
        if decisionPaneID != nil { decisionPaneID = entry.paneID; decisionArrivalCard = true }
    }

    // A card this window opened by itself holds no user edit until a draft exists, so another window may navigate past it.
    private func yieldArrivalCard() {
        guard decisionArrivalCard, !visibleDecisions.contains(where: { decisionDrafts[$0.id] != nil }) else { return }
        dismissDecisions()
    }

    func dismissDecisions() {
        guard !decisionSaving, (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
        decisionPaneID = nil
        decisionError = nil
        restoreTerminalFocus()
    }

    func canNavigateToDecisionSession(_ entry: DecisionInboxEntry) -> Bool {
        pendingDecisions.contains { $0.id == entry.id && $0.paneID == entry.paneID && $0.generation == entry.generation } &&
        sessions.contains { $0.id == entry.paneID && $0.alive } &&
        state.agentLaunches.contains { $0.id == entry.generation && $0.paneID == entry.paneID && $0.lifecycle == .active }
    }

    private var decisionNavigationBusy: Bool {
        decisionPaneID != nil || followUpPaneID != nil || picker != nil || showSettings || showVoice ||
        showRemoteHosts || showAccounts || showExtensions || remotePathRequest != nil || message != nil
    }

    func goToDecisionSession(_ entry: DecisionInboxEntry, from sourceWindow: NSWindow?) {
        guard !decisionSaving, decisionPaneID == entry.paneID,
              (sourceWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return }
        guard canNavigateToDecisionSession(entry) else { decisionError = "The session for this question is no longer available."; return }
        let floating = WorkspaceOwners.floatingOwner(paneID: entry.paneID, root: runtime.root)
        if let floating, floating !== self { floating.yieldArrivalCard() }
        if let owner = floating, owner !== self, owner.decisionNavigationBusy {
            decisionError = "Finish editing in the session window before navigating."
            return
        }
        decisionSaving = true
        decisionError = nil
        let runtime = runtime
        queue.async { [weak self, weak sourceWindow] in
            do {
                let result = try runtime.transaction {
                    let paneID = try runtime.navigateToDecisionSession(entry.id, generation: entry.generation)
                    return (paneID, try runtime.state(), try runtime.list(), try runtime.decisionInbox())
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    let (paneID, state, sessions, entries) = result
                    guard let sourceWindow, sourceWindow.isVisible else { self.decisionSaving = false; return }
                    guard (sourceWindow.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else {
                        self.decisionSaving = false
                        self.decisionError = "Finish composing your answer before going to the session."
                        return
                    }
                    self.decisionEntries = entries
                    self.decisionSaving = false
                    let owner = WorkspaceOwners.floatingOwner(paneID: paneID, root: runtime.root)
                    if let owner, owner !== self { owner.yieldArrivalCard() }
                    if let owner, owner !== self, owner.decisionNavigationBusy {
                        self.decisionError = "Finish editing in the session window before navigating."
                        return
                    }
                    self.preferredDecisionID = entry.id
                    self.decisionPaneID = nil
                    if let owner, owner !== self {
                        owner.decisionEntries = entries
                        owner.preferredDecisionID = entry.id
                        for question in entries where question.paneID == paneID {
                            if let draft = self.decisionDrafts[question.id] { owner.decisionDrafts[question.id] = draft }
                        }
                        self.apply(state, sessions: sessions, takeSelection: false)
                        owner.apply(state, sessions: sessions, takeSelection: true)
                    } else { self.apply(state, sessions: sessions, takeSelection: true) }
                    if let owner { owner.floatingPanes.focus(paneID) }
                    else {
                        sourceWindow.contentView?.layoutSubtreeIfNeeded()
                        self.restoreTerminalFocus()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.decisionSaving = false
                    if let routing = error as? UnisessionNavigationError, case .requiresOverlay = routing,
                       let reveal = self.onRevealSupervisor, let sourceWindow, sourceWindow.isVisible,
                       sourceWindow.attachedSheet == nil,
                       (sourceWindow.firstResponder as? NSTextInputClient)?.hasMarkedText() != true {
                        self.preferredDecisionID = entry.id; self.decisionPaneID = nil; reveal()
                    }
                    else if let routing = error as? SupervisorNavigationError, case .requiresPanel = routing,
                       let reveal = self.onRevealSupervisor, let sourceWindow, sourceWindow.isVisible,
                       (sourceWindow.firstResponder as? NSTextInputClient)?.hasMarkedText() != true {
                        self.preferredDecisionID = entry.id
                        self.decisionPaneID = nil
                        reveal()
                    } else { self.decisionError = error.localizedDescription }
                }
            }
        }
    }

    func resolveDecision(_ entry: DecisionInboxEntry, action: String, optionID: String?, instruction: String?, locale: String?) {
        guard !decisionSaving, entry.paneID == decisionPaneID,
              (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
        decisionSaving = true
        decisionError = nil
        let runtime = runtime
        queue.async { [weak self] in
            do {
                if TwinDecisionID.isReserved(entry.id) { _ = try runtime.resolveTwinDecisionFromNative(entry.id, generation: entry.generation, action: action, optionID: optionID, instruction: instruction, locale: locale) }
                else { _ = try runtime.resolveDecision(entry.id, generation: entry.generation, action: action, optionID: optionID, instruction: instruction, locale: locale) }
                let entries = try runtime.decisionInbox()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.decisionEntries = entries
                    self.decisionDrafts.removeValue(forKey: entry.id)
                    self.decisionSaving = false
                    if self.visibleDecisions.isEmpty { self.dismissDecisions() }
                }
            } catch {
                DispatchQueue.main.async { self?.decisionSaving = false; self?.decisionError = error.localizedDescription }
            }
        }
    }

    func newTab() { execute(.newTab) }

    func openRemoteHosts() {
        picker = nil
        showActivity = false
        showRemoteHosts = true
    }

    func newSession(title: String? = nil) {
        picker = nil; zoomed = false
        perform { try $0.performAction(.newSession, title: title) }
    }

    func dismissPicker() {
        picker = nil
        restoreTerminalFocus()
    }

    func restoreTerminalFocus(returningTo window: NSWindow? = nil) {
        pendingTerminalFocusID = focusedID
        pendingTerminalFocusReturnWindow = window.map(ObjectIdentifier.init)
        DispatchQueue.main.async { [weak self] in self?.completePendingTerminalFocus() }
    }

    func completePendingTerminalFocus() {
        guard let id = pendingTerminalFocusID else { return }
        guard focusedID == id, decisionPaneID == nil, followUpPaneID == nil, picker == nil, conversationResume == nil,
              !showActivity, !showSettings, !showVoice, !showRemoteHosts, !showAccounts, !showExtensions,
              remotePathRequest == nil, NSApp.modalWindow == nil else {
            pendingTerminalFocusID = nil
            return
        }
        guard let view = terminalViews[id], let window = view.window else { return }
        if let returnWindow = pendingTerminalFocusReturnWindow {
            guard ObjectIdentifier(window) == returnWindow,
                  window.firstResponder == nil || window.firstResponder === window ||
                  window.firstResponder is TranoView else {
                pendingTerminalFocusID = nil
                return
            }
        }
        guard window.attachedSheet == nil, (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else {
            pendingTerminalFocusID = nil
            return
        }
        if let responder = window.firstResponder as? NSView, responder !== view {
            let editorOwner = (responder as? NSTextView)?.delegate as? NSView
            if responder.isDescendant(of: view) || editorOwner?.isDescendant(of: view) == true {
                pendingTerminalFocusID = nil
                return
            }
        }
        if window.makeFirstResponder(view) { pendingTerminalFocusID = nil }
    }

    func newTab(at directory: String) { perform { try $0.performAction(.newTab, cwd: directory) } }

    func split(_ axis: SplitAxis) {
        guard let tab = selectedTab else { newTab(); return }
        let cwd = currentDirectory
        perform { runtime in
            let session = try runtime.create(title: "Shell", cwd: cwd)
            do { try runtime.update { try $0.layout.split(tabID: tab.id, paneID: session.id, axis: axis) } }
            catch { try? runtime.terminate(session.id); throw error }
        }
    }

    var canFocusPaneFromPointer: Bool {
        !loading && conversationResume == nil && decisionPaneID == nil && followUpPaneID == nil && picker == nil &&
        !showActivity && !showSettings && !showVoice && !showRemoteHosts && !showAccounts && !showExtensions && remotePathRequest == nil
    }

    func focus(_ id: String, in window: NSWindow? = nil) {
        if let window {
            guard canFocusPaneFromPointer, window.isVisible, !window.isMiniaturized, window.attachedSheet == nil, NSApp.modalWindow == nil,
                  (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true,
                  let view = terminalViews[id], view.store === self, view.window === window, !view.isHiddenOrHasHiddenAncestor,
                  selectedTab?.panes.contains(id) == true || floatingPanes.paneID(in: window) == id,
                  window.makeFirstResponder(view) else { return }
        }
        acknowledgeActivity(id)
        guard focusedID != id else { return }
        try? state.layout.focusPane(id)
        perform(publishingSelectionBeforeObservation: window != nil) { try $0.update { try $0.layout.focusPane(id) } }
    }

    func selectTab(_ id: String) {
        if let tab = state.layout.tabs.first(where: { $0.id == id }), let pane = tab.focusedPaneID ?? tab.panes.first { acknowledgeActivity(pane) }
        zoomed = false
        let presented = state.layout.isPresentedInMasterView(id)
        perform(publishingSelectionBeforeObservation: true) {
            try $0.update { presented ? try $0.layout.selectPresentedTab(id) : try $0.layout.selectTab(id) }
        }
    }

    func selectWorkspace(_ id: String) {
        picker = nil; zoomed = false
        perform(completion: { [weak self] error in
            if error == nil { self?.acknowledgeWorkspaceActivity(id) }
        }) { try $0.update { try $0.layout.selectWorkspace(id) } }
    }

    func closeTab(_ id: String, sourceWindow: NSWindow? = nil) {
        guard safeInterfaceNavigation, let tab = state.layout.tabs.first(where: { $0.id == id }),
              let inputID = focusedID, let inputView = terminalViews[inputID], let inputWindow = inputView.window,
              let owner = sourceWindow ?? floatingPanes.presentationOwner(for: inputWindow) else { return }
        let context = HeaderMenuContext(workspaceID: tab.workspaceID, tabID: tab.id,
                                        paneID: tab.focusedPaneID ?? tab.panes.first)
        let workspaceID = preferredWorkspaceID
        performCapturedClose(.closeTab, context: context, validateInput: { [weak self, weak owner, weak inputView, weak inputWindow, weak inputResponder = owner.firstResponder] in
            guard let self, let owner, let inputView, let inputWindow,
                  self.focusedID == inputID, self.preferredWorkspaceID == workspaceID,
                  self.terminalViews[inputID] === inputView, inputView.store === self, inputView.window === inputWindow,
                  self.floatingPanes.presentationOwner(for: inputWindow) === owner, owner.firstResponder === inputResponder,
                  owner.isVisible, !owner.isMiniaturized, owner.isKeyWindow, owner.attachedSheet == nil, NSApp.modalWindow == nil,
                  (owner.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return false }
            return true
        })
    }

    var closeConfirmationModal: (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }

    func performCapturedClose(_ action: ActionID, context: HeaderMenuContext, validateInput: (() -> Bool)? = nil) {
        guard context.matches(state.layout) else { return }
        if let reason = CloseConfirmation.reason(action, context: context, state: state, sessions: sessions,
                                                 preferGeneratedTitles: terminalPreferences.preferGeneratedTitles) {
            guard CloseConfirmation.confirm(reason, runModal: closeConfirmationModal), context.matches(state.layout) else { return }
        }
        zoomed = false
        perform(restoringContext: false, holdingTransaction: false, restoringFocus: true, validateBeforeWork: { [weak self] in
            self?.safeInterfaceNavigation == true && (validateInput?() ?? true)
        }, completion: { [weak self] error in
            if error != nil { self?.refresh() }
        }) { runtime in
            guard context.matches(try runtime.state().layout) else { return }
            let validate: (RuntimeState) throws -> Void = { state in
                guard context.matches(state.layout) else { throw TerminalError.invalid("The terminal close target changed") }
            }
            switch action {
            case .closeTab:
                if let id = context.tabID { try runtime.closeTerminalTab(id, validate: validate) }
            case .closePane:
                if let id = context.paneID { try runtime.closeTerminalPane(id, validate: validate) }
            case .closeOtherTabs:
                if let id = context.tabID { try runtime.closeOtherTerminalTabs(keeping: id, validate: validate) }
            case .closeTabsToLeft, .closeTabsToRight:
                if let id = context.tabID { try runtime.closeTerminalTabs(beside: id, side: action == .closeTabsToLeft ? .left : .right, validate: validate) }
            case .closeOtherPanes:
                if let id = context.paneID { try runtime.closeOtherTerminalPanes(keeping: id, validate: validate) }
            default: break
            }
        }
    }

    func closeWorkspace(_ id: String, validateBeforeWork: (@MainActor () -> Bool)? = nil) {
        guard followUpPaneID == nil, decisionPaneID == nil,
              state.layout.workspaces.contains(where: { $0.id == id && !$0.closed }) else { return }
        commandKeyHints.cancel()
        if state.layout.selectedWorkspaceID == id { zoomed = false }
        let runtime = runtime
        queue.async { [weak self] in
            let allowed = DispatchQueue.main.sync { MainActor.assumeIsolated {
                guard let self, self.followUpPaneID == nil, self.decisionPaneID == nil else { return false }
                return validateBeforeWork?() ?? true
            } }
            guard allowed else { return }
            do {
                let snapshot = try runtime.transaction { () -> RuntimeState? in
                    guard try runtime.state().layout.workspaces.contains(where: { $0.id == id && !$0.closed }) else { return nil }
                    try runtime.update { $0.layout.closeWorkspace(id) }
                    return try runtime.state()
                }
                DispatchQueue.main.async {
                    guard let self, let snapshot else { return }
                    self.apply(snapshot, sessions: self.sessions, takeSelection: false)
                    self.restoreTerminalFocus()
                }
            } catch { DispatchQueue.main.async { self?.message = error.localizedDescription } }
        }
    }

    func attach(_ id: String) {
        acknowledgeActivity(id)
        picker = nil
        let runtime = runtime
        perform { try $0.update { state in
            guard state.sessions.contains(where: { $0.id == id }) else { throw TerminalError.invalid("Unknown session") }
            try runtime.requireOrdinaryPane(id,
                attachedPaneIDs: Set((state.layout.tabs + state.layout.closedTabs).flatMap(\.panes)))
            if state.layout.tabs.contains(where: { $0.panes.contains(id) }) {
                try state.layout.focusPane(id)
            } else { state.layout.addTab(paneID: id) }
        } }
    }

    private func refreshNotificationPreferences() {
        guard !notificationPreferenceRefreshPending else { return }
        notificationPreferenceRefreshPending = true
        let root = runtime.root
        queue.async { [weak self] in
            let preferences = try? NotificationPreferencesStore(root: root).read()
            DispatchQueue.main.async {
                guard let self else { return }
                self.notificationPreferenceRefreshPending = false
                guard let preferences else { return }
                if self.notificationPreferences != preferences { self.notificationPreferences = preferences }
                let count = NotificationPolicy.dockBadgeCount(layout: self.state.layout, sessions: self.sessions,
                                                             readAt: self.state.activityReadAt, preferences: preferences)
                let label = count > 0 ? String(count) : nil
                if NSApplication.shared.dockTile.badgeLabel != label { NSApplication.shared.dockTile.badgeLabel = label }
            }
        }
    }

    func acknowledgeActivity(_ id: String) {
        acknowledgeActivities(sessions.filter { $0.id == id })
    }

    private func acknowledgeWorkspaceActivity(_ id: String) {
        guard state.layout.selectedWorkspaceID == id else { return }
        let paneIDs = Set(state.layout.tabs.filter { $0.workspaceID == id }.flatMap(\.panes))
        acknowledgeActivities(sessions.filter { paneIDs.contains($0.id) })
    }

    private func acknowledgeActivities(_ panes: [TerminalSession]) {
        let events = Dictionary(panes.filter {
            ActivityInbox.isUnread($0, readAt: state.activityReadAt[$0.id])
        }.map { ($0.id, $0.activity.updatedAt) }, uniquingKeysWith: max)
        guard !events.isEmpty else { return }
        let runtime = runtime
        queue.async { [weak self] in
            do {
                let acknowledged = try runtime.acknowledgeActivities(events)
                DispatchQueue.main.async {
                    guard let self, !acknowledged.isEmpty else { return }
                    self.state.activityReadAt.merge(acknowledged, uniquingKeysWith: max)
                    self.refreshNotificationPreferences()
                }
            } catch { DispatchQueue.main.async { self?.message = error.localizedDescription } }
        }
    }

    var activityNeedsAttention: Bool {
        activityIndicatorEvents.contains { seenActivityEvents[$0.key] != $0.value }
    }

    var activityIndicatorEvents: [ActivityIndicatorKey: Date] {
        var events: [ActivityIndicatorKey: Date] = [:]
        // Same membership as the Activity rows: a closed pane has no row, so it must not light the indicator.
        let closed = state.layout.closedPaneIDs
        for pane in sessions where !closed.contains(pane.id) && ActivityInbox.isUnread(pane, readAt: state.activityReadAt[pane.id]) {
            events[.pane(pane.id, pane.activity.state.rawValue)] = pane.activity.updatedAt
        }
        for record in worktreeCleanupRecords where [.held, .error, .needsReview].contains(record.status) {
            events[.worktree(record.id, record.status.rawValue)] = record.updatedAt
        }
        return events
    }

    func acknowledgeActivityInbox(_ presented: [ActivityIndicatorKey: Date]) {
        guard showActivity else { return }
        let current = activityIndicatorEvents
        var seen = seenActivityEvents.filter { current[$0.key] == $0.value }
        for (key, timestamp) in presented where current[key] == timestamp { seen[key] = timestamp }
        if seenActivityEvents != seen { seenActivityEvents = seen }
    }

    func authorizeNotifications() {
        perform { runtime in
            let result = try APIClient(path: runtime.root.appendingPathComponent("api.sock").path).call(APIRequest(method: "notifications.authorize"))
            if let error = result.error { throw TerminalError.runtime(error) }
        }
    }

    func detach() {
        guard let id = focusedID else { return }
        perform { try $0.update { $0.layout.detach(id) } }
    }

    func terminate(_ id: String) {
        let alert = NSAlert()
        alert.messageText = "Terminate this session?"
        alert.informativeText = "The shell and its running jobs will stop."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Terminate")
        if alert.runModal() == .alertSecondButtonReturn { perform { try $0.terminate(id) } }
    }

    func move(_ paneID: String, to tabID: String) {
        perform { try $0.update { try $0.layout.move(paneID: paneID, to: tabID) } }
    }

    func resizeSplit(_ id: String, ratio: Double) {
        perform { runtime in
            try runtime.markInterfaceSplitManuallyResized(id)
            try runtime.update { try $0.layout.resize(splitID: id, ratio: ratio) }
        }
    }

    func resizeFocused(_ direction: PaneResizeDirection) {
        guard let pane = focusedID, let target = selectedTab?.tree.resizeTarget(paneID: pane, direction: direction) else { return }
        resizeSplit(target.splitID, ratio: target.ratio)
    }

    func focusDirection(horizontal: Double, vertical: Double) {
        guard let id = focusedID, let current = terminalViews[id], let window = current.window else { return }
        let origin = current.convert(current.bounds, to: nil)
        let candidates = (selectedTab?.panes ?? []).compactMap { candidate -> (String, Double)? in
            guard candidate != id, let view = terminalViews[candidate], view.window === window else { return nil }
            let rect = view.convert(view.bounds, to: nil)
            let dx = rect.midX - origin.midX, dy = rect.midY - origin.midY
            guard dx * horizontal + dy * vertical > 1 else { return nil }
            return (candidate, hypot(dx, dy))
        }
        if let next = candidates.min(by: { $0.1 < $1.1 }) { focus(next.0) }
    }

    func find(_ action: NSFindPanelAction = .showFindPanel) {
        guard let id = focusedID else { return }
        let item = NSMenuItem()
        item.tag = Int(action.rawValue)
        terminalViews[id]?.performFindPanelAction(item)
    }

    func moveToNewTab() {
        guard let id = focusedID else { return }
        perform { try $0.update { $0.layout.detach(id); $0.layout.addTab(paneID: id) } }
    }

    func cyclePane(_ delta: Int) {
        guard let panes = selectedTab?.panes, !panes.isEmpty else { return }
        let current = panes.firstIndex(of: focusedID ?? "") ?? 0
        focus(panes[(current + delta + panes.count) % panes.count])
    }

    func cycleTab(_ delta: Int) { execute(delta > 0 ? .nextTab : .previousTab) }

    func fontSize(_ delta: Double) {
        let paneID = focusedID
        perform(validateBeforeWork: { [weak self] in
            self?.focusedID == paneID && self?.safeInterfaceNavigation == true
        }) { runtime in
            let settings = try runtime.state().settings
            let preferences = try runtime.terminalPreferences()
            let plan = try TerminalFontAdjustmentPlan.make(delta: delta, settings: settings, preferences: preferences, paneID: paneID)
            try runtime.update { $0.settings.merge(plan.settings, from: settings) }
            try runtime.saveTerminalPreferences(plan.preferences, from: preferences)
        }
    }

    func saveSettings(_ settings: TerminalSettings, from baseline: TerminalSettings? = nil,
                      themes: ThemePreferences? = nil, themeBaseline: ThemePreferences? = nil,
                      notifications: NotificationPreferences? = nil, notificationBaseline: NotificationPreferences? = nil,
                      interface: InterfacePreferences? = nil, interfaceBaseline: InterfacePreferences? = nil,
                      terminal: TerminalPreferences? = nil, terminalBaseline: TerminalPreferences? = nil,
                      developer: DeveloperPreferences? = nil, developerBaseline: DeveloperPreferences? = nil,
                      completion: ((Error?) -> Void)? = nil) {
        let baseline = baseline ?? state.settings
        let previousDeveloper = developerBaseline ?? developerPreferences
        let refreshHelper = developer.map {
            $0.installationLocation != previousDeveloper.installationLocation || $0.sourceDirectory != previousDeveloper.sourceDirectory
        } ?? false
        perform(completion: { [weak self] error in
            if error == nil, refreshHelper, let self { BackgroundService.start(runtime: self.runtime) }
            completion?(error)
        }) { runtime in
            _ = try TerminalKeySequenceMap(overrides: settings.keyBindings)
            if let terminal {
                var checked = try runtime.terminalPreferences()
                checked.merge(terminal, from: terminalBaseline ?? checked)
                try checked.validate()
            }
            if let developer {
                try developer.validate()
                if developer.installationLocation == .sourceCheckout {
                    _ = try DeveloperInstallationInspector.sourceBundle(directory: URL(fileURLWithPath: developer.sourceDirectory))
                }
                _ = try DeveloperSettingsStore(root: runtime.root).load()
            }
            if let interface {
                try interface.validate()
                let current = try runtime.interfacePreferences()
                if let interfaceBaseline {
                    var draft = InterfacePreferencesDraft(interfaceBaseline)
                    draft.value = interface
                    _ = try draft.applying(to: current)
                }
            }
            if let themes {
                try themes.validate()
                var checked = try runtime.themePreferences()
                if let themeBaseline { try checked.merge(themes, from: themeBaseline) }
            }
            if let notifications {
                try notifications.validate()
                var checked = try runtime.notificationPreferences()
                if let notificationBaseline { try notificationBaseline.validate(); checked.merge(notifications, from: notificationBaseline); try checked.validate() }
            }
            try runtime.update { $0.settings.merge(settings, from: baseline) }
            if settings.persistScrollback != baseline.persistScrollback { try runtime.setScrollbackPersistence(settings.persistScrollback) }
            if let themes { try runtime.saveThemePreferences(themes, baseline: themeBaseline) }
            if let notifications { try runtime.saveNotificationPreferences(notifications, from: notificationBaseline) }
            if let interface { try runtime.saveInterfacePreferences(interface, baseline: interfaceBaseline) }
            if let terminal { try runtime.saveTerminalPreferences(terminal, from: terminalBaseline ?? runtime.terminalPreferences()) }
            if let developer {
                _ = try DeveloperSettingsStore(root: runtime.root).merge(baseline: developerBaseline ?? DeveloperSettingsStore(root: runtime.root).load(), edited: developer)
            }
        }
        if settings.persistScrollback != baseline.persistScrollback {
            let hosts = state.remoteHosts, runtime = runtime
            queue.async {
                for host in hosts {
                    do { _ = try RemoteClient(host: host).call(APIRequest(method: "scrollback.settings", params: ["enabled": .bool(settings.persistScrollback)])) }
                    catch { DispatchQueue.main.async { self.message = "Scrollback preference could not reach " + host.name + ": " + error.localizedDescription } }
                }
            }
        }
    }

    var onNewWindow: (() -> Void)?
    var onCloseWindow: (() -> Void)?

    func execute(_ action: ActionID, sourceWindow: NSWindow? = nil) {
        guard externalPanePolicy == nil else { return }
        commandKeyHints.interrupt()
        if action == .resumeConversation { picker = nil; toggleConversationResume(); return }
        guard conversationResume == nil else { return }
        if action == .pessimisticTwin, decisionPaneID == nil, followUpPaneID == nil { picker = nil; if let id = focusedID { toggleTwinModePicker(paneID: id) }; return }
        if action == .queuedInput, decisionPaneID == nil { toggleFollowUps(); return }
        guard decisionPaneID == nil, followUpPaneID == nil else { return }
        if action == .closePane && focusedID == nil || action == .closeTab && selectedTab == nil {
            guard safeInterfaceNavigation else { return }
            if let id = state.layout.selectedWorkspaceID,
               state.layout.workspaces.contains(where: { $0.id == id && !$0.closed }) {
                let owner = sourceWindow
                let ownsWindow = owner != nil
                closeWorkspace(id, validateBeforeWork: { [weak self, weak owner, weak responder = owner?.firstResponder] in
                    guard self?.safeInterfaceNavigation == true else { return false }
                    return !ownsWindow || (owner?.isVisible == true && owner?.attachedSheet == nil &&
                        owner?.firstResponder === responder && (owner?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true)
                })
            } else { onCloseWindow?() }
            return
        }
        defer { restoreTerminalFocus() }
        let view = focusedID.flatMap { terminalViews[$0] }
        switch action {
        case .closePane, .closeTab, .closeOtherPanes, .closeOtherTabs, .closeTabsToLeft, .closeTabsToRight:
            guard let tab = selectedTab else { return }
            let paneID = focusedID
            let context = HeaderMenuContext(workspaceID: tab.workspaceID, tabID: tab.id, paneID: paneID)
            let ownsWindow = sourceWindow != nil
            performCapturedClose(action, context: context, validateInput: { [weak owner = sourceWindow, weak responder = sourceWindow?.firstResponder] in
                !ownsWindow || (owner?.isVisible == true && owner?.isMiniaturized == false && owner?.isKeyWindow == true &&
                    owner?.attachedSheet == nil && owner?.firstResponder === responder &&
                    (owner?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true)
            })
        case .resumeConversation, .pessimisticTwin: break
        case .newWindow: onNewWindow?()
        case .newSession: newSession()
        case .fullscreen: view?.window?.toggleFullScreen(nil)
        case .palette: picker = .commands
        case .switchSession: picker = .sessions
        case .closeSession: if let id = state.layout.selectedWorkspaceID { closeWorkspace(id) }
        case .goToAnything: picker = .anything
        case .movePaneTab: picker = .movePane
        case .settings: showSettings = true
        case .voice: showVoice = true
        case .urlHints:
            if let hints = view?.urlHints {
                if hints.isActive { hints.dismiss() }
                else { hints.start() }
            }
        case .resizeLeft: resizeFocused(.left)
        case .resizeRight: resizeFocused(.right)
        case .resizeUp: resizeFocused(.up)
        case .resizeDown: resizeFocused(.down)
        case .activity: showActivity.toggle()
        case .zoom: zoomed.toggle()
        case .increaseFont: fontSize(1)
        case .decreaseFont: fontSize(-1)
        case .resetFont: fontSize(0)
        case .floatPane: if let id = focusedID { floatingPanes.toggle(id) }
        case .focusLeft: focusDirection(horizontal: -1, vertical: 0)
        case .focusRight: focusDirection(horizontal: 1, vertical: 0)
        case .focusUp: focusDirection(horizontal: 0, vertical: 1)
        case .focusDown: focusDirection(horizontal: 0, vertical: -1)
        case .copy: view?.copy(self)
        case .paste: view?.paste(self)
        case .selectAll: view?.selectAllWithTerminalPreferences(self)
        case .clear: view?.clearScrollback()
        case .find: find()
        case .findNext: find(.next)
        case .findPrevious: find(.previous)
        case .copyPaneID:
            if let id = focusedID { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(id, forType: .string) }
        case .insertPath: pickPath(directoryOnly: false)
        case .goToDirectory: pickPath(directoryOnly: true)
        case .renameSession, .renameTab, .renamePane: rename(action)
        case .restoreSessions:
            perform(restoringContext: false, holdingTransaction: false) { _ = try $0.recoverSessions() }
        case .restoreTab:
            zoomed = false
            perform(holdingTransaction: false, restoringFocus: true, validateBeforeWork: { [weak self] in self?.headerInputCanNavigate == true }) {
                try $0.restoreClosedTerminal()
            }
        default:
            zoomed = false
            perform { try $0.performAction(action) }
        }
    }

    private func pickPath(directoryOnly: Bool) {
        guard let id = focusedID, let view = terminalViews[id], let owner = view.interactionOwner(),
              let lease = view.interactionLease(for: owner) else { return }
        if let pane = sessions.first(where: { $0.id == id }), let reference = pane.remote {
            remotePathRequest = RemotePathRequest(paneID: id, hostID: reference.hostID, path: pane.cwd, directoryOnly: directoryOnly, owner: owner)
            return
        }
        let runtime = runtime
        queue.async { [weak self] in
            guard lease.isValid else { return }
            let result = Result { () -> (String?, TerminalPreferences, [TerminalRecentPath]) in
                let cwd = try? runtime.workingDirectory(id)
                return try runtime.transaction {
                    guard lease.isValid, try runtime.state().sessions.contains(where: { $0.id == id && $0.pid == lease.sessionPID && $0.remote == nil }) else { throw TerminalError.invalid("Terminal session changed") }
                    return (cwd, try runtime.terminalPreferences(), try runtime.recentTerminalPaths())
                }
            }
            DispatchQueue.main.async {
                guard let self, let view = self.terminalViews[id], view.interactionOwner() == owner,
                      let window = view.window else { return }
                switch result {
                case .failure(let error): self.message = error.localizedDescription
                case .success(let (cwd, preferences, recent)):
                    let panel = self.makeTerminalPathPanel(directoryOnly: directoryOnly,
                        directory: cwd ?? self.currentDirectory, recentPaths: recent, preferences: preferences, owner: owner)
                    panel.beginSheetModal(for: window) { [weak self, weak view] result in
                        guard let self, let view, result == .OK, view.interactionOwner() == owner else { return }
                        let paths = panel.urls.map(\.path)
                        if directoryOnly, let path = paths.first {
                            self.perform(validateBeforeWork: { lease.isValid }) { runtime in
                                guard lease.isValid, try runtime.state().sessions.contains(where: { $0.id == id && $0.pid == lease.sessionPID }) else { throw TerminalError.invalid("Terminal session changed") }
                                try runtime.performAction(.newTab, cwd: path, paneID: id)
                                try runtime.recordTerminalPath(path)
                            }
                        } else {
                            do {
                                view.pasteText(try PathInsertion.text(paths: paths))
                                self.recordTerminalPaths(paths, hostID: nil, owner: owner)
                            } catch { self.message = error.localizedDescription }
                        }
                    }
                }
            }
        }
    }

    func insertImage(_ data: Data, paneID: String) {
        guard let target = DeferredTerminalInputTarget.capture(store: self, paneID: paneID) else { return }
        enqueueImage(data, target: target)
    }

    func toggleCollapse(_ id: String) {
        perform { try $0.update { state in
            if let index = state.layout.workspaces.firstIndex(where: { $0.id == id }) { state.layout.workspaces[index].collapsed.toggle() }
        } }
    }

    func commitHeaderRename(_ action: ActionID, name: String, context: HeaderMenuContext) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200, action == .renameSession || action == .renameTab else { return }
        performHeaderAction(context: context, takeSelection: false) { try $0.update { state in
            if action == .renameSession, let index = state.layout.workspaces.firstIndex(where: { $0.id == context.workspaceID }) {
                state.layout.workspaces[index].title = name
            } else if action == .renameTab, let index = state.layout.tabs.firstIndex(where: { $0.id == context.tabID }) {
                state.layout.tabs[index].title = name
            }
        } }
    }

    func rename(_ action: ActionID, target: String? = nil, headerContext: HeaderMenuContext? = nil, onCommit: ((String) -> Void)? = nil) {
        let workspaceID = action == .renameSession ? target ?? state.layout.selectedWorkspaceID : state.layout.selectedWorkspaceID
        let tabID = action == .renameTab ? target ?? state.layout.selectedTabID : state.layout.selectedTabID
        let paneID = action == .renamePane ? target ?? focusedID : focusedID
        let old: String
        switch action {
        case .renameSession: old = state.layout.workspaces.first { $0.id == workspaceID }?.title ?? ""
        case .renameTab: old = state.layout.tabs.first { $0.id == tabID }?.title ?? ""
        default: old = sessions.first { $0.id == paneID }?.title ?? ""
        }
        let alert = NSAlert()
        alert.messageText = ActionCatalog.all.first { $0.action == action }?.title ?? "Rename"
        let field = NSTextField(string: old)
        field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200 else { message = "Use a name between 1 and 200 characters."; return }
        if let onCommit { onCommit(name); return }
        if let headerContext { commitHeaderRename(action, name: name, context: headerContext); return }
        perform { try $0.update { state in
            switch action {
            case .renameSession:
                if let index = state.layout.workspaces.firstIndex(where: { $0.id == workspaceID }) { state.layout.workspaces[index].title = name }
            case .renameTab:
                if let index = state.layout.tabs.firstIndex(where: { $0.id == tabID }) { state.layout.tabs[index].title = name }
            default:
                if let index = state.sessions.firstIndex(where: { $0.id == paneID }) { state.sessions[index].title = name }
            }
        } }
    }

    var commands: [(String, String, () -> Void)] {
        ActionCatalog.all.map { command in (command.title, command.shortcut, { self.execute(command.action) }) }
    }
}
