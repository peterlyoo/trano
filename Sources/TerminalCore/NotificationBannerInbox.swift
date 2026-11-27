import Foundation

public struct NotificationBanner: Codable, Equatable, Identifiable {
    public var id: String { message.identifier }
    public let message: NotificationMessage
    public let position: NotificationPosition
    public let createdAt: Date
    public let expiresAt: Date
    public init(message: NotificationMessage, position: NotificationPosition, createdAt: Date, expiresAt: Date) {
        self.message = message; self.position = position; self.createdAt = createdAt; self.expiresAt = expiresAt
    }
}

public struct NotificationBannerInbox {
    public let root: URL
    public init(root: URL) { self.root = root }
    public static func presentable(_ entries: [NotificationBanner], paneIDs: Set<String>, focusedPaneID: String?) -> [NotificationBanner] {
        entries.filter { $0.message.paneID != focusedPaneID && $0.message.paneID.map(paneIDs.contains) == true }
    }
    public func read(now: Date = Date()) throws -> [NotificationBanner] {
        try NotificationPrivateFile.withLock(root: root, exclusive: false) {
            try load().filter { Self.valid($0, now: now) }
        }
    }
    public func append(_ message: NotificationMessage, position: NotificationPosition, now: Date = Date()) throws {
        guard now.timeIntervalSince1970.isFinite, message.kind == .activity, let paneID = message.paneID, UUID(uuidString: paneID) != nil else {
            throw TerminalError.invalid("In-app notification requires an activity pane")
        }
        try NotificationPrivateFile.withLock(root: root, exclusive: true) {
            var entries = try load().filter { Self.valid($0, now: now) && $0.id != message.identifier }
            entries.append(NotificationBanner(message: message, position: position, createdAt: now, expiresAt: now.addingTimeInterval(8)))
            entries = Array(entries.suffix(32))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(entries); data.append(10)
            guard data.count <= 131_072 else { throw TerminalError.invalid("In-app notification inbox exceeds 128 KiB") }
            try TerminalRuntime.atomicWrite(data, to: root.appendingPathComponent("notification-banners.json"))
        }
    }
    private func load() throws -> [NotificationBanner] {
        guard let data = try NotificationPrivateFile.read(root.appendingPathComponent("notification-banners.json"), limit: 131_072) else { return [] }
        return Array(try JSONDecoder().decode([NotificationBanner].self, from: data).suffix(32))
    }
    private static func valid(_ entry: NotificationBanner, now: Date) -> Bool {
        entry.createdAt.timeIntervalSince1970.isFinite && entry.expiresAt.timeIntervalSince1970.isFinite &&
        entry.createdAt <= now && entry.expiresAt > now && entry.expiresAt.timeIntervalSince(entry.createdAt) <= 8 &&
        entry.message.kind == .activity && entry.message.paneID.flatMap(UUID.init(uuidString:)) != nil &&
        entry.message.title.count <= 100 && entry.message.body.count <= 500
    }
}
