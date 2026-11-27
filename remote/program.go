package main

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

const maxProgramArgs = 64 * 1024

var programValueFlags = map[string]bool{
	"--as": true, "--as-group": true, "--as-uid": true, "--as-user-extra": true,
	"--cache-dir": true, "--certificate-authority": true, "--client-certificate": true, "--client-key": true,
	"--cluster": true, "--context": true, "--kubeconfig": true, "--kuberc": true,
	"--namespace": true, "--password": true, "--profile": true, "--profile-output": true,
	"--proxy-url": true, "--request-timeout": true, "--server": true,
	"--storage-driver-buffer-duration": true, "--storage-driver-db": true, "--storage-driver-host": true,
	"--storage-driver-password": true, "--storage-driver-table": true, "--storage-driver-user": true,
	"--tls-server-name": true, "--token": true, "--user": true, "--username": true,
	"--v": true, "--vmodule": true, "-n": true, "-s": true, "-v": true,
}

var programBoolFlags = map[string]bool{
	"--disable-compression": true, "--insecure-skip-tls-verify": true, "--match-server-version": true,
	"--storage-driver-secure": true, "--warnings-as-errors": true,
}

func classifyProgram(image string, args []string) string {
	name := filepath.Base(image)
	switch name {
	case "zsh", "claude", "codex", "k9s":
		return name
	case "kubectl":
	default:
		return ""
	}
	for index := 1; index < len(args); index++ {
		arg := args[index]
		if arg == "--" || arg == "" {
			return ""
		}
		if !strings.HasPrefix(arg, "-") {
			if arg == "exec" {
				return "kubectl_exec"
			}
			return ""
		}
		flag, _, attached := strings.Cut(arg, "=")
		if programValueFlags[flag] {
			if !attached {
				index++
				if index >= len(args) {
					return ""
				}
			}
			continue
		}
		if programBoolFlags[flag] {
			continue
		}
		if len(arg) > 2 && (strings.HasPrefix(arg, "-n") || strings.HasPrefix(arg, "-s") || strings.HasPrefix(arg, "-v")) && !strings.HasPrefix(arg, "--") {
			continue
		}
		return ""
	}
	return ""
}

type programProcess struct {
	pid, parent, group, foreground int
	tty                            int64
	started                        uint64
	image                          string
}

type programProbe struct {
	root string
	uid  uint32
}

func newProgramProbe(root string, uid uint32) *programProbe {
	return &programProbe{root: root, uid: uid}
}

func readProgramFile(path string, limit int64) ([]byte, bool) {
	file, err := os.Open(path)
	if err != nil {
		return nil, false
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	return data, err == nil && int64(len(data)) <= limit
}

func (p *programProbe) process(pid int) (programProcess, bool) {
	if pid <= 1 {
		return programProcess{}, false
	}
	dir := filepath.Join(p.root, strconv.Itoa(pid))
	info, err := os.Stat(dir)
	if err != nil || !info.IsDir() {
		return programProcess{}, false
	}
	owner, ok := info.Sys().(*syscall.Stat_t)
	if !ok || owner.Uid != p.uid {
		return programProcess{}, false
	}
	data, ok := readProgramFile(filepath.Join(dir, "stat"), 8192)
	if !ok {
		return programProcess{}, false
	}
	text := string(data)
	start, end := strings.IndexByte(text, '('), strings.LastIndexByte(text, ')')
	if start < 1 || end <= start {
		return programProcess{}, false
	}
	actual, err := strconv.Atoi(strings.TrimSpace(text[:start]))
	fields := strings.Fields(text[end+1:])
	if err != nil || actual != pid || len(fields) < 20 || fields[0] == "Z" || fields[0] == "X" {
		return programProcess{}, false
	}
	result := programProcess{pid: pid}
	for index, value := range map[int]*int{1: &result.parent, 2: &result.group, 5: &result.foreground} {
		parsed, err := strconv.Atoi(fields[index])
		if err != nil {
			return programProcess{}, false
		}
		*value = parsed
	}
	result.tty, err = strconv.ParseInt(fields[4], 10, 64)
	if err != nil {
		return programProcess{}, false
	}
	result.started, err = strconv.ParseUint(fields[19], 10, 64)
	if err != nil || result.started == 0 {
		return programProcess{}, false
	}
	result.image, err = os.Readlink(filepath.Join(dir, "exe"))
	if err != nil || !filepath.IsAbs(result.image) {
		return programProcess{}, false
	}
	result.image = strings.TrimSuffix(result.image, " (deleted)")
	return result, true
}

func (p *programProbe) descendant(process programProcess, pane programProcess) bool {
	seen := map[int]bool{}
	for count := 0; count < 64; count++ {
		if process.pid == pane.pid {
			return true
		}
		if seen[process.pid] || process.tty != pane.tty {
			return false
		}
		seen[process.pid] = true
		var ok bool
		process, ok = p.process(process.parent)
		if !ok {
			return false
		}
	}
	return false
}

func (p *programProbe) candidate(process programProcess, pane programProcess) string {
	if process.group != pane.foreground || process.foreground != pane.foreground || process.tty != pane.tty || !p.descendant(process, pane) {
		return ""
	}
	var args []string
	if filepath.Base(process.image) == "kubectl" {
		data, ok := readProgramFile(filepath.Join(p.root, strconv.Itoa(process.pid), "cmdline"), maxProgramArgs)
		if !ok || len(data) == 0 || data[len(data)-1] != 0 {
			return ""
		}
		parts := bytes.Split(data[:len(data)-1], []byte{0})
		if len(parts) > 256 {
			return ""
		}
		for _, part := range parts {
			args = append(args, string(part))
		}
	}
	program := classifyProgram(process.image, args)
	currentPane, paneOK := p.process(pane.pid)
	currentProcess, processOK := p.process(process.pid)
	if !paneOK || !processOK || currentPane != pane || currentProcess != process {
		return ""
	}
	return program
}

func (p *programProbe) foreground(pid int) string {
	pane, ok := p.process(pid)
	if !ok || pane.tty == 0 || pane.foreground <= 1 {
		return ""
	}
	if leader, ok := p.process(pane.foreground); ok {
		if program := p.candidate(leader, pane); program != "" {
			return program
		}
	}
	queue := []int{pid}
	seen := map[int]bool{}
	for len(queue) > 0 && len(seen) < 64 {
		current := queue[0]
		queue = queue[1:]
		if seen[current] {
			continue
		}
		seen[current] = true
		process, ok := p.process(current)
		if !ok || process.tty != pane.tty {
			continue
		}
		if program := p.candidate(process, pane); program != "" {
			return program
		}
		children, ok := readProgramFile(filepath.Join(p.root, strconv.Itoa(current), "task", strconv.Itoa(current), "children"), 16384)
		if !ok {
			continue
		}
		for _, field := range strings.Fields(string(children)) {
			child, err := strconv.Atoi(field)
			if err == nil && child > 1 && len(queue) < 64 {
				if record, ok := p.process(child); ok && record.parent == current {
					queue = append(queue, child)
				}
			}
		}
	}
	return ""
}

func (p *programProbe) inputIdentities(pid int) (string, string) {
	process, ok := p.process(pid)
	if !ok || process.tty == 0 || process.group <= 1 {
		return "", ""
	}
	current, ok := p.process(pid)
	if !ok || current != process {
		return "", ""
	}
	identity := strconv.Itoa(process.pid) + ":" + strconv.FormatUint(process.started, 10) + ":" +
		strconv.FormatInt(process.tty, 10) + ":" + strconv.Itoa(process.group)
	if process.group != pid || process.foreground != process.group {
		return identity, ""
	}
	switch filepath.Base(process.image) {
	case "zsh", "bash", "fish", "dash", "sh", "ksh":
		return identity, identity
	default:
		return identity, ""
	}
}

func projectForegroundPrograms(sessions []Session, observe func(int) string, inputIdentities ...func(int) (string, string)) []Session {
	result := append([]Session(nil), sessions...)
	for index := range result {
		result[index].ForegroundProgram = ""
		backend, shell := "", ""
		if result[index].Alive {
			result[index].ForegroundProgram = observe(result[index].PID)
			if len(inputIdentities) > 0 && inputIdentities[0] != nil {
				backend, shell = inputIdentities[0](result[index].PID)
			}
		}
		if shell != backend {
			shell = ""
		}
		result[index].InputBackendIdentity = &backend
		result[index].ShellInputIdentity = &shell
	}
	return result
}

func linuxForegroundProgram(pid int) string {
	return newProgramProbe("/proc", uint32(os.Getuid())).foreground(pid)
}

func linuxInputIdentities(pid int) (string, string) {
	return newProgramProbe("/proc", uint32(os.Getuid())).inputIdentities(pid)
}
