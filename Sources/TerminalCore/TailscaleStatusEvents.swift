import Foundation

public final class TailscaleStatusEvents {
    private let lock = NSLock()
    private var state: String?
    private var failing = false
    public init() {}
    public func observe(state: String?, failed: Bool) -> [NotificationMessage] {
        lock.lock(); defer { lock.unlock() }
        var messages: [NotificationMessage] = []
        if let state, self.state != state {
            self.state = state
            if state == "NeedsLogin" {
                messages.append(NotificationMessage(identifier: "tailscale.signin." + UUID().uuidString, kind: .tailscaleSignIn, title: "Sign in to Tailscale", body: "Open Trano Server settings to complete Tailscale sign-in."))
            } else if state == "NeedsMachineAuth" {
                messages.append(NotificationMessage(identifier: "tailscale.approval." + UUID().uuidString, kind: .tailscaleDeviceApproval, title: "Tailscale device approval required", body: "Approve this device in your tailnet before using Trano remote access."))
            }
        }
        if failed && !failing {
            messages.append(NotificationMessage(identifier: "tailscale.failure." + UUID().uuidString, kind: .tailscaleFailure, title: "Tailscale connection needs attention", body: "Open Trano Server settings to review the connection and retry."))
        }
        failing = failed
        return messages
    }
    public static func authenticationURLs(in output: Data) -> [URL] {
        guard output.count <= 1_048_576, let text = String(data: output, encoding: .utf8),
              let pattern = try? NSRegularExpression(pattern: #"https://[^\s<>\"'()\u001B]+"#) else { return [] }
        var seen: Set<String> = []
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text), let url = URL(string: String(text[range])), url.scheme == "https", let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil, url.fragment == nil, url.absoluteString.utf8.count <= 4096,
                  seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
    }
}
