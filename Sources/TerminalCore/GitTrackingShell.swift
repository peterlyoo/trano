import Foundation
import Darwin

public enum GitTrackingShell {
    public static func install(root: URL, helperExecutable: String) throws -> String {
        guard helperExecutable.hasPrefix("/"), !helperExecutable.utf8.contains(0) else { throw TerminalError.invalid("Invalid worktree tracking helper") }
        let descriptor = open(root.appendingPathComponent("git-tracking-install.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw TerminalError.runtime("Cannot open Git tracking installation lease") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              fchmod(descriptor, 0o600) == 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw TerminalError.runtime("Git tracking installation is already running or unavailable")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        let directory = try ManagedDirectory.ensure(root, component: "git-bin")
        let agents = try ManagedDirectory.ensure(root, component: "bin")
        let shell = try ManagedDirectory.ensure(root, component: "shell")
        let compatibility = try ManagedDirectory.ensure(shell, component: "bin")
        let script = """
        #!/bin/sh
        set -f
        real_git=''
        previous_ifs=$IFS
        IFS=:
        for directory in $PATH; do
          case "$directory" in
            \(ShellQuote.quote(directory.path))|\(ShellQuote.quote(agents.path))|\(ShellQuote.quote(compatibility.path))) continue ;;
          esac
          if [ -f "${directory:-.}/git" ] && [ -x "${directory:-.}/git" ]; then
            real_git="${directory:-.}/git"
            break
          fi
        done
        IFS=$previous_ifs
        if [ -z "$real_git" ]; then real_git=/usr/bin/git; fi
        if [ -n "${TRANO_WORKTREE_CAPTURE:-}" ]; then exec "$real_git" "$@"; fi
        for argument do
          if [ "$argument" = worktree ]; then
            helper="${TRANO_CLI_PATH:-}"
            if [ -z "$helper" ]; then helper=\(ShellQuote.quote(helperExecutable)); fi
            if [ ! -f "$helper" ] || [ ! -x "$helper" ]; then exec "$real_git" "$@"; fi
            exec "$helper" tracked-git "$real_git" "$@"
          fi
        done
        exec "$real_git" "$@"

        """
        for base in [directory, agents, compatibility] { try write(script, in: base) }
        return directory.appendingPathComponent("git").path
    }

    public static func environment(_ original: [String: String], root: URL, helperExecutable: String) throws -> [String: String] {
        _ = try install(root: root, helperExecutable: helperExecutable)
        var environment = original
        let directory = root.appendingPathComponent("git-bin").path
        let paths = (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            .filter { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path != directory }
        environment["PATH"] = ([directory] + paths).joined(separator: ":")
        environment["TRANO_GIT_SHIM_DIR"] = directory
        return environment
    }

    public static func isManagedShim(_ path: String, root: URL) -> Bool {
        let identity = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        return ["git-bin/git", "bin/git", "shell/bin/git"].contains {
            root.appendingPathComponent($0).standardizedFileURL.resolvingSymlinksInPath().path == identity
        }
    }

    public static func isInstalled(root: URL) -> Bool {
        ["git-bin", "bin", "shell/bin"].allSatisfy { component in
            let base = root.appendingPathComponent(component)
            for name in ["git", ".git-trano-owned"] {
                var info = stat()
                guard lstat(base.appendingPathComponent(name).path, &info) == 0,
                      info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
                      info.st_mode & 0o077 == 0 else { return false }
            }
            return FileManager.default.isExecutableFile(atPath: base.appendingPathComponent("git").path)
                && (try? Data(contentsOf: base.appendingPathComponent(".git-trano-owned"))) == Data("trano-git-tracking-v1\n".utf8)
        }
    }

    private static func write(_ script: String, in directory: URL) throws {
        let file = directory.appendingPathComponent("git"), marker = directory.appendingPathComponent(".git-trano-owned")
        let ownership = Data("trano-git-tracking-v1\n".utf8)
        func ownedRegularFile(_ url: URL) throws -> Bool {
            var value = stat()
            if lstat(url.path, &value) != 0 {
                if errno == ENOENT { return false }
                throw TerminalError.runtime("Cannot inspect Git tracking file")
            }
            guard value.st_uid == getuid(), value.st_mode & S_IFMT == S_IFREG, value.st_mode & 0o077 == 0 else {
                throw TerminalError.invalid("Git tracking files must be owned private regular files")
            }
            return true
        }
        let hasFile = try ownedRegularFile(file), hasMarker = try ownedRegularFile(marker)
        guard !hasFile || hasMarker else { throw TerminalError.invalid("Refusing to replace unmanaged Git executable") }
        if hasMarker { guard try Data(contentsOf: marker) == ownership else { throw TerminalError.invalid("Unknown Git tracking ownership marker") } }
        else { try TerminalRuntime.atomicWrite(ownership, to: marker) }
        let data = Data(script.utf8)
        let current = hasFile ? try Data(contentsOf: file) : nil
        if current != data { try TerminalRuntime.atomicWrite(data, to: file) }
        guard chmod(file.path, 0o700) == 0 else { throw TerminalError.runtime("Cannot make Git tracking executable") }
    }
}
