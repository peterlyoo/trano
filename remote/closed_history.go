package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
)

const closedHistoryBytes = 1024 * 1024
const closedHistoryRecords = 10000

type closedShellSelection struct {
	Token      string `json:"token"`
	Shell      string `json:"shell"`
	PID        int    `json:"pid"`
	Generation string `json:"generation"`
	BootID     string `json:"bootID"`
}

func (r *Runtime) readClosedShellSelection(id string) (closedShellSelection, error) {
	var value closedShellSelection
	if !validID.MatchString(id) {
		return value, errors.New("invalid shell history owner")
	}
	data, err := readClosedFile(filepath.Join(r.root, "shell-history", id+".json"), 8192)
	if err != nil {
		return value, err
	}
	if err := json.Unmarshal(data, &value); err != nil || !validID.MatchString(value.Token) || !closedShellPath(value.Shell) {
		return value, errors.New("invalid shell history selection")
	}
	return value, nil
}

func (r *Runtime) prepareClosedShellSelection(id, shell string) (closedShellSelection, []string, error) {
	if !validID.MatchString(id) || !closedShellPath(shell) {
		return closedShellSelection{}, nil, errors.New("invalid shell history selection")
	}
	dir := filepath.Join(r.root, "shell-history")
	if err := ownedDirectory(dir); err != nil {
		return closedShellSelection{}, nil, err
	}
	token, err := uuid()
	if err != nil {
		return closedShellSelection{}, nil, err
	}
	selection := closedShellSelection{Token: token, Shell: shell}
	env := []string{"TRANO_HISTORY_FILE=" + filepath.Join(dir, token+".history"), "TRANO_HISTORY_OWNER=", "TRANO_HISTORY_IMPORT="}
	return selection, env, nil
}

func (r *Runtime) saveClosedShellSelection(id string, selection closedShellSelection, pid int) error {
	selection.PID = pid
	if process, err := r.closedController().Observe(r, id); err == nil && process.PID == pid {
		selection.Generation = process.Generation
		if len(process.Witnesses) > 0 {
			selection.BootID = process.Witnesses[0].BootID
		}
	}
	data, err := json.Marshal(selection)
	if err != nil {
		return err
	}
	return writeClosedFile(filepath.Join(r.root, "shell-history", id+".json"), append(data, '\n'))
}

func (r *Runtime) captureClosedHistory(id string, process closedProcess) ([]byte, string, error) {
	kind := filepath.Base(process.Shell)
	if kind != "bash" && kind != "zsh" {
		return nil, "unavailable", nil
	}
	if selection, err := r.readClosedShellSelection(id); err == nil && selection.PID == process.PID && selection.Generation == process.Generation && selection.Shell == process.Shell && len(process.Witnesses) > 0 && selection.BootID == process.Witnesses[0].BootID {
		path := filepath.Join(r.root, "shell-history", selection.Token+".history")
		if err := closedHistoryExportReady(path); err != nil {
			return nil, "", err
		}
		data, readErr := readNativeClosedHistory(path, kind, true)
		if err := closedHistoryExportReady(path); err != nil {
			return nil, "", err
		}
		if readErr == nil {
			return data, "journal", nil
		}
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, "unavailable", nil
	}
	name := ".bash_history"
	if kind == "zsh" {
		name = ".zsh_history"
	}
	if data, err := readNativeClosedHistory(filepath.Join(home, name), kind, false); err == nil {
		return data, "persistedFallback", nil
	}
	return nil, "unavailable", nil
}

func closedHistoryExportReady(path string) error {
	_, err := readClosedFile(path+".pending", 64)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	return errors.New("native shell history export is in progress; retry closing this terminal after the shell finishes its snapshot")
}

func readNativeClosedHistory(path, kind string, private bool) ([]byte, error) {
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), path)
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	owner, ok := info.Sys().(*syscall.Stat_t)
	if !info.Mode().IsRegular() || !ok || owner.Uid != uint32(os.Getuid()) || owner.Nlink != 1 || private && info.Mode().Perm()&0077 != 0 {
		return nil, errors.New("invalid native shell history source")
	}
	start := info.Size() - closedHistoryBytes - 65536
	if start < 0 {
		start = 0
	}
	if _, err := file.Seek(start, io.SeekStart); err != nil {
		return nil, err
	}
	data, err := io.ReadAll(io.LimitReader(file, closedHistoryBytes+65537))
	if err != nil {
		return nil, err
	}
	if bytes.IndexByte(data, 0) >= 0 {
		return nil, errors.New("invalid native shell history data")
	}
	return boundNativeClosedHistory(data, kind, start > 0 || info.Size() > closedHistoryBytes), nil
}

func boundNativeClosedHistory(data []byte, kind string, partial bool) []byte {
	if len(data) == 0 {
		return nil
	}
	last := bytes.LastIndexByte(data, '\n')
	if last < 0 {
		return nil
	}
	data = data[:last+1]
	boundaries := []int{}
	timestamped := false
	if kind == "bash" {
		for offset := 0; offset < len(data); {
			end := bytes.IndexByte(data[offset:], '\n')
			if end < 0 {
				break
			}
			line := data[offset : offset+end]
			if len(line) >= 10 && line[0] == '#' {
				if _, err := strconv.ParseUint(string(line[1:]), 10, 64); err == nil {
					boundaries = append(boundaries, offset)
					timestamped = true
				}
			}
			offset += end + 1
		}
	}
	if !timestamped {
		if !partial {
			boundaries = append(boundaries, 0)
		}
		for index, value := range data {
			if value == '\n' && index+1 < len(data) && (kind != "zsh" || index == 0 || data[index-1] != '\\') {
				boundaries = append(boundaries, index+1)
			}
		}
	}
	for index, start := range boundaries {
		if len(data)-start <= closedHistoryBytes && len(boundaries)-index <= closedHistoryRecords {
			return append([]byte(nil), data[start:]...)
		}
	}
	return nil
}

func (r *Runtime) prepareClosedHistoryImport(snapshot closedTerminalSnapshot) error {
	dir, err := r.closedDirectory(false)
	if err != nil {
		return err
	}
	return writeClosedFile(filepath.Join(dir, snapshot.OperationID+".history"), snapshot.History)
}

func closedHistoryStartup(kind string) string {
	switch kind {
	case "zsh":
		return `if [[ -n "$TRANO_HISTORY_FILE" && -z "$TRANO_HISTORY_OWNER" ]]; then
  export TRANO_HISTORY_OWNER=$$
  if [[ -n "$TRANO_HISTORY_IMPORT" && -f "$TRANO_HISTORY_IMPORT" ]]; then builtin fc -RI "$TRANO_HISTORY_IMPORT"; fi
  unset TRANO_HISTORY_IMPORT
  _trano_history_save() {
    [[ "$TRANO_HISTORY_OWNER" == $$ ]] || return
    (
      umask 077
      ulimit -f 16384 || exit 1
      trap 'exit 1' XFSZ
      local HISTSIZE=10000 SAVEHIST=10000
      local raw bounded pending
      pending=$(command mktemp "${TRANO_HISTORY_FILE}.pending.XXXXXXXX") || exit 1
      builtin printf '%s\n' "$TRANO_HISTORY_OWNER" > "$pending" || exit 1
      command mv -f -- "$pending" "$TRANO_HISTORY_FILE.pending" || exit 1
      raw=$(command mktemp "${TRANO_HISTORY_FILE}.raw.XXXXXXXX") || exit 1
      bounded=$(command mktemp "${TRANO_HISTORY_FILE}.write.XXXXXXXX") || { command rm -f -- "$raw"; exit 1; }
      trap 'command rm -f -- "$raw" "$raw.new" "$raw.LOCK" "$bounded"' EXIT
      builtin fc -W "$raw" || exit 1
      [[ $(command wc -c < "$raw") -lt 8388608 ]] || exit 1
      command tail -c 1048577 "$raw" > "$bounded" || exit 1
      command mv -f -- "$bounded" "$TRANO_HISTORY_FILE" || exit 1
      command rm -f -- "$TRANO_HISTORY_FILE.pending"
    ) >/dev/null 2>&1 || true
    return 0
  }
  autoload -Uz add-zsh-hook
  add-zsh-hook preexec _trano_history_save
  add-zsh-hook precmd _trano_history_save
  _trano_history_save
fi
`
	case "bash":
		return `if [[ -n "$TRANO_HISTORY_FILE" && -z "$TRANO_HISTORY_OWNER" ]]; then
  export TRANO_HISTORY_OWNER=$$
  if [[ -n "$TRANO_HISTORY_IMPORT" && -f "$TRANO_HISTORY_IMPORT" ]]; then builtin history -r "$TRANO_HISTORY_IMPORT"; fi
  unset TRANO_HISTORY_IMPORT
  _trano_history_save() {
    [[ "$TRANO_HISTORY_OWNER" == $$ && -z "${_TRANO_HISTORY_BUSY:-}" ]] || return
    local _TRANO_HISTORY_BUSY=1
    (
      umask 077
      ulimit -f 16384 || exit 1
      trap 'exit 1' XFSZ
      HISTSIZE=10000
      HISTTIMEFORMAT='%s '
      local raw bounded pending
      pending=$(command mktemp "${TRANO_HISTORY_FILE}.pending.XXXXXXXX") || exit 1
      builtin printf '%s\n' "$TRANO_HISTORY_OWNER" > "$pending" || exit 1
      command mv -f -- "$pending" "$TRANO_HISTORY_FILE.pending" || exit 1
      raw=$(command mktemp "${TRANO_HISTORY_FILE}.raw.XXXXXXXX") || exit 1
      bounded=$(command mktemp "${TRANO_HISTORY_FILE}.write.XXXXXXXX") || { command rm -f -- "$raw"; exit 1; }
      trap 'command rm -f -- "$raw" "$bounded"' EXIT
      builtin history -w "$raw" || exit 1
      [[ $(command wc -c < "$raw") -lt 8388608 ]] || exit 1
      command tail -c 1048577 "$raw" > "$bounded" || exit 1
      command mv -f -- "$bounded" "$TRANO_HISTORY_FILE" || exit 1
      command rm -f -- "$TRANO_HISTORY_FILE.pending"
    ) >/dev/null 2>&1 || true
    return 0
  }
  if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == 'declare -a'* ]]; then PROMPT_COMMAND+=(_trano_history_save); else PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND;} _trano_history_save"; fi
  if [[ -z $(trap -p DEBUG) ]]; then trap '_trano_history_save' DEBUG; fi
  _trano_history_save
fi
` + closedAgentStartup()
	default:
		return closedAgentStartup()
	}
}

func closedAgentStartup() string {
	return `if [ -n "$TRANO_CLOSED_OPERATION" ]; then
  if [ -n "$TRANO_RESTORE_CWD" ]; then cd -- "$TRANO_RESTORE_CWD" || return; fi
  unset TRANO_RESTORE_CWD
  _trano_closed_operation="$TRANO_CLOSED_OPERATION"
  unset TRANO_CLOSED_OPERATION
  "$TRANO_REMOTE_HELPER" closed-start "$_trano_closed_operation"
  unset _trano_closed_operation
fi
`
}

func closedFishStartup() string {
	return `set -l _trano_closed_operation "$TRANO_CLOSED_OPERATION"
set -e TRANO_CLOSED_OPERATION
cd -- "$TRANO_RESTORE_CWD"; and command "$TRANO_REMOTE_HELPER" closed-start "$_trano_closed_operation"
set -e TRANO_RESTORE_CWD
`
}
