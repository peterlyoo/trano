import Foundation

extension TerminalRuntime {
    public func notificationPreferences() throws -> NotificationPreferences { try NotificationPreferencesStore(root: root).read() }
    @discardableResult public func saveNotificationPreferences(_ preferences: NotificationPreferences, from baseline: NotificationPreferences? = nil) throws -> NotificationPreferences {
        try NotificationPreferencesStore(root: root).save(preferences, from: baseline)
    }
}

public enum NotificationPreferencesAPI {
    public static func handle(_ request: APIRequest, runtime: TerminalRuntime) throws -> JSONValue? {
        switch request.method {
        case "notifications.preferences.get":
            return try JSONValue.encoded(runtime.notificationPreferences())
        case "notifications.preferences.update":
            guard let raw = request.params["preferences"] else { throw TerminalError.invalid("Missing notification preferences") }
            let proposed = try JSONDecoder().decode(NotificationPreferences.self, from: JSONEncoder().encode(raw))
            let baseline = try request.params["baseline"].map { try JSONDecoder().decode(NotificationPreferences.self, from: JSONEncoder().encode($0)) }
            return try JSONValue.encoded(runtime.saveNotificationPreferences(proposed, from: baseline))
        default: return nil
        }
    }
}
