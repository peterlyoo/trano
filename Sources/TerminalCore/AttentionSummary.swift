import Foundation

public enum AttentionSummary {
    public static let questionTools: Set<String> = ["AskUserQuestion"]
    static let limit = 240

    public static func activity(event: String, payload: [String: JSONValue]) -> (state: ActivityState, reason: String)? {
        let tool = payload["tool_name"]?.text ?? ""
        switch event {
        case "PermissionRequest":
            return (.blocked, permission(tool: tool, input: payload["tool_input"]))
        case "PreToolUse" where questionTools.contains(tool):
            return (.blocked, question(payload["tool_input"]))
        case "PostToolUse" where questionTools.contains(tool), "PostToolUseFailure" where questionTools.contains(tool):
            return (.running, "")
        case "Notification":
            guard ["permission_prompt", "elicitation_dialog"].contains(payload["notification_type"]?.text ?? "") else { return nil }
            return (.blocked, bounded(payload["message"]?.text ?? "Waiting for your input"))
        default:
            return nil
        }
    }

    public static func permission(tool: String, input: JSONValue?) -> String {
        let name = tool.isEmpty ? "tool" : tool
        let detail = ["command", "file_path", "path", "url", "pattern", "query", "description", "prompt"]
            .lazy.compactMap { input?[$0]?.text }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return bounded(detail.map { "approve \(name): \($0)" } ?? "approve \(name)")
    }

    public static func question(_ input: JSONValue?) -> String {
        if case .array(let questions)? = input?["questions"],
           let first = questions.first(where: { !($0["question"]?.text ?? "").isEmpty }), let text = first["question"]?.text {
            var labels: [String] = []
            if case .array(let options)? = first["options"] { labels = options.compactMap { $0["label"]?.text } }
            return answer(text, options: labels)
        }
        return answer(input?["question"]?.text ?? "question pending", options: [])
    }

    public static func decision(_ question: DecisionQuestion, locale: String) -> String {
        answer(question.question.text(locale: locale), options: question.options.map { $0.label.text(locale: locale) })
    }

    /// A completion shows the agent's own summary of the turn when it reported one, then the session title the
    /// agent set, then a generic line.
    public static func completion(reason: String = "", terminalTitle: String?) -> String {
        let summary = bounded(reason)
        if !summary.isEmpty { return summary }
        return TerminalTitleMetadata.normalize(terminalTitle).map(bounded) ?? "Task completed"
    }

    static func answer(_ question: String, options: [String]) -> String {
        let labels = options.filter { !$0.isEmpty }
        return bounded("answer: " + question + (labels.isEmpty ? "" : " (" + labels.joined(separator: " · ") + ")"))
    }

    static func bounded(_ text: String) -> String {
        let single = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return single.count > limit ? String(single.prefix(limit - 1)) + "…" : single
    }
}

public struct InterfacePresence: Codable, Equatable {
    public var pid: Int32
    public var focusedPaneID: String?

    public init(pid: Int32, focusedPaneID: String?) { self.pid = pid; self.focusedPaneID = focusedPaneID }

    public static func url(root: URL) -> URL { root.appendingPathComponent("presence/gui.json") }

    public static func write(_ presence: InterfacePresence, root: URL) throws {
        let directory = root.appendingPathComponent("presence")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try TerminalRuntime.atomicWrite(JSONEncoder().encode(presence), to: url(root: root))
    }

    public static func read(root: URL) -> InterfacePresence? {
        guard let data = try? Data(contentsOf: url(root: root)), data.count <= 4096 else { return nil }
        return try? JSONDecoder().decode(InterfacePresence.self, from: data)
    }

    public static func focusedPane(root: URL, isActive: (Int32) -> Bool) -> String? {
        guard let presence = read(root: root), presence.pid > 0, kill(presence.pid, 0) == 0, isActive(presence.pid) else { return nil }
        return presence.focusedPaneID
    }
}
