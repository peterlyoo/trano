import Foundation

public enum TwinProviderSandbox {
    public static func profile(worktree: String, privateProfileRoot: String, apiSocketPath: String? = nil, sourceConfigurationRoot: String? = nil) throws -> String {
        guard TwinProviderPlanner.validPath(worktree), TwinProviderPlanner.validPath(privateProfileRoot),
              !TwinProviderPlanner.contains(worktree, privateProfileRoot), !TwinProviderPlanner.contains(privateProfileRoot, worktree),
              let apiSocketPath, TwinProviderPlanner.validPath(apiSocketPath), sourceConfigurationRoot.map(TwinProviderPlanner.validPath) ?? true else { throw TerminalError.invalid("Invalid twin confinement paths") }
        let runtimeRoot = URL(fileURLWithPath: apiSocketPath).deletingLastPathComponent().path
        guard runtimeRoot != "/", runtimeRoot != worktree, runtimeRoot != privateProfileRoot else { throw TerminalError.invalid("The twin API must live in a private runtime directory") }
        let sourceRule = sourceConfigurationRoot.map { quote($0) + " = \"deny\"\n" } ?? ""
        return """
        [permissions.trano_twin.workspace_roots]
        \(quote(worktree)) = true
        [permissions.trano_twin.filesystem]
        "/" = "read"
        \(quote(runtimeRoot)) = "deny"
        ":workspace_roots" = "write"
        \(quote(worktree + "/.git")) = "read"
        \(quote(privateProfileRoot)) = "deny"
        \(quote(privateProfileRoot + "/tmp")) = "write"
        \(sourceRule)[permissions.trano_twin.network]
        enabled = true
        mode = "limited"
        [permissions.trano_twin.network.domains]
        [permissions.trano_twin.network.unix_sockets]
        \(quote(apiSocketPath)) = "allow"

        """
    }
    private static func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
}
