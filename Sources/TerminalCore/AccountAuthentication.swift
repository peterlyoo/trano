import Foundation
import Darwin

public enum AccountAuthenticationStatus: String, Codable { case authenticated, loggedOut = "logged_out", unknown }

public struct AccountAuthenticationSnapshot: Codable {
    public let accountID: String
    public let provider: AgentKind
    public let status: AccountAuthenticationStatus
    public let checkedAt: Date
}

enum AccountAuthenticationAdapter {
    static func claude(account: AccountProfile, root: URL, exitCode: Int32, data: Data) throws -> AccountAuthenticationSnapshot {
        let payload = try AccountUsageAdapter.object(data)
        let status: AccountAuthenticationStatus
        if let directory = payload["configDirectory"] as? String,
           URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL == root.resolvingSymlinksInPath().standardizedFileURL {
            if exitCode == 0, payload["loggedIn"] as? Bool == true,
               ["claude.ai", "oauth_token", "api_key", "api_key_helper"].contains(payload["authMethod"] as? String ?? "") { status = .authenticated }
            else if exitCode == 1, payload["loggedIn"] as? Bool == false { status = .loggedOut }
            else { status = .unknown }
        } else { status = .unknown }
        return AccountAuthenticationSnapshot(accountID: account.id, provider: account.provider, status: status, checkedAt: Date())
    }
}

extension TerminalRuntime {
    public func accountAuthentication(accountID: String) throws -> AccountAuthenticationSnapshot {
        guard let account = try state().accounts.first(where: { $0.id == accountID }) else { throw TerminalError.invalid("Unknown account") }
        let directory = try accountRoot(accountID), command = try accountCommand(accountID, login: true)
        let fd = open(directory.appendingPathComponent(".trano-refresh.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw TerminalError.runtime("Cannot lock account authentication check") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw TerminalError.runtime("An account refresh is already running") }
        defer { _ = flock(fd, LOCK_UN) }
        var environment = ProcessInfo.processInfo.environment
        for key in command.removeEnvironment + ["REX_BLOCK", "REX_SESSION", "REX_SERVER", "TRANO_LAUNCH_ID"] { environment.removeValue(forKey: key) }
        environment.merge(command.environment) { _, new in new }
        let shim = root.appendingPathComponent("bin").resolvingSymlinksInPath().path
        environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init).filter { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path != shim }.joined(separator: ":")
        do {
            if account.provider == .claude {
                let response = try CommandRunner.run("/usr/bin/env", ["claude", "auth", "status", "--json"], environment: environment, timeout: 10)
                return try AccountAuthenticationAdapter.claude(account: account, root: directory, exitCode: response.status, data: response.stdout)
            }
            let response = try AccountRPC.request(method: "account/read", parameters: .object(["refreshToken": .bool(false)]), environment: environment)
            let status: AccountAuthenticationStatus
            if response["result"]?["account"] == .null { status = .loggedOut }
            else if ["chatgpt", "apiKey"].contains(response["result"]?["account"]?["type"]?.text ?? "") { status = .authenticated }
            else { status = .unknown }
            return AccountAuthenticationSnapshot(accountID: account.id, provider: account.provider, status: status, checkedAt: Date())
        } catch {
            return AccountAuthenticationSnapshot(accountID: account.id, provider: account.provider, status: .unknown, checkedAt: Date())
        }
    }
}
