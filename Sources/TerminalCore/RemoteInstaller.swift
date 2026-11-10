import Foundation
import CryptoKit

public enum RemoteInstallationState: String, Codable {
    case ready, missing, conflict, missingTmux = "missing_tmux", unsupported
}

public struct RemoteInstallationStatus: Codable, Equatable {
    public let state: RemoteInstallationState
    public let architecture: String
    public let message: String

    public static func parse(_ output: String) throws -> RemoteInstallationStatus {
        var fields: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, ["os", "arch", "tmux", "helper"].contains(String(pair[0])), fields[String(pair[0])] == nil else {
                throw TerminalError.runtime("Unexpected SSH installation probe response")
            }
            fields[String(pair[0])] = String(pair[1])
        }
        guard fields.count == 4, ["0", "1"].contains(fields["tmux"] ?? ""), ["managed", "unmanaged", "missing"].contains(fields["helper"] ?? "") else {
            throw TerminalError.runtime("Incomplete SSH installation probe response")
        }
        let architecture = ["x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"][fields["arch"] ?? ""] ?? ""
        guard fields["os"] == "Linux", !architecture.isEmpty else { return Self(state: .unsupported, architecture: architecture, message: "The remote helper supports Linux arm64 and amd64.") }
        guard fields["tmux"] == "1" else { return Self(state: .missingTmux, architecture: architecture, message: "Install tmux with the host's package manager, then check again.") }
        switch fields["helper"] {
        case "managed": return Self(state: .ready, architecture: architecture, message: "Trano is installed and its checksum matches.")
        case "unmanaged": return Self(state: .conflict, architecture: architecture, message: "An existing helper is not managed by this installer. Replace with backup to continue.")
        default: return Self(state: .missing, architecture: architecture, message: "Install the bundled helper to start remote sessions.")
        }
    }
}

public struct RemoteInstaller {
    public let resources: URL
    public init(resources: URL? = nil) {
        self.resources = resources ?? Self.bundledResources(bundleURL: Bundle.main.bundleURL, executableURL: Bundle.main.executableURL)
    }

    static func bundledResources(bundleURL: URL, executableURL: URL?) -> URL {
        var candidates: [URL] = []
        for origin in [bundleURL, executableURL?.deletingLastPathComponent()].compactMap({ $0 }) {
            var ancestor = origin.standardizedFileURL
            for _ in 0..<10 {
                if ancestor.pathExtension == "app" {
                    let candidate = ancestor.appendingPathComponent("Contents/Resources/Remote")
                    if !candidates.contains(candidate) { candidates.append(candidate) }
                }
                let parent = ancestor.deletingLastPathComponent()
                if parent == ancestor { break }
                ancestor = parent
            }
        }
        for candidate in candidates {
            guard let attributes = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  attributes.isDirectory == true, attributes.isSymbolicLink != true,
                  FileManager.default.isReadableFile(atPath: candidate.appendingPathComponent("install-remote.sh").path) else { continue }
            return candidate
        }
        return bundleURL.appendingPathComponent("Contents/Resources/Remote")
    }

    static let probe = """
    set -eu
    printf 'os=%s\narch=%s\n' "$(uname -s)" "$(uname -m)"
    if command -v tmux >/dev/null 2>&1; then printf 'tmux=1\n'; else printf 'tmux=0\n'; fi
    target="$HOME/.local/bin/trano-server"
    marker="$HOME/.local/bin/.trano-server.sha256"
    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
      printf 'helper=missing\n'
    elif [ -f "$marker" ] && [ ! -L "$marker" ] && [ -x "$target" ] && [ ! -L "$target" ]; then
      if command -v sha256sum >/dev/null 2>&1; then actual=$(sha256sum "$target" | awk '{print $1}'); else actual=$(shasum -a 256 "$target" | awk '{print $1}'); fi
      if [ "$actual" = "$(cat "$marker")" ]; then printf 'helper=managed\n'; else printf 'helper=unmanaged\n'; fi
    else
      printf 'helper=unmanaged\n'
    fi
    """

    private func ssh(_ host: RemoteHost, command: String, input: Data? = nil, timeout: TimeInterval = 15) throws -> Data {
        try host.validated()
        let configuration = host.sshConfigPath.map { ["-F", $0] } ?? []
        let arguments = configuration + ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "LogLevel=ERROR", "--", host.address, command]
        let result = try CommandRunner.run("/usr/bin/ssh", arguments, input: input, timeout: timeout)
        guard result.status == 0 else { throw TerminalError.runtime(String(decoding: result.stderr.prefix(4096), as: UTF8.self)) }
        return result.stdout
    }

    public func check(host: RemoteHost) throws -> RemoteInstallationStatus {
        let data = try ssh(host, command: "sh -c " + ShellQuote.quote(Self.probe))
        return try RemoteInstallationStatus.parse(String(decoding: data, as: UTF8.self))
    }

    func verifiedPackage(architecture: String) throws -> (binary: URL, installer: URL, digest: String) {
        guard ["arm64", "amd64"].contains(architecture) else { throw TerminalError.invalid("Unsupported remote architecture") }
        let binary = resources.appendingPathComponent("linux-" + architecture).appendingPathComponent("trano-server")
        let checksum = binary.appendingPathExtension("sha256")
        let installer = resources.appendingPathComponent("install-remote.sh")
        for file in [binary, checksum, installer] {
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true, (values.fileSize ?? 0) <= 32 * 1024 * 1024 else { throw TerminalError.invalid("Invalid bundled remote package") }
        }
        let data = try Data(contentsOf: binary, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let expected = try String(contentsOf: checksum, encoding: .utf8).split(whereSeparator: \.isWhitespace).first.map(String.init)
        guard expected == digest else { throw TerminalError.invalid("Bundled remote helper checksum does not match") }
        return (binary, installer, digest)
    }

    public func install(host: RemoteHost, force: Bool = false) throws -> RemoteInstallationStatus {
        let status = try check(host: host)
        guard status.state != .unsupported, status.state != .missingTmux else { throw TerminalError.invalid(status.message) }
        guard status.state != .conflict || force else { throw TerminalError.invalid(status.message) }
        let package = try verifiedPackage(architecture: status.architecture)
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("trano-remote-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        try FileManager.default.copyItem(at: package.binary, to: stage.appendingPathComponent("trano-server"))
        try FileManager.default.copyItem(at: package.installer, to: stage.appendingPathComponent("install-remote.sh"))
        let archive = try CommandRunner.run("/usr/bin/tar", ["-cf", "-", "-C", stage.path, "trano-server", "install-remote.sh"], timeout: 15, limit: 40 * 1024 * 1024)
        guard archive.status == 0 else { throw TerminalError.runtime("Cannot prepare the remote helper archive") }
        let script = """
        set -eu
        umask 077
        stage=$(mktemp -d "${TMPDIR:-/tmp}/trano-install.XXXXXXXX")
        trap 'rm -rf "$stage"' EXIT HUP INT TERM
        tar -xf - -C "$stage"
        sh "$stage/install-remote.sh" --binary "$stage/trano-server" --sha256 \(ShellQuote.quote(package.digest))\(force ? " --force" : "")
        """
        _ = try ssh(host, command: "sh -c " + ShellQuote.quote(script), input: archive.stdout, timeout: 90)
        let installed = try check(host: host)
        guard installed.state == .ready else { throw TerminalError.runtime("Remote helper installation did not pass verification") }
        return installed
    }
}

extension TerminalRuntime {
    public func checkRemoteInstallation(hostID: String, resources: URL? = nil) throws -> RemoteInstallationStatus {
        try RemoteInstaller(resources: resources).check(host: remoteHost(hostID))
    }
    public func installRemoteHelper(hostID: String, force: Bool = false, resources: URL? = nil) throws -> RemoteInstallationStatus {
        try RemoteInstaller(resources: resources).install(host: remoteHost(hostID), force: force)
    }
}
