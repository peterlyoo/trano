import Foundation

public struct PreparedTerminalShell: Equatable, Sendable {
    public let command: TerminalStartupCommand
    public let environment: [String]
    public init(command: TerminalStartupCommand, environment: [String]) {
        self.command = command; self.environment = environment
    }
}

enum ShellHistoryIntegration {
    static let zsh = #"""
    [[ -o interactive ]] || return
    [[ -z "${TRANO_HISTORY_OWNER_PID:-}" || "$TRANO_HISTORY_OWNER_PID" == "$$" ]] || return
    [[ "${_trano_history_loaded:-}" != "$TRANO_HISTORY_TOKEN" ]] || return
    export TRANO_HISTORY_OWNER_PID=$$
    typeset -g _trano_history_loaded="$TRANO_HISTORY_TOKEN" _trano_history_restored=0
    _trano_history_snapshot() {
      [[ "$TRANO_HISTORY_OWNER_PID" == "$$" ]] || return 0
      (
        umask 077
        ulimit -f 16384 || exit 1
        trap 'exit 1' XFSZ
        local HISTSIZE=10000 SAVEHIST=10000
        local raw bounded capability pending
        pending=$(/usr/bin/mktemp "${TRANO_HISTORY_FILE}.pending.XXXXXXXX") || exit 1
        builtin printf '%s\n' "$TRANO_HISTORY_OWNER_PID" > "$pending" || exit 1
        /bin/mv -f "$pending" "${TRANO_HISTORY_FILE}.pending" || exit 1
        raw=$(/usr/bin/mktemp "${TRANO_HISTORY_FILE}.raw.XXXXXXXX") || exit 1
        bounded=$(/usr/bin/mktemp "${TRANO_HISTORY_FILE}.write.XXXXXXXX") || { /bin/rm -f "$raw"; exit 1; }
        capability=$(/usr/bin/mktemp "${TRANO_HISTORY_CAPABILITY}.write.XXXXXXXX") || { /bin/rm -f "$raw" "$bounded"; exit 1; }
        trap '/bin/rm -f "$raw" "$raw.new" "$raw.LOCK" "$bounded" "$capability"' EXIT
        builtin fc -W "$raw" || exit 1
        [[ $(/usr/bin/wc -c < "$raw") -lt 8388608 ]] || exit 1
        /usr/bin/tail -c 1048577 "$raw" > "$bounded" || exit 1
        builtin printf 'preexec\n' > "$capability" || exit 1
        /bin/mv -f "$bounded" "$TRANO_HISTORY_FILE" || exit 1
        /bin/mv -f "$capability" "$TRANO_HISTORY_CAPABILITY" || exit 1
        /bin/rm -f "${TRANO_HISTORY_FILE}.pending"
      ) >/dev/null 2>&1 || true
      return 0
    }
    _trano_history_prompt() {
      if [[ "$_trano_history_restored" == 0 ]]; then
        _trano_history_restored=1
        if [[ -n "${TRANO_HISTORY_RESTORE:-}" && -f "$TRANO_HISTORY_RESTORE" && ! -L "$TRANO_HISTORY_RESTORE" ]]; then
          builtin fc -RI "$TRANO_HISTORY_RESTORE"
        fi
      fi
      _trano_history_snapshot
      return 0
    }
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd _trano_history_prompt
    add-zsh-hook preexec _trano_history_snapshot

    """#

    static let bash = #"""
    [[ $- == *i* ]] || return
    [[ -z "${TRANO_HISTORY_OWNER_PID:-}" || "$TRANO_HISTORY_OWNER_PID" == "$$" ]] || return
    [[ "${_trano_history_loaded:-}" != "$TRANO_HISTORY_TOKEN" ]] || return
    export TRANO_HISTORY_OWNER_PID=$$
    _trano_history_loaded=$TRANO_HISTORY_TOKEN
    _trano_history_restored=0
    _trano_history_preexec_available=0
    _trano_history_at_prompt=0
    _trano_history_snapshot() {
      [[ "$TRANO_HISTORY_OWNER_PID" == "$$" ]] || return 0
      (
        umask 077
        ulimit -f 16384 || exit 1
        trap 'exit 1' XFSZ
        HISTSIZE=10000
        HISTTIMEFORMAT='%s '
        local raw bounded capability pending
        pending=$(/usr/bin/mktemp "${TRANO_HISTORY_FILE}.pending.XXXXXXXX") || exit 1
        builtin printf '%s\n' "$TRANO_HISTORY_OWNER_PID" > "$pending" || exit 1
        /bin/mv -f "$pending" "${TRANO_HISTORY_FILE}.pending" || exit 1
        raw=$(/usr/bin/mktemp "${TRANO_HISTORY_FILE}.raw.XXXXXXXX") || exit 1
        bounded=$(/usr/bin/mktemp "${TRANO_HISTORY_FILE}.write.XXXXXXXX") || { /bin/rm -f "$raw"; exit 1; }
        capability=$(/usr/bin/mktemp "${TRANO_HISTORY_CAPABILITY}.write.XXXXXXXX") || { /bin/rm -f "$raw" "$bounded"; exit 1; }
        trap '/bin/rm -f "$raw" "$bounded" "$capability"' EXIT
        builtin history -w "$raw" || exit 1
        [[ $(/usr/bin/wc -c < "$raw") -lt 8388608 ]] || exit 1
        /usr/bin/tail -c 1048577 "$raw" > "$bounded" || exit 1
        if [[ "$_trano_history_preexec_available" == 1 ]]; then
          builtin printf 'preexec\n' > "$capability"
        else
          builtin printf 'prompt\n' > "$capability"
        fi
        /bin/mv -f "$bounded" "$TRANO_HISTORY_FILE" || exit 1
        /bin/mv -f "$capability" "$TRANO_HISTORY_CAPABILITY" || exit 1
        /bin/rm -f "${TRANO_HISTORY_FILE}.pending"
      ) >/dev/null 2>&1 || true
      return 0
    }
    _trano_history_prompt() {
      local previous=$?
      if [[ "$_trano_history_restored" == 0 ]]; then
        _trano_history_restored=1
        if [[ -n "${TRANO_HISTORY_RESTORE:-}" && -f "$TRANO_HISTORY_RESTORE" && ! -L "$TRANO_HISTORY_RESTORE" ]]; then
          builtin history -r "$TRANO_HISTORY_RESTORE"
        fi
      fi
      _trano_history_snapshot
      if [[ "$PWD" != "${TRANO_LAST_CWD:-}" ]]; then
        "$TRANO_CLI_PATH" cwd "$TRANO_SESSION" "$PWD" >/dev/null 2>&1
        TRANO_LAST_CWD=$PWD
      fi
      _trano_history_at_prompt=1
      return "$previous"
    }
    _trano_history_before_command() {
      if [[ "$_trano_history_at_prompt" == 1 && ${BASH_SUBSHELL:-0} == 0 ]]; then
        _trano_history_at_prompt=0
        _trano_history_snapshot
      fi
      return 0
    }
    if [[ $(declare -p preexec_functions 2>/dev/null) == 'declare -a'* ]]; then
      preexec_functions+=(_trano_history_snapshot)
      _trano_history_preexec_available=1
    elif [[ -z "$(trap -p DEBUG)" ]]; then
      trap '_trano_history_before_command' DEBUG
      _trano_history_preexec_available=1
    fi
    if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a'* ]]; then
      PROMPT_COMMAND+=(_trano_history_prompt)
    else
      PROMPT_COMMAND="${PROMPT_COMMAND:-}"$'\n''_trano_history_prompt'
    fi

    """#

    static let fish = #"""
    status is-interactive; or return
    if set -q fish_private_mode; and test "$fish_private_mode" = 1
      return
    end
    if set -q fish_history; and test -z "$fish_history"
      return
    end
    if set -q TRANO_HISTORY_OWNER_PID; and test -n "$TRANO_HISTORY_OWNER_PID"; and test "$TRANO_HISTORY_OWNER_PID" != "$fish_pid"
      return
    end
    if test "$_trano_history_loaded" = "$TRANO_HISTORY_TOKEN"
      return
    end
    set -gx TRANO_HISTORY_OWNER_PID $fish_pid
    set -gx PATH "$TRANO_GIT_SHIM_DIR" "$TRANO_SHIM_DIR" $PATH
    set -g _trano_history_loaded "$TRANO_HISTORY_TOKEN"
    set -g _trano_history_restored 0
    function _trano_history_snapshot
      if set -q fish_private_mode; and test "$fish_private_mode" = 1
        return
      end
      if set -q fish_history; and test -z "$fish_history"
        return
      end
      set -l pending (/usr/bin/mktemp "$TRANO_HISTORY_FILE.pending.XXXXXXXX"); or return
      /bin/chmod 600 "$pending"
      builtin printf '%s\n' "$TRANO_HISTORY_OWNER_PID" > "$pending"; or return
      /bin/mv -f "$pending" "$TRANO_HISTORY_FILE.pending"; or return
      set -l bounded (/usr/bin/mktemp "$TRANO_HISTORY_FILE.write.XXXXXXXX"); or return
      /bin/chmod 600 "$bounded"
      builtin history search --null --reverse --max 10000 | /usr/bin/tail -c 1048577 > "$bounded"
      set -l saved_status $pipestatus
      if test "$saved_status[2]" != 0
        /bin/rm -f "$bounded"
        return
      end
      /bin/mv -f "$bounded" "$TRANO_HISTORY_FILE"; and /bin/rm -f "$TRANO_HISTORY_FILE.pending"
    end
    function _trano_history_prompt --on-event fish_prompt
      if test "$_trano_history_restored" = 0
        set -g _trano_history_restored 1
        if string match -rq '^([4-9]|[1-9][0-9]+)\.' -- "$version"
          if test -n "$TRANO_HISTORY_RESTORE"; and test -f "$TRANO_HISTORY_RESTORE"; and not test -L "$TRANO_HISTORY_RESTORE"
            while read --null --local entry
              builtin history append -- "$entry"
            end < "$TRANO_HISTORY_RESTORE"
          end
        end
      end
      _trano_history_snapshot
      if test "$PWD" != "$TRANO_LAST_CWD"
        "$TRANO_CLI_PATH" cwd "$TRANO_SESSION" "$PWD" >/dev/null 2>&1
        set -g TRANO_LAST_CWD "$PWD"
      end
    end
    function _trano_history_preexec --on-event fish_preexec
      _trano_history_snapshot
    end

    """#

    static func bashStartup(login: Bool) -> String {
        let startup = login ? #"""
        if [[ -r /etc/profile ]]; then source /etc/profile; fi
        for _trano_profile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
          if [[ -r "$_trano_profile" ]]; then source "$_trano_profile"; break; fi
        done
        unset _trano_profile
        """# : #"""
        if [[ -r "$HOME/.bashrc" ]]; then source "$HOME/.bashrc"; fi
        """#
        return startup + "\n" + #"""
        export PATH="${TRANO_GIT_SHIM_DIR:-$TRANO_DATA_DIR/git-bin}:$TRANO_SHIM_DIR:$PATH"
        """# + "\n" + bash
    }
}

extension TerminalRuntime {
    public func prepareTerminalShell(_ command: TerminalStartupCommand, paneID: String,
                                     restoring: Bool) throws -> PreparedTerminalShell {
        let store = ShellHistoryStore(runtimeRoot: root)
        let files = try store.prepareJournal(paneID: paneID, command: command, restoring: restoring,
                                             seedEmpty: helperExecutable == nil)
        guard helperExecutable != nil else { return PreparedTerminalShell(command: command, environment: []) }
        let format = ShellHistoryStore.format(for: command)
        let flags: Set<String> = ["-l", "-i", "-li", "-il", "--login", "--interactive"]
        guard format != .none, command.arguments.allSatisfy({ flags.contains($0) }) else {
            return PreparedTerminalShell(command: command, environment: [])
        }
        var environment = try shellEnvironment()
        let integration = try ManagedDirectory.ensure(root, component: "shell")
        environment += ["TRANO_HISTORY_FILE=" + files.journal.path,
                        "TRANO_HISTORY_CAPABILITY=" + files.capability.path,
                        "TRANO_HISTORY_RESTORE=" + (files.restore?.path ?? ""),
                        "TRANO_HISTORY_TOKEN=" + files.token, "TRANO_HISTORY_OWNER_PID="]
        var prepared = command
        switch format {
        case .zsh:
            let script = integration.appendingPathComponent("history.zsh")
            try Self.atomicWrite(Data(ShellHistoryIntegration.zsh.utf8), to: script)
            environment.append("TRANO_HISTORY_INIT=" + script.path)
        case .bash:
            environment.removeAll { $0.hasPrefix("ZDOTDIR=") || $0.hasPrefix("TRANO_ZDOTDIR_") }
            let login = command.arguments.contains { ["-l", "-li", "-il", "--login"].contains($0) }
            let script = integration.appendingPathComponent(login ? "history-login.bash" : "history.bash")
            try Self.atomicWrite(Data(ShellHistoryIntegration.bashStartup(login: login).utf8), to: script)
            prepared.arguments = ["--noprofile", "--rcfile", script.path, "-i"]
        case .fish:
            environment.removeAll { $0.hasPrefix("ZDOTDIR=") || $0.hasPrefix("TRANO_ZDOTDIR_") }
            let script = integration.appendingPathComponent("history.fish")
            try Self.atomicWrite(Data(ShellHistoryIntegration.fish.utf8), to: script)
            environment.append("TRANO_HISTORY_INIT=" + script.path)
            prepared.arguments += ["--init-command", "source \"$TRANO_HISTORY_INIT\""]
        case .none: break
        }
        return PreparedTerminalShell(command: prepared, environment: environment)
    }
}
