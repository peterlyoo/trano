import Foundation

extension TerminalRuntime {
    func shellEnvironment() throws -> [String] {
        guard let helperExecutable else { return [] }
        prepareWorktreeTracking()
        let integration = try ManagedDirectory.ensure(root, component: "shell")
        let shims = try ManagedDirectory.ensure(root, component: "bin")
        for provider in ["claude", "codex"] {
            let file = shims.appendingPathComponent(provider)
            let script = "#!/bin/sh\nexec \"$TRANO_CLI_PATH\" run --agent " + provider + " -- \"$@\"\n"
            if (try? String(contentsOf: file, encoding: .utf8)) != script { try Self.atomicWrite(Data(script.utf8), to: file) }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        for name in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
            var script = """
            if [[ "$TRANO_ZDOTDIR_PRESENT" == 1 ]]; then
              export ZDOTDIR="$TRANO_ZDOTDIR_VALUE"
            else
              unset ZDOTDIR
            fi
            if [[ -r "${ZDOTDIR:-$HOME}/\(name)" ]]; then
              source "${ZDOTDIR:-$HOME}/\(name)"
            fi

            """
            if name != ".zlogin" {
                script += """
                if (( ${+ZDOTDIR} )); then
                  export TRANO_ZDOTDIR_PRESENT=1 TRANO_ZDOTDIR_VALUE="$ZDOTDIR"
                else
                  export TRANO_ZDOTDIR_PRESENT=0 TRANO_ZDOTDIR_VALUE=''
                fi
                export ZDOTDIR="$TRANO_SHELL_DIR"

                """
            }
            if [".zshrc", ".zlogin"].contains(name) { script += "export PATH=\"${TRANO_GIT_SHIM_DIR:-$TRANO_DATA_DIR/git-bin}:$TRANO_SHIM_DIR:$PATH\"\n" }
            if name == ".zshrc" {
                script += """
                _trano_record_directory() {
                  if [[ "$PWD" != "${TRANO_LAST_CWD:-}" ]]; then
                    "$TRANO_CLI_PATH" cwd "$TRANO_SESSION" "$PWD" >/dev/null 2>&1
                    TRANO_LAST_CWD="$PWD"
                  fi
                }
                autoload -Uz add-zsh-hook
                add-zsh-hook precmd _trano_record_directory

                """
            }
            if name == ".zshrc" || name == ".zlogin" {
                script += "if [[ -n \"${TRANO_HISTORY_INIT:-}\" && -r \"$TRANO_HISTORY_INIT\" ]]; then source \"$TRANO_HISTORY_INIT\"; fi\n"
            }
            let file = integration.appendingPathComponent(name)
            if (try? String(contentsOf: file, encoding: .utf8)) != script { try Self.atomicWrite(Data(script.utf8), to: file) }
        }
        let original = ProcessInfo.processInfo.environment["ZDOTDIR"]
        return ["TRANO_GIT_SHIM_DIR=" + root.appendingPathComponent("git-bin").path, "TRANO_CLI_PATH=" + helperExecutable, "ZDOTDIR=" + integration.path,
                "TRANO_SHELL_DIR=" + integration.path, "TRANO_SHIM_DIR=" + shims.path,
                "TRANO_ZDOTDIR_PRESENT=" + (original == nil ? "0" : "1"), "TRANO_ZDOTDIR_VALUE=" + (original ?? "")]
    }
}
