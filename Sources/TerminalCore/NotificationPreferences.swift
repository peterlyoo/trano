import Foundation
import Darwin

public enum NotificationPosition: String, Codable, CaseIterable {
    case topLeft, topCenter, topRight, bottomLeft, bottomCenter, bottomRight
}

public struct NotificationChannels: Codable, Equatable {
    public var enabled = true
    public var tabIndicator = true
    public var systemNotification = true
    public var dockBadge = true
    public var sound = true
    public init(enabled: Bool = true, tabIndicator: Bool = true, systemNotification: Bool = true,
                dockBadge: Bool = true, sound: Bool = true) {
        self.enabled = enabled; self.tabIndicator = tabIndicator; self.systemNotification = systemNotification
        self.dockBadge = dockBadge; self.sound = sound
    }
    private enum CodingKeys: String, CodingKey { case enabled, tabIndicator, systemNotification, dockBadge, sound }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        tabIndicator = try values.decodeIfPresent(Bool.self, forKey: .tabIndicator) ?? tabIndicator
        systemNotification = try values.decodeIfPresent(Bool.self, forKey: .systemNotification) ?? systemNotification
        dockBadge = try values.decodeIfPresent(Bool.self, forKey: .dockBadge) ?? dockBadge
        sound = try values.decodeIfPresent(Bool.self, forKey: .sound) ?? sound
    }
    mutating func merge(_ draft: NotificationChannels, from baseline: NotificationChannels) {
        if draft.enabled != baseline.enabled { enabled = draft.enabled }
        if draft.tabIndicator != baseline.tabIndicator { tabIndicator = draft.tabIndicator }
        if draft.systemNotification != baseline.systemNotification { systemNotification = draft.systemNotification }
        if draft.dockBadge != baseline.dockBadge { dockBadge = draft.dockBadge }
        if draft.sound != baseline.sound { sound = draft.sound }
    }
}

public struct NotificationPreferences: Codable, Equatable {
    public var position = NotificationPosition.topRight
    public var showActivityInTabs = true
    public var includeIdleProcesses = true
    public var showEachProcessInTabs = true
    public var systemNotifications = true
    public var badgeDockIcon = false
    public var playSounds = true
    public var soundVolume: Double = 1
    public var working = NotificationChannels(tabIndicator: false, systemNotification: false, dockBadge: false, sound: false)
    public var blocked = NotificationChannels()
    public var error = NotificationChannels()
    public var done = NotificationChannels()
    public var terminalNotifications = false
    public var tailscaleSignIn = true
    public var tailscaleDeviceApproval = true
    public var tailscaleFailures = true
    public var quotaLowEnabled = true
    public var quotaResetEnabled = true
    public var quotaLowRemainingPercent: Double = 10
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case position, showActivityInTabs, includeIdleProcesses, showEachProcessInTabs, systemNotifications
        case badgeDockIcon, playSounds, soundVolume, working, blocked, error, done, terminalNotifications
        case tailscaleSignIn, tailscaleDeviceApproval, tailscaleFailures, quotaLowEnabled, quotaResetEnabled, quotaLowRemainingPercent
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        position = try values.decodeIfPresent(NotificationPosition.self, forKey: .position) ?? position
        showActivityInTabs = try values.decodeIfPresent(Bool.self, forKey: .showActivityInTabs) ?? showActivityInTabs
        includeIdleProcesses = try values.decodeIfPresent(Bool.self, forKey: .includeIdleProcesses) ?? includeIdleProcesses
        showEachProcessInTabs = try values.decodeIfPresent(Bool.self, forKey: .showEachProcessInTabs) ?? showEachProcessInTabs
        systemNotifications = try values.decodeIfPresent(Bool.self, forKey: .systemNotifications) ?? systemNotifications
        badgeDockIcon = try values.decodeIfPresent(Bool.self, forKey: .badgeDockIcon) ?? badgeDockIcon
        playSounds = try values.decodeIfPresent(Bool.self, forKey: .playSounds) ?? playSounds
        soundVolume = try values.decodeIfPresent(Double.self, forKey: .soundVolume) ?? soundVolume
        working = try values.decodeIfPresent(NotificationChannels.self, forKey: .working) ?? working
        blocked = try values.decodeIfPresent(NotificationChannels.self, forKey: .blocked) ?? blocked
        error = try values.decodeIfPresent(NotificationChannels.self, forKey: .error) ?? error
        done = try values.decodeIfPresent(NotificationChannels.self, forKey: .done) ?? done
        terminalNotifications = try values.decodeIfPresent(Bool.self, forKey: .terminalNotifications) ?? terminalNotifications
        tailscaleSignIn = try values.decodeIfPresent(Bool.self, forKey: .tailscaleSignIn) ?? tailscaleSignIn
        tailscaleDeviceApproval = try values.decodeIfPresent(Bool.self, forKey: .tailscaleDeviceApproval) ?? tailscaleDeviceApproval
        tailscaleFailures = try values.decodeIfPresent(Bool.self, forKey: .tailscaleFailures) ?? tailscaleFailures
        quotaLowEnabled = try values.decodeIfPresent(Bool.self, forKey: .quotaLowEnabled) ?? quotaLowEnabled
        quotaResetEnabled = try values.decodeIfPresent(Bool.self, forKey: .quotaResetEnabled) ?? quotaResetEnabled
        quotaLowRemainingPercent = try values.decodeIfPresent(Double.self, forKey: .quotaLowRemainingPercent) ?? quotaLowRemainingPercent
        try validate()
    }
    public func validate() throws {
        guard soundVolume.isFinite, (0...1).contains(soundVolume) else { throw TerminalError.invalid("Sound volume must be between 0 and 1.") }
        guard quotaLowRemainingPercent.isFinite, (0...100).contains(quotaLowRemainingPercent) else { throw TerminalError.invalid("Remaining quota threshold must be between 0 and 100 percent.") }
    }
    public mutating func merge(_ draft: NotificationPreferences, from baseline: NotificationPreferences) {
        if draft.position != baseline.position { position = draft.position }
        if draft.showActivityInTabs != baseline.showActivityInTabs { showActivityInTabs = draft.showActivityInTabs }
        if draft.includeIdleProcesses != baseline.includeIdleProcesses { includeIdleProcesses = draft.includeIdleProcesses }
        if draft.showEachProcessInTabs != baseline.showEachProcessInTabs { showEachProcessInTabs = draft.showEachProcessInTabs }
        if draft.systemNotifications != baseline.systemNotifications { systemNotifications = draft.systemNotifications }
        if draft.badgeDockIcon != baseline.badgeDockIcon { badgeDockIcon = draft.badgeDockIcon }
        if draft.playSounds != baseline.playSounds { playSounds = draft.playSounds }
        if draft.soundVolume != baseline.soundVolume { soundVolume = draft.soundVolume }
        working.merge(draft.working, from: baseline.working)
        blocked.merge(draft.blocked, from: baseline.blocked)
        error.merge(draft.error, from: baseline.error)
        done.merge(draft.done, from: baseline.done)
        if draft.terminalNotifications != baseline.terminalNotifications { terminalNotifications = draft.terminalNotifications }
        if draft.tailscaleSignIn != baseline.tailscaleSignIn { tailscaleSignIn = draft.tailscaleSignIn }
        if draft.tailscaleDeviceApproval != baseline.tailscaleDeviceApproval { tailscaleDeviceApproval = draft.tailscaleDeviceApproval }
        if draft.tailscaleFailures != baseline.tailscaleFailures { tailscaleFailures = draft.tailscaleFailures }
        if draft.quotaLowEnabled != baseline.quotaLowEnabled { quotaLowEnabled = draft.quotaLowEnabled }
        if draft.quotaResetEnabled != baseline.quotaResetEnabled { quotaResetEnabled = draft.quotaResetEnabled }
        if draft.quotaLowRemainingPercent != baseline.quotaLowRemainingPercent { quotaLowRemainingPercent = draft.quotaLowRemainingPercent }
    }
    public func channels(for activity: ActivityState) -> NotificationChannels? {
        switch activity {
        case .running: return working
        case .blocked: return blocked
        case .error: return error
        case .done: return done
        case .idle, .unknown: return nil
        }
    }
}

public struct NotificationPreferencesDraft {
    public var preferences: NotificationPreferences
    private let baseline: NotificationPreferences
    public init(_ preferences: NotificationPreferences) { self.preferences = preferences; baseline = preferences }
    public mutating func cancel() { preferences = baseline }
    public func merged(into current: NotificationPreferences) throws -> NotificationPreferences {
        try preferences.validate()
        var merged = current
        merged.merge(preferences, from: baseline)
        try merged.validate()
        return merged
    }
}

public enum NotificationKind: String, Codable {
    case activity, terminal, quotaLow, quotaReset, tailscaleSignIn, tailscaleDeviceApproval, tailscaleFailure
}

public struct NotificationContext: Equatable {
    public let applicationActive: Bool
    public let focusedPaneID: String?
    public init(applicationActive: Bool, focusedPaneID: String? = nil) {
        self.applicationActive = applicationActive; self.focusedPaneID = focusedPaneID
    }
}

public struct NotificationEffects: Equatable {
    public let tabIndicator: Bool
    public let inApp: Bool
    public let systemNotification: Bool
    public let dockBadge: Bool
    public let soundVolume: Double?
    public let position: NotificationPosition
    public init(tabIndicator: Bool = false, inApp: Bool = false, systemNotification: Bool = false,
                dockBadge: Bool = false, soundVolume: Double? = nil, position: NotificationPosition = .topRight) {
        self.tabIndicator = tabIndicator; self.inApp = inApp; self.systemNotification = systemNotification
        self.dockBadge = dockBadge; self.soundVolume = soundVolume; self.position = position
    }
}

public enum NotificationPolicy {
    public static func effects(kind: NotificationKind, activity: ActivityState? = nil, paneID: String? = nil,
                               preferences: NotificationPreferences, legacyMasterEnabled: Bool,
                               context: NotificationContext) -> NotificationEffects {
        let channels: NotificationChannels
        if kind == .activity {
            guard let activity, let policy = preferences.channels(for: activity) else { return NotificationEffects(position: preferences.position) }
            channels = policy
        } else {
            let enabled: Bool
            switch kind {
            case .terminal: enabled = preferences.terminalNotifications
            case .quotaLow: enabled = preferences.quotaLowEnabled
            case .quotaReset: enabled = preferences.quotaResetEnabled
            case .tailscaleSignIn: enabled = preferences.tailscaleSignIn
            case .tailscaleDeviceApproval: enabled = preferences.tailscaleDeviceApproval
            case .tailscaleFailure: enabled = preferences.tailscaleFailures
            case .activity: enabled = false
            }
            channels = NotificationChannels(enabled: enabled, tabIndicator: false, dockBadge: false)
        }
        guard channels.enabled else { return NotificationEffects(position: preferences.position) }
        let activityEvent = kind == .activity
        let watching = context.applicationActive && paneID != nil && context.focusedPaneID == paneID
        let systemAllowed = preferences.systemNotifications && !watching
        let deliver = legacyMasterEnabled && channels.systemNotification
        return NotificationEffects(
            tabIndicator: activityEvent && activity != .running && preferences.showActivityInTabs && channels.tabIndicator,
            inApp: false,
            systemNotification: deliver && systemAllowed,
            dockBadge: activityEvent && preferences.badgeDockIcon && channels.dockBadge,
            soundVolume: !watching && legacyMasterEnabled && preferences.playSounds && channels.sound && preferences.soundVolume > 0 ? preferences.soundVolume : nil,
            position: preferences.position)
    }

    public static func dockBadgeCount(layout: WorkspaceLayout, sessions: [TerminalSession], readAt: [String: Date],
                                      preferences: NotificationPreferences) -> Int {
        guard preferences.badgeDockIcon else { return 0 }
        let open = Set(layout.workspaces.filter { !$0.closed }.map(\.id))
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return layout.tabs.filter { tab in
            guard let workspace = tab.workspaceID, open.contains(workspace) else { return false }
            return tab.panes.contains { id in
                guard let session = byID[id], [.blocked, .error, .done].contains(session.activity.state),
                      let policy = preferences.channels(for: session.activity.state), policy.enabled, policy.dockBadge else { return false }
                return readAt[id].map { $0 < session.activity.updatedAt } ?? true
            }
        }.count
    }
}

public struct QuotaAlarmNotice: Codable, Equatable {
    public let kind: NotificationKind
    public let accountID: String
    public let provider: AgentKind
    public let windowIDs: [String]
    public let date: Date
    public let isLimitReached: Bool
    public init(kind: NotificationKind, accountID: String, provider: AgentKind, windowIDs: [String], date: Date, isLimitReached: Bool = false) {
        self.kind = kind; self.accountID = accountID; self.provider = provider; self.windowIDs = windowIDs
        self.date = date; self.isLimitReached = isLimitReached
    }
}

public struct QuotaAlarmWindow: Codable, Equatable {
    public var accountID: String
    public var provider: AgentKind
    public var windowID: String
    public var resetAt: Date?
    public var lowActive: Bool
    public var resetConsumed: Bool
    public var observedAt: Date?
    public var organizationBindingID: String?
    public init(accountID: String, provider: AgentKind, windowID: String, resetAt: Date?, lowActive: Bool, resetConsumed: Bool, observedAt: Date? = nil, organizationBindingID: String? = nil) {
        self.accountID = accountID; self.provider = provider; self.windowID = windowID
        self.resetAt = resetAt; self.lowActive = lowActive; self.resetConsumed = resetConsumed; self.observedAt = observedAt
        self.organizationBindingID = organizationBindingID.flatMap { $0.isEmpty ? nil : $0 }
    }
    private enum CodingKeys: String, CodingKey {
        case accountID, provider, windowID, resetAt, lowActive, resetConsumed, observedAt, organizationBindingID
    }
    public init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        self.init(accountID: try value.decode(String.self, forKey: .accountID),
            provider: try value.decode(AgentKind.self, forKey: .provider), windowID: try value.decode(String.self, forKey: .windowID),
            resetAt: try value.decodeIfPresent(Date.self, forKey: .resetAt), lowActive: try value.decode(Bool.self, forKey: .lowActive),
            resetConsumed: try value.decode(Bool.self, forKey: .resetConsumed), observedAt: try value.decodeIfPresent(Date.self, forKey: .observedAt),
            organizationBindingID: try value.decodeIfPresent(String.self, forKey: .organizationBindingID))
    }
}

public struct QuotaAlarmLedger: Codable, Equatable {
    public var windows: [QuotaAlarmWindow] = []
    public init() {}
}

public enum QuotaAlarmEngine {
    public static let freshness: TimeInterval = 300
    public static let maximumWindows = 512
    private static let reachedID = "__limit_reached__"
    private struct Identity: Hashable {
        let account: String
        let provider: String
        let window: String
        let organizationBindingID: String?
        init(_ state: QuotaAlarmWindow) { account = state.accountID; provider = state.provider.rawValue; window = state.windowID; organizationBindingID = state.organizationBindingID }
        init(_ account: AccountProfile, _ window: String) { self.account = account.id; provider = account.provider.rawValue; self.window = window; organizationBindingID = account.organizationUsageBindingID }
    }

    public static func advance(ledger: inout QuotaAlarmLedger, accounts: [AccountProfile], usage: [AccountUsageSnapshot],
                               preferences: NotificationPreferences, now: Date) -> [QuotaAlarmNotice] {
        guard now.timeIntervalSince1970.isFinite, (try? preferences.validate()) != nil else { return [] }
        let active = Dictionary(accounts.prefix(128).filter { $0.enabled && $0.provider != .shell }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var states: [Identity: QuotaAlarmWindow] = [:]
        for state in ledger.windows.prefix(Self.maximumWindows) {
            guard let account = active[state.accountID], account.provider == state.provider,
                  account.organizationUsageBindingID == state.organizationBindingID,
                  validID(state.windowID), state.resetAt?.timeIntervalSince1970.isFinite != false else { continue }
            let key = Identity(state)
            if let previous = states[key], (previous.observedAt ?? .distantPast) > (state.observedAt ?? .distantPast) { continue }
            states[key] = state
        }
        var resets: [String: [String]] = [:]
        var lows: [String: [String]] = [:]
        var reached = Set<String>()
        for key in Array(states.keys) {
            guard var state = states[key], let reset = state.resetAt, !state.resetConsumed, reset <= now else { continue }
            state.resetConsumed = true
            state.lowActive = false
            states[key] = state
            if preferences.quotaResetEnabled { resets[state.accountID, default: []].append(state.windowID) }
        }
        var observations: [String: AccountUsageSnapshot] = [:]
        for observation in usage.prefix(256) {
            guard let account = active[observation.accountID], account.provider == observation.provider,
                  account.organizationUsageBindingID == observation.organizationBindingID,
                  [.available, .limited].contains(observation.status), observation.observedAt.timeIntervalSince1970.isFinite else { continue }
            let age = now.timeIntervalSince(observation.observedAt)
            guard age >= 0, age <= freshness else { continue }
            if let previous = observations[observation.accountID], previous.observedAt > observation.observedAt { continue }
            observations[observation.accountID] = observation
        }
        for accountID in observations.keys.sorted() {
            guard let observation = observations[accountID], let account = active[accountID] else { continue }
            var validWindows = 0
            for window in observation.windows.prefix(16) {
                guard validID(window.id), window.id != reachedID, window.usedPercent.isFinite, (0...100).contains(window.usedPercent),
                      window.resetsAt?.timeIntervalSince1970.isFinite != false,
                      window.resetsAt.map({ $0 > now }) ?? true else { continue }
                validWindows += 1
                let key = Identity(account, window.id)
                guard states[key] != nil || states.count < maximumWindows else { continue }
                var state = states[key] ?? QuotaAlarmWindow(accountID: account.id, provider: account.provider, windowID: window.id, resetAt: window.resetsAt, lowActive: false, resetConsumed: false, organizationBindingID: observation.organizationBindingID)
                guard state.observedAt.map({ $0 <= observation.observedAt }) ?? true else { continue }
                let changed = state.resetAt != nil && window.resetsAt != nil && state.resetAt != window.resetsAt
                if changed { state.lowActive = false; state.resetConsumed = false }
                let low = 100 - window.usedPercent <= preferences.quotaLowRemainingPercent
                if low && !state.lowActive && preferences.quotaLowEnabled { lows[account.id, default: []].append(window.id) }
                state.lowActive = state.lowActive || low
                if let reset = window.resetsAt { state.resetAt = reset }
                state.observedAt = observation.observedAt
                states[key] = state
            }
            let reachedKey = Identity(account, reachedID)
            if observation.status == .limited && validWindows == 0 && observation.windows.isEmpty {
                guard states[reachedKey] != nil || states.count < maximumWindows else { continue }
                var state = states[reachedKey] ?? QuotaAlarmWindow(accountID: account.id, provider: account.provider, windowID: reachedID, resetAt: nil, lowActive: false, resetConsumed: true, organizationBindingID: observation.organizationBindingID)
                guard state.observedAt.map({ $0 <= observation.observedAt }) ?? true else { continue }
                if !state.lowActive && preferences.quotaLowEnabled { reached.insert(account.id) }
                state.lowActive = true; state.observedAt = observation.observedAt
                states[reachedKey] = state
            } else if var state = states[reachedKey], state.observedAt.map({ $0 <= observation.observedAt }) ?? true {
                state.lowActive = false; state.observedAt = observation.observedAt; states[reachedKey] = state
            }
        }
        ledger.windows = states.values.sorted {
            if $0.accountID != $1.accountID { return $0.accountID < $1.accountID }
            if $0.provider != $1.provider { return $0.provider.rawValue < $1.provider.rawValue }
            return $0.windowID < $1.windowID
        }
        var result: [QuotaAlarmNotice] = []
        for accountID in resets.keys.sorted() {
            guard let account = active[accountID] else { continue }
            result.append(QuotaAlarmNotice(kind: .quotaReset, accountID: accountID, provider: account.provider,
                                           windowIDs: Array(Set(resets[accountID] ?? [])).sorted(), date: now))
        }
        for accountID in Set(lows.keys).union(reached).sorted() {
            guard let account = active[accountID] else { continue }
            result.append(QuotaAlarmNotice(kind: .quotaLow, accountID: accountID, provider: account.provider,
                                           windowIDs: Array(Set(lows[accountID] ?? [])).sorted(), date: now, isLimitReached: reached.contains(accountID)))
        }
        return result
    }

    public static func nextReset(ledger: QuotaAlarmLedger, accounts: [AccountProfile], now: Date) -> Date? {
        let active = Dictionary(accounts.prefix(128).filter { $0.enabled && $0.provider != .shell }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ledger.windows.prefix(maximumWindows).filter { window in
            guard let account = active[window.accountID] else { return false }
            return account.provider == window.provider && account.organizationUsageBindingID == window.organizationBindingID &&
                !window.resetConsumed && window.resetAt?.timeIntervalSince1970.isFinite == true && (window.resetAt ?? .distantPast) > now
        }.compactMap(\.resetAt).min()
    }

    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

public struct NotificationPreferencesStore {
    public let root: URL
    public init(root: URL) { self.root = root }
    public func read() throws -> NotificationPreferences {
        try NotificationPrivateFile.withLock(root: root, exclusive: false) {
            guard let data = try NotificationPrivateFile.read(root.appendingPathComponent("notification-preferences.json"), limit: 65_536) else { return NotificationPreferences() }
            return try JSONDecoder().decode(NotificationPreferences.self, from: data)
        }
    }
    @discardableResult public func save(_ preferences: NotificationPreferences, from baseline: NotificationPreferences? = nil) throws -> NotificationPreferences {
        try preferences.validate()
        if let baseline { try baseline.validate() }
        return try NotificationPrivateFile.withLock(root: root, exclusive: true) {
            let url = root.appendingPathComponent("notification-preferences.json")
            let data = try NotificationPrivateFile.read(url, limit: 65_536)
            var current = try data.map { try JSONDecoder().decode(NotificationPreferences.self, from: $0) } ?? NotificationPreferences()
            if let baseline { current.merge(preferences, from: baseline) }
            else { current = preferences }
            try current.validate()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var encoded = try encoder.encode(current); encoded.append(10)
            guard encoded.count <= 65_536 else { throw TerminalError.invalid("Notification preferences exceed 64 KiB.") }
            if encoded != data { try TerminalRuntime.atomicWrite(encoded, to: url) }
            return current
        }
    }
}

public struct QuotaAlarmLedgerStore {
    public let root: URL
    public init(root: URL) { self.root = root }
    public func read() throws -> QuotaAlarmLedger {
        try NotificationPrivateFile.withLock(root: root, exclusive: false) {
            guard let data = try NotificationPrivateFile.read(root.appendingPathComponent("quota-notification-ledger.json"), limit: 524_288) else { return QuotaAlarmLedger() }
            return try JSONDecoder().decode(QuotaAlarmLedger.self, from: data)
        }
    }
    public func save(_ ledger: QuotaAlarmLedger) throws {
        try NotificationPrivateFile.withLock(root: root, exclusive: true) {
            let url = root.appendingPathComponent("quota-notification-ledger.json")
            let previous = try NotificationPrivateFile.read(url, limit: 524_288)
            if let previous { _ = try JSONDecoder().decode(QuotaAlarmLedger.self, from: previous) }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(ledger); data.append(10)
            guard data.count <= 524_288 else { throw TerminalError.invalid("Quota notification ledger exceeds 512 KiB.") }
            if data != previous { try TerminalRuntime.atomicWrite(data, to: url) }
        }
    }
}

enum NotificationPrivateFile {
    static func withLock<T>(root: URL, exclusive: Bool, body: () throws -> T) throws -> T {
        var parent = stat()
        guard lstat(root.path, &parent) == 0, parent.st_mode & S_IFMT == S_IFDIR, parent.st_uid == getuid(), parent.st_mode & 0o077 == 0 else {
            throw TerminalError.invalid("Notification state requires a private owned directory.")
        }
        let fd = open(root.appendingPathComponent(".notifications.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw TerminalError.invalid("Cannot lock private notification state.") }
        defer { close(fd) }
        var lock = stat()
        guard fstat(fd, &lock) == 0, lock.st_mode & S_IFMT == S_IFREG, lock.st_uid == getuid(), lock.st_nlink == 1, lock.st_mode & 0o077 == 0,
              flock(fd, exclusive ? LOCK_EX : LOCK_SH) == 0 else { throw TerminalError.invalid("Invalid private notification lock.") }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }
    static func read(_ url: URL, limit: Int) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw TerminalError.invalid("Cannot open private notification state.") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o077 == 0, info.st_size <= limit else { throw TerminalError.invalid("Notification state must be a bounded private owned regular file.") }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw TerminalError.invalid("Cannot read private notification state.") }
            if count == 0 { return data }
            guard data.count + count <= limit else { throw TerminalError.invalid("Private notification state is too large.") }
            data.append(contentsOf: bytes.prefix(count))
        }
    }
}
