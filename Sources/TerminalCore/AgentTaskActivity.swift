import Foundation

enum AgentTaskActivity {
    static let limit = 64

    static func validID(_ value: String) -> Bool {
        let segments = value.split(separator: "/", omittingEmptySubsequences: false)
        return !value.isEmpty && value.utf8.count <= 128 && segments.count <= 8 && segments.allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 64 && $0 != "." && $0 != ".." && $0.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [95, 46, 45].contains($0)
            }
        }
    }

    static func validGeneration(_ value: String) -> Bool { validID(value) && !value.contains("/") }

    static func validName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func parentID(_ value: String) -> String? {
        guard let slash = value.lastIndex(of: "/") else { return nil }
        return String(value[..<slash])
    }

    static func hookState(_ event: String, provider: AgentKind) -> ActivityState? {
        if event == "SubagentStart" { return .running }
        if event == "SubagentStop" { return .done }
        guard provider == .claude else { return nil }
        switch event {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse": return .running
        case "PermissionRequest": return .blocked
        case "PostToolUseFailure", "StopFailure": return .error
        case "Stop": return .done
        default: return nil
        }
    }

    static func hasCycle(id: String, parentID: String?, tasks: [AgentTask]) -> Bool {
        var visited: Set<String> = [id]
        var next = parentID
        while let parent = next {
            guard visited.insert(parent).inserted else { return true }
            next = tasks.first(where: { $0.id == parent })?.parentID
        }
        return false
    }

    static func removing(_ id: String, from tasks: [AgentTask]) -> [AgentTask] {
        var removed: Set<String> = [id]
        for _ in 0..<limit {
            let descendants = tasks.filter { $0.id.hasPrefix(id + "/") || $0.parentID.map(removed.contains) == true }.map(\.id)
            let previous = removed.count
            removed.formUnion(descendants)
            if removed.count == previous { break }
        }
        return tasks.filter { !removed.contains($0.id) }
    }
}

extension TerminalRuntime {
    public func report(_ paneID: String, report: ActivityReport) throws {
        if let taskID = report.taskID {
            try recordAgentTask(paneID: paneID, id: taskID, parentID: report.parentID, name: report.taskName,
                                state: report.state, agent: report.agent, source: "osc7501", generation: report.generation,
                                reason: report.reason, clear: report.clearsActive)
        } else {
            try transaction {
                try self.report(paneID, state: report.state, reason: report.reason, agent: report.agent,
                                source: "osc7501", clearsActive: report.clearsActive)
                if report.clearsActive && report.state == .unknown,
                   try state().sessions.first(where: { $0.id == paneID })?.agentTasks != nil {
                    try update { state in
                        if let index = state.sessions.firstIndex(where: { $0.id == paneID }) { state.sessions[index].agentTasks = nil }
                    }
                }
            }
        }
    }

    func recordAgentTask(paneID: String, id: String, parentID: String?, name: String?, state activityState: ActivityState,
                         agent: AgentKind, source: String, generation: String?, reason: String = "", clear: Bool = false) throws {
        guard AgentTaskActivity.validID(id), parentID.map(AgentTaskActivity.validID) ?? true,
              parentID != id, name.map(AgentTaskActivity.validName) ?? true,
              generation.map(AgentTaskActivity.validGeneration) ?? true, reason.utf8.count <= 128 else { return }
        try transaction {
            let snapshot = try state()
            guard let index = snapshot.sessions.firstIndex(where: { $0.id == paneID && $0.remote == nil }) else { return }
            let launch = snapshot.agentLaunches.first { $0.paneID == paneID && $0.lifecycle == .active }
            if let generation, generation != launch?.id { return }
            if let launch, agent != .shell && agent != launch.provider { return }
            var tasks = snapshot.sessions[index].agentTasks ?? []
            if clear {
                let remaining = AgentTaskActivity.removing(id, from: tasks)
                guard remaining != tasks else { return }
                try update { $0.sessions[index].agentTasks = remaining.isEmpty ? nil : remaining }
                return
            }
            let existing = tasks.firstIndex { $0.id == id }
            let resolvedParent = parentID ?? existing.flatMap { tasks[$0].parentID }
            guard !AgentTaskActivity.hasCycle(id: id, parentID: resolvedParent, tasks: tasks) else { return }
            let resolvedName = name ?? existing.map { tasks[$0].name } ?? String(id.split(separator: "/").last!)
            let resolvedAgent = agent == .shell ? launch?.provider ?? existing.map { tasks[$0].agent } ?? .shell : agent
            var activity = Activity()
            activity.state = activityState; activity.source = source; activity.reason = reason
            let task = AgentTask(id: id, parentID: resolvedParent, name: resolvedName, agent: resolvedAgent,
                                 activity: activity, generation: launch?.id)
            if let existing {
                tasks[existing] = task
            } else {
                if tasks.count >= AgentTaskActivity.limit {
                    guard let oldest = tasks.indices.filter({ ![.running, .blocked].contains(tasks[$0].activity.state) })
                        .min(by: { tasks[$0].activity.updatedAt < tasks[$1].activity.updatedAt }) else { return }
                    tasks.remove(at: oldest)
                }
                tasks.append(task)
            }
            try update { $0.sessions[index].agentTasks = tasks }
        }
    }
}
