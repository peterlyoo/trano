import Foundation

public struct NotificationMessage: Codable, Equatable {
    public let identifier: String
    public let kind: NotificationKind
    public let title: String
    public let body: String
    public let paneID: String?
    public let activity: ActivityState?
    public init(identifier: String, kind: NotificationKind, title: String, body: String, paneID: String? = nil, activity: ActivityState? = nil) {
        self.identifier = String(identifier.prefix(200)); self.kind = kind
        self.title = Self.clean(title, limit: 100); self.body = Self.clean(body, limit: 500)
        self.paneID = paneID; self.activity = activity
    }
    public static func quota(_ notice: QuotaAlarmNotice, account: AccountProfile, threshold: Double) -> NotificationMessage {
        let provider = notice.provider.rawValue.capitalized
        let title: String
        let body: String
        if notice.kind == .quotaReset {
            title = "\(provider) quota reset"
            body = "Scheduled quota reset time reached. Refresh usage to confirm availability."
        } else if notice.isLimitReached {
            title = "\(provider) quota reached"
            body = "The provider reported an account usage limit."
        } else {
            title = "\(provider) quota low"
            body = "One or more usage windows have \(threshold.formatted())% or less remaining."
        }
        return NotificationMessage(identifier: "\(notice.kind.rawValue).\(account.id).\(notice.date.timeIntervalSince1970)", kind: notice.kind,
                                   title: title + " · " + account.label, body: body)
    }
    private static func clean(_ value: String, limit: Int) -> String {
        String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(limit).map(String.init).joined())
    }
}

public enum NotificationDelivery {
    @discardableResult public static func deliver(_ message: NotificationMessage, preferences: NotificationPreferences,
                                                  legacyMasterEnabled: Bool, context: NotificationContext,
                                                  system: (NotificationMessage) -> Void,
                                                  inApp: (NotificationMessage, NotificationPosition) -> Void,
                                                  sound: (Double) -> Void) -> NotificationEffects {
        let effects = NotificationPolicy.effects(kind: message.kind, activity: message.activity, paneID: message.paneID,
                                                  preferences: preferences, legacyMasterEnabled: legacyMasterEnabled, context: context)
        if effects.systemNotification { system(message) }
        if let volume = effects.soundVolume { sound(volume) }
        return effects
    }

    public static func deliver(batch messages: [NotificationMessage], preferences: NotificationPreferences,
                               legacyMasterEnabled: Bool, context: (NotificationMessage) -> NotificationContext,
                               system: (NotificationMessage) -> Void,
                               inApp: (NotificationMessage, NotificationPosition) -> Void,
                               sound: (Double) -> Void) {
        var loudest: Double?
        for message in messages {
            let effects = deliver(message, preferences: preferences, legacyMasterEnabled: legacyMasterEnabled,
                                  context: context(message), system: system, inApp: inApp, sound: { _ in })
            if let volume = effects.soundVolume { loudest = max(loudest ?? 0, volume) }
        }
        if let loudest { sound(loudest) }
    }
}

public enum ActivityNotificationBacklog {
    // A restarted service resumes from a persisted cursor; events older than this predate the
    // restart (e.g. panes killed at shutdown) and must not be replayed as a notification burst.
    public static let maximumAge: TimeInterval = 120
    public static let notifiedStates: Set<ActivityState> = [.running, .done, .error, .blocked]
    public static let hookGrace: TimeInterval = 1
    /// Claude and Codex report the turn summary on screen about 2 s after the hook reports the completion.
    public static let summaryGrace: TimeInterval = 3

    /// Seconds to wait before delivering, so a richer report of the same moment replaces a bare one.
    public static func wait(for events: [ActivityEvent], now: Date) -> TimeInterval? {
        events.compactMap { event -> TimeInterval? in
            guard [.claude, .codex].contains(event.agent) else { return nil }
            let age = now.timeIntervalSince(event.activity.updatedAt)
            switch event.activity.state {
            case .blocked where event.activity.source != "hook": return hookGrace - age
            case .done where event.activity.reason.isEmpty: return summaryGrace - age
            default: return nil
            }
        }.filter { $0 > 0 }.max()
    }

    public static func deliverable(_ events: [ActivityEvent], now: Date, maximumAge: TimeInterval = maximumAge) -> [ActivityEvent] {
        let latest = Dictionary(events.map { ($0.sessionID, $0) }, uniquingKeysWith: { left, right in right.revision >= left.revision ? right : left })
        return latest.values
            .filter { notifiedStates.contains($0.activity.state) && now.timeIntervalSince($0.activity.updatedAt) <= maximumAge }
            .sorted { $0.revision < $1.revision }
    }
}
