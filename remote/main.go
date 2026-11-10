package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const maxFrame = 1 << 20
const referenceEpoch int64 = 978307200

var validID = regexp.MustCompile(`^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$`)

type Activity struct {
	State     string  `json:"state"`
	Reason    string  `json:"reason"`
	Source    string  `json:"source"`
	UpdatedAt float64 `json:"updatedAt"`
}
type AgentTask struct {
	ID         string   `json:"id"`
	ParentID   string   `json:"parentID,omitempty"`
	Name       string   `json:"name"`
	Agent      string   `json:"agent"`
	Activity   Activity `json:"activity"`
	Generation string   `json:"generation,omitempty"`
}
type Session struct {
	ID         string      `json:"id"`
	Title      string      `json:"title"`
	Cwd        string      `json:"cwd"`
	PID        int         `json:"pid"`
	Host       string      `json:"host"`
	Agent      string      `json:"agent"`
	Activity   Activity    `json:"activity"`
	AgentTasks []AgentTask `json:"agentTasks,omitempty"`
	CreatedAt  float64     `json:"createdAt"`
	Alive      bool        `json:"alive"`
}
type State struct {
	SchemaVersion     int              `json:"schemaVersion"`
	Sessions          []Session        `json:"sessions"`
	AgentLaunches     []AgentLaunch    `json:"agentLaunches,omitempty"`
	Recovery          []RecoveryResult `json:"recovery,omitempty"`
	PersistScrollback *bool            `json:"persistScrollback,omitempty"`
}
type Request struct {
	APIVersion int                        `json:"apiVersion"`
	Method     string                     `json:"method"`
	Params     map[string]json.RawMessage `json:"params"`
}
type Response struct {
	APIVersion int    `json:"apiVersion"`
	Result     any    `json:"result,omitempty"`
	Error      string `json:"error,omitempty"`
}
type Runtime struct{ root, socket, tmux, helper string }

func NewRuntime(root string) (*Runtime, error) {
	root, err := filepath.Abs(root)
	if err != nil {
		return nil, err
	}
	if len(root) > 85 {
		return nil, errors.New("runtime path is too long for a Unix socket")
	}
	if info, err := os.Lstat(root); err == nil {
		owner, ok := info.Sys().(*syscall.Stat_t)
		if !info.IsDir() || !ok || owner.Uid != uint32(os.Getuid()) {
			return nil, errors.New("runtime must be an owned directory, not a symlink")
		}
		entries, err := os.ReadDir(root)
		if err != nil {
			return nil, err
		}
		if _, err := os.Stat(filepath.Join(root, ".trano")); err != nil && len(entries) != 0 {
			return nil, errors.New("refusing nonempty unmanaged runtime directory")
		}
	} else if !os.IsNotExist(err) {
		return nil, err
	}
	tmux, err := exec.LookPath("tmux")
	if err != nil {
		return nil, errors.New("tmux is required on this host")
	}
	if err := os.MkdirAll(root, 0700); err != nil {
		return nil, err
	}
	if err := os.Chmod(root, 0700); err != nil {
		return nil, err
	}
	if err := atomicWrite(filepath.Join(root, ".trano"), []byte("1\n")); err != nil {
		return nil, err
	}
	config := filepath.Join(root, "tmux.conf")
	if _, err := os.Stat(config); os.IsNotExist(err) {
		if err := atomicWrite(config, []byte("set -g status off\nset -g exit-empty on\nset -g history-limit 10000\nset -g default-terminal tmux-256color\nset -g remain-on-exit on\nset -g allow-passthrough on\nset -g set-clipboard off\nset -g prefix None\nunbind-key C-b\n")); err != nil {
			return nil, err
		}
	}
	return &Runtime{root: root, socket: filepath.Join(root, "mux.sock"), tmux: tmux}, nil
}
func atomicWrite(path string, data []byte) error {
	file, err := os.CreateTemp(filepath.Dir(path), ".write-")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	if err := file.Chmod(0600); err != nil {
		return err
	}
	if _, err := file.Write(data); err != nil {
		return err
	}
	if err := file.Sync(); err != nil {
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	return os.Rename(file.Name(), path)
}
func (r *Runtime) lock() (*os.File, error) {
	fd, err := syscall.Open(filepath.Join(r.root, "state.lock"), syscall.O_CREAT|syscall.O_RDWR|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0600)
	if err != nil {
		return nil, err
	}
	f := os.NewFile(uintptr(fd), "state.lock")
	if err := syscall.Flock(fd, syscall.LOCK_EX); err != nil {
		f.Close()
		return nil, err
	}
	return f, nil
}
func (r *Runtime) load() (State, error) {
	data, err := os.ReadFile(filepath.Join(r.root, "state.json"))
	if os.IsNotExist(err) {
		return State{SchemaVersion: 1, Sessions: []Session{}}, nil
	}
	if err != nil {
		return State{}, err
	}
	var s State
	if err := json.Unmarshal(data, &s); err != nil {
		return s, err
	}
	if s.SchemaVersion != 1 {
		return s, errors.New("unsupported state schema")
	}
	return s, nil
}
func (r *Runtime) save(s State) error {
	data, err := json.Marshal(s)
	if err != nil {
		return err
	}
	return atomicWrite(filepath.Join(r.root, "state.json"), append(data, '\n'))
}

type boundedOutput struct {
	bytes.Buffer
	overflow bool
	limit    int
}

func (b *boundedOutput) Write(p []byte) (int, error) {
	n := len(p)
	limit := b.limit
	if limit == 0 {
		limit = maxFrame
	}
	remaining := limit - b.Len()
	if len(p) > remaining {
		p = p[:remaining]
		b.overflow = true
	}
	_, _ = b.Buffer.Write(p)
	return n, nil
}
func environment() []string {
	result := []string{}
	for _, item := range os.Environ() {
		if !strings.HasPrefix(item, "TMUX=") {
			result = append(result, item)
		}
	}
	return append(result, "LC_MESSAGES=C")
}
func (r *Runtime) command(args ...string) (string, error) { return r.commandLimit(maxFrame, args...) }
func (r *Runtime) commandLimit(limit int, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	args = append([]string{"-u", "-S", r.socket, "-f", filepath.Join(r.root, "tmux.conf")}, args...)
	for i, value := range args {
		if strings.HasSuffix(value, ";") {
			args[i] = strings.TrimSuffix(value, ";") + "\\;"
		}
	}
	cmd := exec.CommandContext(ctx, r.tmux, args...)
	cmd.WaitDelay = 200 * time.Millisecond
	cmd.Env = environment()
	output := &boundedOutput{limit: limit}
	cmd.Stdout, cmd.Stderr = output, output
	err := cmd.Run()
	if ctx.Err() != nil {
		return "", ctx.Err()
	}
	if output.overflow {
		return "", fmt.Errorf("output exceeds %d bytes; request fewer lines", limit)
	}
	if err != nil {
		return output.String(), fmt.Errorf("tmux: %s: %w", strings.TrimSpace(output.String()), err)
	}
	return output.String(), nil
}
func now() float64 { return float64(time.Now().UnixNano())/1e9 - float64(referenceEpoch) }
func uuid() (string, error) {
	data := make([]byte, 16)
	if _, err := rand.Read(data); err != nil {
		return "", err
	}
	data[6] = (data[6] & 0x0f) | 0x40
	data[8] = (data[8] & 0x3f) | 0x80
	text := hex.EncodeToString(data)
	return text[:8] + "-" + text[8:12] + "-" + text[12:16] + "-" + text[16:20] + "-" + text[20:], nil
}
func (r *Runtime) Create(title, cwd string) (Session, error) {
	file, err := r.lock()
	if err != nil {
		return Session{}, err
	}
	defer file.Close()
	if cwd == "" {
		cwd, err = os.UserHomeDir()
		if err != nil {
			return Session{}, err
		}
	}
	cwd, err = filepath.Abs(cwd)
	if err != nil {
		return Session{}, err
	}
	info, err := os.Stat(cwd)
	if err != nil || !info.IsDir() || len(title) > 800 || strings.ContainsRune(title, 0) || strings.ContainsAny(cwd, "\r\n") {
		return Session{}, errors.New("invalid title or working directory")
	}
	s, err := r.load()
	if err != nil {
		return Session{}, err
	}
	id, err := uuid()
	if err != nil {
		return Session{}, err
	}
	pid, err := r.spawnShell(id, cwd)
	if err != nil {
		return Session{}, err
	}
	if title == "" {
		title = "Remote Terminal"
	}
	item := Session{ID: id, Title: title, Cwd: cwd, PID: pid, Host: "remote", Agent: "shell", Activity: Activity{State: "unknown", Source: "unknown", UpdatedAt: now()}, CreatedAt: now(), Alive: true}
	s.Sessions = append(s.Sessions, item)
	if err := r.save(s); err != nil {
		_, _ = r.command("kill-session", "-t", "="+id)
		return Session{}, err
	}
	if err := r.monitor(id); err != nil {
		_, _ = r.command("kill-session", "-t", "="+id)
		s.Sessions = s.Sessions[:len(s.Sessions)-1]
		_ = r.save(s)
		return Session{}, err
	}
	return item, nil
}
func require(s State, id string) error {
	if !validID.MatchString(id) {
		return errors.New("invalid session ID")
	}
	for _, item := range s.Sessions {
		if item.ID == id {
			return nil
		}
	}
	return errors.New("unknown session")
}
func (r *Runtime) List() ([]Session, error) {
	file, err := r.lock()
	if err != nil {
		return nil, err
	}
	defer file.Close()
	s, err := r.load()
	if err != nil {
		return nil, err
	}
	output, err := r.command("list-panes", "-a", "-F", "#{session_name}|#{pane_dead}|#{pane_pid}|#{pane_current_path}")
	if err != nil && !missingServer(output) {
		return nil, err
	}
	alive := map[string]bool{}
	pids := map[string]int{}
	directories := map[string]string{}
	for _, line := range strings.Split(output, "\n") {
		fields := strings.SplitN(line, "|", 4)
		if len(fields) == 4 {
			alive[fields[0]] = fields[1] == "0"
			pids[fields[0]], _ = strconv.Atoi(fields[2])
			directories[fields[0]] = fields[3]
		}
	}
	changed := false
	for i := range s.Sessions {
		before := s.Sessions[i]
		s.Sessions[i].Alive = alive[s.Sessions[i].ID]
		if pid := pids[s.Sessions[i].ID]; pid > 0 {
			s.Sessions[i].PID = pid
		}
		if cwd := directories[s.Sessions[i].ID]; cwd != "" {
			s.Sessions[i].Cwd = cwd
		}
		if before.Alive != s.Sessions[i].Alive || before.PID != s.Sessions[i].PID || before.Cwd != s.Sessions[i].Cwd {
			changed = true
		}
	}
	if changed {
		if err := r.save(s); err != nil {
			return nil, err
		}
	}
	return s.Sessions, nil
}
func (r *Runtime) Capture(id string, lines int) (string, error) {
	file, err := r.lock()
	if err != nil {
		return "", err
	}
	defer file.Close()
	s, err := r.load()
	if err != nil {
		return "", err
	}
	if err := require(s, id); err != nil {
		return "", err
	}
	if lines < 1 || lines > 10000 {
		return "", errors.New("lines must be 1...10000")
	}
	return r.command("capture-pane", "-p", "-t", id+":0.0", "-S", "-"+strconv.Itoa(lines))
}
func (r *Runtime) Send(id, text string, enter bool) error {
	file, err := r.lock()
	if err != nil {
		return err
	}
	defer file.Close()
	s, err := r.load()
	if err != nil {
		return err
	}
	if err := require(s, id); err != nil {
		return err
	}
	if len(text) > 65536 || strings.ContainsRune(text, 0) {
		return errors.New("input exceeds 64 KiB or contains NUL")
	}
	if _, err := r.command("send-keys", "-t", id+":0.0", "-l", "--", text); err != nil {
		return err
	}
	if enter {
		_, err = r.command("send-keys", "-t", id+":0.0", "Enter")
	}
	return err
}
func (r *Runtime) Terminate(id string) error {
	file, err := r.lock()
	if err != nil {
		return err
	}
	defer file.Close()
	s, err := r.load()
	if err != nil {
		return err
	}
	if err := require(s, id); err != nil {
		return err
	}
	_, _ = r.command("kill-session", "-t", "="+id)
	remaining, err := r.command("list-sessions", "-F", "#{session_name}")
	if err != nil && !missingServer(remaining) {
		return err
	}
	for _, name := range strings.Split(remaining, "\n") {
		if name == id {
			return errors.New("session did not terminate")
		}
	}
	sessions := []Session{}
	for _, item := range s.Sessions {
		if item.ID != id {
			sessions = append(sessions, item)
		}
	}
	s.Sessions = sessions
	launches := s.AgentLaunches[:0]
	for _, launch := range s.AgentLaunches {
		if launch.SessionID != id {
			launches = append(launches, launch)
		}
	}
	s.AgentLaunches = launches
	results := s.Recovery[:0]
	for _, result := range s.Recovery {
		if result.SessionID != id {
			results = append(results, result)
		}
	}
	s.Recovery = results
	if dir, err := r.snapshotDirectory(false); err == nil && dir != "" {
		_ = os.Remove(filepath.Join(dir, id+".snapshot"))
	}
	return r.save(s)
}

func missingServer(message string) bool {
	return strings.Contains(message, "no server running") || strings.Contains(message, "server exited unexpectedly") || strings.Contains(message, "server is shutting down") ||
		(strings.Contains(message, "error connecting to") && (strings.Contains(message, "No such file or directory") || strings.Contains(message, "Connection refused")))
}
func (r *Runtime) Route(request Request) Response {
	result, err := r.route(request)
	if err != nil {
		return Response{APIVersion: 1, Error: err.Error()}
	}
	return Response{APIVersion: 1, Result: result}
}
func (r *Runtime) route(request Request) (any, error) {
	if request.APIVersion != 1 {
		return nil, errors.New("unsupported API version")
	}
	var title, cwd, id, text, state, agent, reason, path string
	var enter bool
	lines := 100
	for key, destination := range map[string]any{"title": &title, "cwd": &cwd, "id": &id, "text": &text, "enter": &enter, "lines": &lines, "state": &state, "agent": &agent, "reason": &reason, "path": &path} {
		if raw, ok := request.Params[key]; ok {
			if err := json.Unmarshal(raw, destination); err != nil {
				return nil, fmt.Errorf("invalid parameter %s", key)
			}
		}
	}
	switch request.Method {
	case "scrollback.settings":
		var enabled bool
		if err := json.Unmarshal(request.Params["enabled"], &enabled); err != nil {
			return nil, errors.New("enabled must be a boolean")
		}
		return map[string]bool{"enabled": enabled}, r.SetScrollback(enabled)
	case "scrollback.metadata":
		return r.ScrollbackMetadata(id)
	case "recovery.run":
		return r.Recover(id)
	case "recovery.list":
		return r.RecoveryResults()
	case "paths.list":
		return r.ListPaths(path)
	case "health", "server.info":
		return map[string]any{"apiVersion": 1, "version": "0.1.0-dev", "transport": "ssh", "persistent": true}, nil
	case "list", "sessions.list":
		return r.List()
	case "new", "sessions.create":
		return r.Create(title, cwd)
	case "capture", "panes.capture":
		value, err := r.Capture(id, lines)
		return map[string]string{"text": value}, err
	case "send", "panes.send":
		return map[string]bool{"sent": true}, r.Send(id, text, enter)
	case "terminate", "sessions.terminate":
		return map[string]bool{"terminated": true}, r.Terminate(id)
	case "activity.report":
		if agent == "" {
			agent = "shell"
		}
		return map[string]bool{"reported": true}, r.Report(id, activityReport{state: state, agent: agent, reason: reason}, "explicit")
	default:
		return nil, errors.New("unknown API method")
	}
}
func run() error {
	root := os.Getenv("TRANO_REMOTE_ROOT")
	if root == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return err
		}
		root = filepath.Join(home, ".local/share/trano-remote")
	}
	if len(os.Args) < 2 || os.Args[1] == "--help" {
		fmt.Println("trano-server rpc | attach ID | --check\nRemote sessions survive disconnect. TRANO_REMOTE_ROOT overrides the private runtime directory.")
		return nil
	}
	runtime, err := NewRuntime(root)
	if err != nil {
		return err
	}
	runtime.helper, err = os.Executable()
	if err != nil {
		return err
	}
	switch os.Args[1] {
	case "agent-exec":
		return executeGatedProvider()
	case "agent":
		if len(os.Args) < 3 {
			return errors.New("agent requires provider")
		}
		return runtime.RunAgent(os.Args[2], os.Args[3:], "")
	case "resume":
		if len(os.Args) != 4 {
			return errors.New("resume requires session and generation")
		}
		return runtime.ResumeAgent(os.Args[2], os.Args[3])
	case "hook":
		if len(os.Args) != 3 {
			return errors.New("hook requires provider")
		}
		data, err := io.ReadAll(io.LimitReader(os.Stdin, maxFrame+1))
		if err != nil {
			return err
		}
		return runtime.RecordHook(os.Args[2], os.Getenv("TRANO_SESSION"), os.Getenv("TRANO_LAUNCH_ID"), data, os.Getppid())
	case "cwd":
		if len(os.Args) != 4 {
			return errors.New("cwd requires session and path")
		}
		return runtime.RecordDirectory(os.Args[2], os.Args[3])
	case "upload":
		if len(os.Args) != 3 || !validID.MatchString(os.Args[2]) {
			return errors.New("upload requires ID")
		}
		path, err := runtime.UploadPNG(os.Args[2], os.Stdin)
		if err != nil {
			return err
		}
		return json.NewEncoder(os.Stdout).Encode(Response{APIVersion: 1, Result: map[string]string{"path": path}})
	case "monitor":
		if len(os.Args) < 3 || len(os.Args) > 4 || !validID.MatchString(os.Args[2]) {
			return errors.New("monitor requires ID and optional PID")
		}
		pid := 0
		if len(os.Args) == 4 {
			pid, err = strconv.Atoi(os.Args[3])
			if err != nil || pid <= 0 {
				return errors.New("invalid monitor PID")
			}
		}
		return runtime.Monitor(os.Args[2], os.Stdin, pid)
	case "replay":
		if len(os.Args) != 3 {
			return errors.New("replay requires ID")
		}
		text, err := runtime.ReplayScrollback(os.Args[2])
		if err != nil {
			return err
		}
		_, err = io.WriteString(os.Stdout, text)
		return err
	case "rpc":
		scanner := bufio.NewScanner(io.LimitReader(os.Stdin, maxFrame+1))
		scanner.Buffer(make([]byte, 4096), maxFrame)
		if !scanner.Scan() {
			return errors.New("missing or oversized RPC request")
		}
		var request Request
		if err := json.Unmarshal(scanner.Bytes(), &request); err != nil {
			return errors.New("invalid RPC JSON")
		}
		return json.NewEncoder(os.Stdout).Encode(runtime.Route(request))
	case "--check":
		return json.NewEncoder(os.Stdout).Encode(runtime.Route(Request{APIVersion: 1, Method: "health"}))
	case "attach":
		if len(os.Args) != 3 {
			return errors.New("attach requires ID")
		}
		file, err := runtime.lock()
		if err != nil {
			return err
		}
		s, err := runtime.load()
		if err == nil {
			err = require(s, os.Args[2])
		}
		file.Close()
		if err != nil {
			return err
		}
		return syscall.Exec(runtime.tmux, []string{runtime.tmux, "-u", "-S", runtime.socket, "attach-session", "-t", "=" + os.Args[2]}, environment())
	default:
		return errors.New("unknown command")
	}
}
func main() {
	if err := run(); err != nil {
		_ = json.NewEncoder(os.Stderr).Encode(Response{APIVersion: 1, Error: err.Error()})
		os.Exit(1)
	}
}
