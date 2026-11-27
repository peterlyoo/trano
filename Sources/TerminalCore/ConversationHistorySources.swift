import Foundation
import CryptoKit

public enum ConversationHistorySources {
    public static func build(state: RuntimeState, runtimeRoot: URL, home: URL,
                             environment: [String: String] = [:]) -> [ConversationHistorySource] {
        var result: [ConversationHistorySource] = []
        var seen = Set<String>()
        func append(provider: AgentKind, root: String, accountID: String? = nil, label: String, enabled: Bool = true) {
            guard provider != .shell, root.hasPrefix("/"), root.utf8.count <= 4096,
                  !root.contains("\0"), !root.contains("\n"), !root.contains("\r") else { return }
            let path = URL(fileURLWithPath: root).standardizedFileURL.path
            guard path != "/", path != home.standardizedFileURL.path else { return }
            let key = provider.rawValue + ":" + path
            guard seen.insert(key).inserted else { return }
            let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            result.append(ConversationHistorySource(id: accountID.map { "account:" + $0 } ?? digest,
                provider: provider, configurationRoot: path, accountID: accountID, label: label, enabled: enabled))
        }
        for account in state.accounts where UUID(uuidString: account.id) != nil && account.provider != .shell {
            append(provider: account.provider, root: runtimeRoot.appendingPathComponent("accounts").appendingPathComponent(account.id).path,
                   accountID: account.id, label: account.label, enabled: account.enabled)
        }
        for provider in [AgentKind.claude, .codex] {
            let folder = provider == .claude ? ".claude" : ".codex"
            append(provider: provider, root: home.appendingPathComponent(folder).path, label: "Default")
            let key = provider == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"
            if let root = environment[key], !root.isEmpty {
                append(provider: provider, root: root, label: URL(fileURLWithPath: root).lastPathComponent)
            }
        }
        for launch in state.agentLaunches where launch.accountID == nil {
            append(provider: launch.provider, root: launch.configurationRoot,
                   label: URL(fileURLWithPath: launch.configurationRoot).lastPathComponent)
        }
        return result
    }
}
