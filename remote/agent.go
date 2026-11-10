package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
)

func ownedDirectory(path string) error {
	if err := os.Mkdir(path, 0700); err != nil && !os.IsExist(err) {
		return err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	owner, ok := info.Sys().(*syscall.Stat_t)
	if !info.IsDir() || !ok || owner.Uid != uint32(os.Getuid()) {
		return errors.New("integration path is not an owned directory")
	}
	return os.Chmod(path, 0700)
}
func bootIdentity() string {
	data, err := os.ReadFile("/proc/sys/kernel/random/boot_id")
	if err != nil {
		return "unavailable"
	}
	return strings.TrimSpace(string(data))
}
func providerConfig(provider string) string {
	key := "CLAUDE_CONFIG_DIR"
	if provider == "codex" {
		key = "CODEX_HOME"
	}
	if value := os.Getenv(key); filepath.IsAbs(value) {
		return value
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "."+provider)
}
func interactive(provider string, args []string) bool {
	excluded := map[string]bool{}
	values := map[string]bool{"--model": true, "-m": true, "--settings": true, "--mcp-config": true, "--plugin-dir": true, "--permission-mode": true, "--add-dir": true, "--session-id": true, "--resume": true, "-r": true, "--profile": true, "-p": provider == "codex", "--config": true, "-c": true, "--cd": true, "-C": true, "--sandbox": true, "-s": true, "--ask-for-approval": true, "-a": true}
	commands := []string{"exec", "e", "review", "login", "logout", "mcp", "plugin", "app-server", "completion", "debug", "features", "update"}
	if provider == "claude" {
		commands = []string{"auth", "plugin", "plugins", "mcp", "doctor", "update", "install", "setup-token"}
	}
	for _, v := range commands {
		excluded[v] = true
	}
	skip := false
	for _, a := range args {
		if skip {
			skip = false
			continue
		}
		if a == "--" {
			return true
		}
		if a == "--help" || a == "-h" || a == "--version" || a == "-v" || provider == "claude" && (a == "--print" || a == "-p" || a == "--bare") {
			return false
		}
		if strings.HasPrefix(a, "-") {
			skip = values[a]
			continue
		}
		return !excluded[a]
	}
	return true
}
func providerEnvironment(shim string) []string {
	result := []string{}
	for _, entry := range os.Environ() {
		key := strings.SplitN(entry, "=", 2)[0]
		if strings.HasPrefix(key, "REX_") || key == "TRANO_LAUNCH_ID" || key == "PATH" {
			continue
		}
		result = append(result, entry)
	}
	return append(result, "PATH="+withoutShimPath(os.Getenv("PATH"), shim))
}
func findProvider(provider, path string) (string, error) {
	for _, dir := range filepath.SplitList(path) {
		candidate := filepath.Join(dir, provider)
		info, err := os.Stat(candidate)
		if err == nil && !info.IsDir() && info.Mode()&0111 != 0 {
			return filepath.Abs(candidate)
		}
	}
	return "", fmt.Errorf("%s is not installed on this host", provider)
}
func (r *Runtime) RunAgent(provider string, args []string, resumeGeneration string) error {
	if provider != "claude" && provider != "codex" {
		return errors.New("unsupported provider")
	}
	shim := filepath.Join(r.root, "bin")
	executable, err := findProvider(provider, withoutShimPath(os.Getenv("PATH"), shim))
	if err != nil {
		return err
	}
	env := providerEnvironment(shim)
	if !interactive(provider, args) {
		return syscall.Exec(executable, append([]string{executable}, args...), env)
	}
	paneID := os.Getenv("TRANO_SESSION")
	cwd, err := os.Getwd()
	if err != nil {
		return err
	}
	lock, err := r.lock()
	if err != nil {
		return err
	}
	state, err := r.load()
	if err == nil {
		err = require(state, paneID)
	}
	if err != nil {
		lock.Close()
		return err
	}
	launch := AgentLaunch{SessionID: paneID, Provider: provider, Cwd: cwd, ConfigurationRoot: providerConfig(provider), BootID: bootIdentity(), ProcessID: os.Getpid(), Lifecycle: "active", UpdatedAt: now()}
	launch.ID, err = uuid()
	if err != nil {
		lock.Close()
		return err
	}
	kept := []AgentLaunch{}
	matched := resumeGeneration == ""
	for _, previous := range state.AgentLaunches {
		if previous.SessionID != paneID {
			kept = append(kept, previous)
			continue
		}
		if previous.Lifecycle == "active" && previous.BootID == launch.BootID && previous.ProcessID > 0 && syscall.Kill(previous.ProcessID, 0) == nil {
			lock.Close()
			return errors.New("pane already has an active agent")
		}
		if resumeGeneration != "" && previous.ID == resumeGeneration && previous.Lifecycle == "active" && previous.Provider == provider {
			launch.ProviderSessionID, launch.ConfigurationRoot = previous.ProviderSessionID, previous.ConfigurationRoot
			matched = true
		}
	}
	if !matched {
		lock.Close()
		return errors.New("resume launch changed")
	}
	state.AgentLaunches = append(kept, launch)
	for i := range state.Sessions {
		if state.Sessions[i].ID == paneID {
			state.Sessions[i].AgentTasks = nil
		}
	}
	err = r.save(state)
	lock.Close()
	if err != nil {
		return err
	}
	args, err = r.withHooks(provider, args)
	if err != nil {
		return err
	}
	env = append(env, "TRANO_LAUNCH_ID="+launch.ID)
	configKey := "CLAUDE_CONFIG_DIR"
	if provider == "codex" {
		configKey = "CODEX_HOME"
	}
	filtered := env[:0]
	for _, e := range env {
		if !strings.HasPrefix(e, configKey+"=") {
			filtered = append(filtered, e)
		}
	}
	env = append(filtered, configKey+"="+launch.ConfigurationRoot)
	gateRead, gateWrite, err := os.Pipe()
	if err != nil {
		return err
	}
	defer gateWrite.Close()
	child := exec.Command(r.helper, append([]string{"agent-exec", executable}, args...)...)
	child.Env = env
	child.Stdin = os.Stdin
	child.Stdout = os.Stdout
	child.Stderr = os.Stderr
	child.ExtraFiles = []*os.File{gateRead}
	child.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := child.Start(); err != nil {
		gateRead.Close()
		return err
	}
	gateRead.Close()
	lock, err = r.lock()
	if err != nil {
		_ = child.Process.Kill()
		_ = child.Wait()
		return err
	}
	state, err = r.load()
	if err == nil {
		found := false
		for i := range state.AgentLaunches {
			if state.AgentLaunches[i].ID == launch.ID {
				state.AgentLaunches[i].ProviderPID = child.Process.Pid
				found = true
			}
		}
		if !found {
			err = errors.New("launch changed before provider start")
		} else {
			err = r.save(state)
		}
	}
	lock.Close()
	if err != nil {
		_ = child.Process.Kill()
		_ = child.Wait()
		return err
	}
	restoreTerminal, err := handoffAgentTerminal(os.Stdin, child.Process.Pid)
	if err != nil {
		_ = child.Process.Kill()
		_ = child.Wait()
		return err
	}
	signals := make(chan os.Signal, 8)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	done := make(chan struct{})
	stopped := make(chan struct{})
	shutdown := make(chan struct{}, 1)
	go func() {
		defer close(stopped)
		for {
			select {
			case sig := <-signals:
				if sig == syscall.SIGTERM || sig == syscall.SIGHUP {
					select {
					case shutdown <- struct{}{}:
					default:
					}
				}
				if value, ok := sig.(syscall.Signal); ok {
					_ = syscall.Kill(-child.Process.Pid, value)
				}
			case <-done:
				return
			}
		}
	}()
	_, err = gateWrite.Write([]byte{1})
	gateWrite.Close()
	if err != nil {
		_ = child.Process.Kill()
	}
	waitErr := child.Wait()
	signal.Stop(signals)
	close(done)
	<-stopped
	terminalErr := restoreTerminal()
	normal := normalAgentExit(waitErr) && terminalErr == nil
	select {
	case <-shutdown:
		normal = false
	default:
	}
	if normal {
		_, checkErr := r.command("display-message", "-p", "-t", paneID+":0.0", "#{pane_pid}")
		normal = checkErr == nil
	}
	return errors.Join(waitErr, terminalErr, r.finishAgent(launch, resumeGeneration != "", normal))
}
func executeGatedProvider() error {
	if len(os.Args) < 3 {
		return errors.New("missing executable")
	}
	gate := os.NewFile(3, "launch-gate")
	if gate == nil {
		return errors.New("missing launch gate")
	}
	data := []byte{0}
	_, err := io.ReadFull(gate, data)
	gate.Close()
	if err != nil || data[0] != 1 {
		return errors.New("provider launch was cancelled")
	}
	return syscall.Exec(os.Args[2], os.Args[2:], os.Environ())
}
func (r *Runtime) finishAgent(original AgentLaunch, resuming, normal bool) error {
	lock, err := r.lock()
	if err != nil {
		return err
	}
	defer lock.Close()
	state, err := r.load()
	if err != nil {
		return err
	}
	var resumeErr error
	for i := range state.AgentLaunches {
		launch := &state.AgentLaunches[i]
		if launch.SessionID == original.SessionID && launch.ID == original.ID {
			launch.ProcessID = 0
			launch.ProviderPID = 0
			launch.UpdatedAt = now()
			if resuming && (!validID.MatchString(original.ProviderSessionID) || launch.StartedSessionID != original.ProviderSessionID) {
				normal = false
				launch.ProviderSessionID = original.ProviderSessionID
				launch.Cwd, launch.ConfigurationRoot = original.Cwd, original.ConfigurationRoot
				resumeErr = errors.New("remote agent exited before confirming conversation resume")
				result := RecoveryResult{SessionID: original.SessionID, Status: "needs_attention", Message: "Remote agent exited before confirming conversation resume", UpdatedAt: now()}
				found := false
				for j := range state.Recovery {
					if state.Recovery[j].SessionID == original.SessionID {
						state.Recovery[j], found = result, true
					}
				}
				if !found {
					state.Recovery = append(state.Recovery, result)
				}
			}
			if normal {
				launch.Lifecycle = "exited"
			}
		}
	}
	return errors.Join(resumeErr, r.save(state))
}
func (r *Runtime) ResumeAgent(id, generation string) (result error) {
	defer func() {
		if result == nil {
			return
		}
		lock, err := r.lock()
		if err != nil {
			return
		}
		defer lock.Close()
		state, err := r.load()
		if err != nil {
			return
		}
		for i := range state.Recovery {
			if state.Recovery[i].SessionID == id && state.Recovery[i].Status == "restoring" {
				state.Recovery[i].Status = "needs_attention"
				state.Recovery[i].Message = "Remote agent resume failed: " + result.Error()
				state.Recovery[i].UpdatedAt = now()
			}
		}
		_ = r.save(state)
	}()
	lock, err := r.lock()
	if err != nil {
		return err
	}
	state, err := r.load()
	lock.Close()
	if err != nil {
		return err
	}
	for _, launch := range state.AgentLaunches {
		if launch.SessionID == id && launch.ID == generation && launch.Lifecycle == "active" && validID.MatchString(launch.ProviderSessionID) {
			if !validDirectory(launch.Cwd) || !validDirectory(launch.ConfigurationRoot) {
				return errors.New("resume directory is missing")
			}
			if err := os.Chdir(launch.Cwd); err != nil {
				return err
			}
			_ = os.Setenv("TRANO_SESSION", id)
			args := []string{"--resume", launch.ProviderSessionID}
			if launch.Provider == "codex" {
				args = []string{"resume", launch.ProviderSessionID}
			}
			return r.RunAgent(launch.Provider, args, generation)
		}
	}
	return errors.New("no verified active agent mapping")
}
func toml(value any) string {
	switch v := value.(type) {
	case map[string]any:
		keys := []string{}
		for k := range v {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		parts := []string{}
		for _, k := range keys {
			parts = append(parts, strconv.Quote(k)+" = "+toml(v[k]))
		}
		return "{ " + strings.Join(parts, ", ") + " }"
	case []any:
		parts := []string{}
		for _, item := range v {
			parts = append(parts, toml(item))
		}
		return "[" + strings.Join(parts, ", ") + "]"
	default:
		data, _ := json.Marshal(value)
		return string(data)
	}
}
func (r *Runtime) withHooks(provider string, args []string) ([]string, error) {
	hooks := map[string]any{}
	events := []string{"SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "Stop", "SubagentStart", "SubagentStop"}
	if provider == "claude" {
		events = append(events, "PostToolUse", "PostToolUseFailure", "StopFailure")
	}
	for _, event := range events {
		hooks[event] = []any{map[string]any{"hooks": []any{map[string]any{"type": "command", "timeout": 3, "command": "[ -n \"$TRANO_LAUNCH_ID\" ] && \"$TRANO_REMOTE_HELPER\" hook " + provider + " || true"}}}}
	}
	if provider == "codex" {
		return append([]string{"--no-daemon", "-c", "hooks=" + toml(hooks)}, args...), nil
	}
	base := filepath.Join(r.root, "integration")
	plugin := filepath.Join(base, "claude")
	for _, dir := range []string{base, plugin, filepath.Join(plugin, ".claude-plugin"), filepath.Join(plugin, "hooks")} {
		if err := ownedDirectory(dir); err != nil {
			return nil, err
		}
	}
	if err := atomicWrite(filepath.Join(plugin, ".claude-plugin/plugin.json"), []byte("{\"name\":\"trano-remote-session\",\"version\":\"0.1.0\"}\n")); err != nil {
		return nil, err
	}
	data, _ := json.Marshal(map[string]any{"hooks": hooks})
	if err := atomicWrite(filepath.Join(plugin, "hooks/hooks.json"), data); err != nil {
		return nil, err
	}
	return append(args, "--plugin-dir", plugin), nil
}
