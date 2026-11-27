import Foundation
import Darwin

private struct RuntimeContinuity: Codable {
    var activityReadAt: [String: Date]
    var followUpInputs: [FollowUpInput]
    var followUpTurns: [FollowUpTurn]
    var followUpPasteStates: [FollowUpPasteState]

    init(_ state: RuntimeState) {
        activityReadAt = state.activityReadAt
        followUpInputs = state.followUpInputs
        followUpTurns = state.followUpTurns
        followUpPasteStates = state.followUpPasteStates
    }

    var isEmpty: Bool { activityReadAt.isEmpty && followUpInputs.isEmpty && followUpTurns.isEmpty && followUpPasteStates.isEmpty }

    func apply(to state: inout RuntimeState) {
        state.activityReadAt = activityReadAt
        state.followUpInputs = followUpInputs
        state.followUpTurns = followUpTurns
        state.followUpPasteStates = followUpPasteStates
    }
}

extension TerminalRuntime {
    func continuityData() throws -> Data? {
        let path = root.appendingPathComponent("continuity.json").path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw TerminalError.invalid("Cannot open private continuity state") }
        defer { close(fd) }
        var info = stat()
        let maximum = 64 * 1_048_576
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
              info.st_size <= maximum else { throw TerminalError.invalid("Continuity state must be a private owned regular file of at most 64 MiB") }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw TerminalError.runtime("Cannot read continuity state") }
            if count == 0 { break }
            guard data.count + count <= maximum else { throw TerminalError.invalid("Continuity state exceeds 64 MiB") }
            data.append(contentsOf: bytes.prefix(count))
        }
        return data
    }

    func restoreContinuity(to state: inout RuntimeState, data: Data?) throws {
        if let data {
            try JSONDecoder().decode(RuntimeContinuity.self, from: data).apply(to: &state)
        }
    }

    func persistContinuity(from state: inout RuntimeState) throws {
        let continuity = RuntimeContinuity(state)
        let previous = try continuityData()
        if previous != nil || !continuity.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(continuity)
            guard data.count <= 64 * 1_048_576 else { throw TerminalError.invalid("Continuity state exceeds 64 MiB") }
            if data != previous { try Self.atomicWrite(data, to: root.appendingPathComponent("continuity.json")) }
        }
        // Live supervisors from an older build rewrite only the primary schema.
        state.activityReadAt = [:]
        state.followUpInputs = []
        state.followUpTurns = []
        state.followUpPasteStates = []
    }
}
