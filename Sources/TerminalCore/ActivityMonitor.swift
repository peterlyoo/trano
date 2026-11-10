import Foundation

public struct ActivityReport: Equatable {
    public let state: ActivityState
    public let agent: AgentKind
    public let reason: String
    public let clearsActive: Bool
    public let taskID: String?
    public let parentID: String?
    public let taskName: String?
    public let generation: String?

    public init(state: ActivityState, agent: AgentKind, reason: String, clearsActive: Bool,
                taskID: String? = nil, parentID: String? = nil, taskName: String? = nil, generation: String? = nil) {
        self.state = state; self.agent = agent; self.reason = reason; self.clearsActive = clearsActive
        self.taskID = taskID; self.parentID = parentID; self.taskName = taskName; self.generation = generation
    }
}

public struct ActivityScanner {
    private var phase = 0
    private var payload = Data()
    private var discarded = false
    public init() {}

    public mutating func feed(_ bytes: Data) -> [ActivityReport] {
        var reports: [ActivityReport] = []
        for byte in bytes {
            switch phase {
            case 0: if byte == 27 { phase = 1 }
            case 1:
                if byte == 93 { phase = 2; payload.removeAll(keepingCapacity: true); discarded = false }
                else if byte != 27 { phase = 0 }
            case 2:
                if byte == 7 {
                    if !discarded, let report = parse(payload) { reports.append(report) }
                    phase = 0
                } else if byte == 27 { phase = 3 }
                else if payload.count < 4096 { payload.append(byte) }
                else { discarded = true }
            default:
                if byte == 92 {
                    if !discarded, let report = parse(payload) { reports.append(report) }
                    phase = 0
                } else if byte == 93 {
                    phase = 2; payload.removeAll(keepingCapacity: true); discarded = false
                } else { phase = byte == 27 ? 1 : 0 }
            }
        }
        return reports
    }

    private func parse(_ bytes: Data) -> ActivityReport? {
        guard let raw = String(data: bytes, encoding: .utf8) else { return nil }
        if raw == "133;A" || raw.hasPrefix("133;A;") {
            return ActivityReport(state: .idle, agent: .shell, reason: "", clearsActive: true)
        }
        guard raw.hasPrefix("7501;"), bytes.count <= 4092 else { return nil }
        var fields: [String: String] = [:]
        for pair in raw.dropFirst(5).split(separator: ":", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard key.utf8.count <= 16, value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [95,46,44,43,47,61,45].contains($0) }) else { return nil }
            if key == "id" {
                guard AgentTaskActivity.validID(value) else { return nil }
            }
            fields[key] = value
        }
        let taskID = fields["id"]
        let parentID = fields["parent"] ?? taskID.flatMap(AgentTaskActivity.parentID)
        if let parentID {
            guard taskID != nil, AgentTaskActivity.validID(parentID), parentID != taskID else { return nil }
        }
        if let generation = fields["generation"], !AgentTaskActivity.validGeneration(generation) { return nil }
        if let taskName = fields["name"], !AgentTaskActivity.validName(taskName) { return nil }
        let name = fields["state"] ?? ""
        if name == "clear" {
            return ActivityReport(state: .unknown, agent: .shell, reason: "", clearsActive: true,
                                  taskID: taskID, parentID: parentID, generation: fields["generation"])
        }
        guard let state = ActivityState(rawValue: name == "working" ? "running" : name), state != .unknown || taskID != nil else { return nil }
        var reason = fields["kind"] ?? ""
        if taskID == nil, let encoded = fields["msg"] {
            guard encoded.utf8.count <= 2732 else { return nil }
            let padded = encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            guard let data = Data(base64Encoded: padded), data.count <= 2048,
                  let text = String(data: data, encoding: .utf8),
                  !text.unicodeScalars.contains(where: { $0.value <= 31 || (127...159).contains($0.value) }) else { return nil }
            reason = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
        }
        let app = fields["app"]?.lowercased() ?? ""
        let agent: AgentKind = app == "claude" || app == "claude-code" ? .claude : app == "codex" ? .codex : .shell
        return ActivityReport(state: state, agent: agent, reason: String(reason.prefix(1000)), clearsActive: false,
                              taskID: taskID, parentID: parentID, taskName: fields["name"] ?? fields["kind"], generation: fields["generation"])
    }
}

public struct ActivityEvent: Codable, Equatable {
    public let revision: Int
    public let sessionID: String
    public let title: String
    public let activity: Activity
    public let agent: AgentKind
}

public struct EventBatch: Codable {
    public let revision: Int
    public let resetRequired: Bool
    public let events: [ActivityEvent]
}
