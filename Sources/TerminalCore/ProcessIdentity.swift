import Foundation
import Darwin

enum ProcessIdentity {
    static func isRootHook(originPID: Int32, providerPID: Int32, provider: AgentKind) -> Bool {
        var current = originPID
        var visited: Set<Int32> = []
        var paths: [String] = []
        for _ in 0..<32 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return false }
            current = Int32(info.pbi_ppid)
            guard current > 1, visited.insert(current).inserted else { return false }
            var path = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(current, &path, UInt32(path.count)) > 0 else { return false }
            paths.append(String(cString: path))
            if current == providerPID {
                let codexProcesses = paths.filter { URL(fileURLWithPath: $0).lastPathComponent == "codex" }.count
                if provider == .codex && codexProcesses > 0 { return codexProcesses == 1 }
                guard let root = paths.last else { return false }
                return paths.filter { $0 == root }.count == 1
            }
        }
        return false
    }
}
