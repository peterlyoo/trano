import Foundation

public enum TerminalProgram: String, Codable, CaseIterable, Sendable {
    case shell, zsh, claude, codex, k9s
    case kubernetesExec = "kubectl_exec"

    public init(agent: AgentKind) {
        switch agent {
        case .shell: self = .shell
        case .claude: self = .claude
        case .codex: self = .codex
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(Self.init(rawValue:)) ?? .shell
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var commandName: String { self == .kubernetesExec ? "kubectl exec" : rawValue }

    public var displayName: String {
        switch self {
        case .shell: return "Shell"
        case .zsh: return "zsh"
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .k9s: return "k9s"
        case .kubernetesExec: return "Kubernetes"
        }
    }

    public static func classify(executable: String, arguments: [String]) -> TerminalProgram? {
        switch executable.split(separator: "/").last {
        case "zsh": return .zsh
        case "claude": return .claude
        case "codex": return .codex
        case "k9s": return .k9s
        case "kubectl": return kubectlExec(arguments) ? .kubernetesExec : nil
        default: return nil
        }
    }

    private static func kubectlExec(_ arguments: [String]) -> Bool {
        guard (2...4096).contains(arguments.count) else { return false }
        var bytes = 0
        for argument in arguments {
            bytes += argument.utf8.count
            if bytes > 65_536 || argument.utf8.contains(0) { return false }
        }
        let valued: Set<String> = [
            "--as", "--as-group", "--as-uid", "--as-user-extra", "--cache-dir", "--certificate-authority",
            "--client-certificate", "--client-key", "--cluster", "--context", "--kubeconfig", "--kuberc",
            "--namespace", "--password", "--profile", "--profile-output", "--proxy-url", "--request-timeout",
            "--server", "--storage-driver-buffer-duration", "--storage-driver-db", "--storage-driver-host",
            "--storage-driver-password", "--storage-driver-table", "--storage-driver-user", "--tls-server-name",
            "--token", "--user", "--username", "--v", "--vmodule"
        ]
        let boolean: Set<String> = [
            "--disable-compression", "--insecure-skip-tls-verify", "--match-server-version",
            "--storage-driver-secure", "--warnings-as-errors"
        ]
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { return false }
            if argument.hasPrefix("--") {
                let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let flag = String(parts[0])
                if valued.contains(flag) {
                    if parts.count == 1 {
                        guard index + 1 < arguments.count else { return false }
                        index += 1
                    }
                } else if !boolean.contains(flag) { return false }
            } else if argument.hasPrefix("-") {
                guard argument.count >= 2, ["-n", "-s", "-v"].contains(String(argument.prefix(2))) else { return false }
                if argument.count == 2 {
                    guard index + 1 < arguments.count else { return false }
                    index += 1
                }
            } else { return argument == "exec" }
            index += 1
        }
        return false
    }
}
