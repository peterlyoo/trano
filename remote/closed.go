package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
)

const closedTerminalMarker = "trano-closed-terminals-v1\n"
const closedTerminalBytes = 8 * 1024 * 1024

type ClosedTerminalResult struct {
	CloseProtocol     int      `json:"closeProtocol"`
	OperationID       string   `json:"operationID"`
	SessionID         string   `json:"sessionID"`
	ExpectedPID       int      `json:"expectedPID"`
	Generation        string   `json:"generation"`
	Phase             string   `json:"phase"`
	HistoryProvenance string   `json:"historyProvenance"`
	Session           *Session `json:"session,omitempty"`
}

type closedTerminalSnapshot struct {
	ClosedTerminalResult
	Original            Session                `json:"original"`
	Shell               string                 `json:"shell"`
	Display             string                 `json:"display"`
	History             []byte                 `json:"history,omitempty"`
	Launch              *AgentLaunch           `json:"launch,omitempty"`
	Witnesses           []closedProcessWitness `json:"witnesses"`
	CreatedAt           float64                `json:"createdAt"`
	RestoredGeneration  string                 `json:"restoredGeneration,omitempty"`
	ResumeState         string                 `json:"resumeState,omitempty"`
	StartupAcknowledged bool                   `json:"startupAcknowledged,omitempty"`
}

func (r *Runtime) closedDirectory(create bool) (string, error) {
	dir := filepath.Join(r.root, "closed-terminals")
	info, err := os.Lstat(dir)
	if os.IsNotExist(err) && !create {
		return "", os.ErrNotExist
	}
	if err != nil && !os.IsNotExist(err) {
		return "", err
	}
	if info != nil {
		owner, ok := info.Sys().(*syscall.Stat_t)
		if !info.IsDir() || !ok || owner.Uid != uint32(os.Getuid()) || info.Mode().Perm()&0077 != 0 {
			return "", errors.New("closed terminal storage must be a private owned directory")
		}
	} else if err := os.Mkdir(dir, 0700); err != nil {
		return "", err
	}
	marker := filepath.Join(dir, ".trano-closed-terminals")
	data, err := readClosedFile(marker, int64(len(closedTerminalMarker)))
	if os.IsNotExist(err) && create {
		entries, err := os.ReadDir(dir)
		if err != nil {
			return "", err
		}
		if len(entries) != 0 {
			return "", errors.New("refusing unmanaged closed terminal storage")
		}
		if err := writeClosedFile(marker, []byte(closedTerminalMarker)); err != nil {
			return "", err
		}
	} else if err != nil {
		return "", err
	} else if string(data) != closedTerminalMarker {
		return "", errors.New("invalid closed terminal ownership marker")
	}
	return dir, nil
}

func readClosedFile(path string, limit int64) ([]byte, error) {
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
	if !info.Mode().IsRegular() || !ok || owner.Uid != uint32(os.Getuid()) || owner.Nlink != 1 || info.Mode().Perm()&0077 != 0 || info.Size() > limit {
		return nil, errors.New("invalid private closed terminal file")
	}
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err == nil && int64(len(data)) > limit {
		err = errors.New("closed terminal file exceeds its bound")
	}
	return data, err
}

func writeClosedFile(path string, data []byte) error {
	if info, err := os.Lstat(path); err == nil {
		owner, ok := info.Sys().(*syscall.Stat_t)
		if !info.Mode().IsRegular() || !ok || owner.Uid != uint32(os.Getuid()) || owner.Nlink != 1 || info.Mode().Perm()&0077 != 0 {
			return errors.New("refusing unowned closed terminal file")
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	if err := atomicWrite(path, data); err != nil {
		return err
	}
	dir, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

func (r *Runtime) readClosedTerminal(operationID string) (closedTerminalSnapshot, error) {
	var snapshot closedTerminalSnapshot
	if !validID.MatchString(operationID) {
		return snapshot, errors.New("invalid close operation ID")
	}
	dir, err := r.closedDirectory(false)
	if err != nil {
		return snapshot, err
	}
	data, err := readClosedFile(filepath.Join(dir, operationID+".json"), closedTerminalBytes)
	if err != nil {
		return snapshot, err
	}
	if err := json.Unmarshal(data, &snapshot); err != nil {
		return snapshot, errors.New("invalid closed terminal snapshot")
	}
	if snapshot.CloseProtocol != 1 || snapshot.OperationID != operationID || !validID.MatchString(snapshot.SessionID) || snapshot.Original.ID != snapshot.SessionID || snapshot.ExpectedPID < 1 || snapshot.Original.PID != snapshot.ExpectedPID || snapshot.Generation == "" || len(snapshot.Generation) > 256 || !closedShellPath(snapshot.Shell) || len(snapshot.Display) > snapshotBytes || len(snapshot.History) > closedHistoryBytes || len(snapshot.Witnesses) > 1024 {
		return snapshot, errors.New("invalid closed terminal snapshot identity")
	}
	switch snapshot.Phase {
	case "prepared", "committing", "closed", "reopening", "reopened":
	default:
		return snapshot, errors.New("invalid closed terminal phase")
	}
	return snapshot, nil
}

func (r *Runtime) writeClosedTerminal(snapshot closedTerminalSnapshot) error {
	dir, err := r.closedDirectory(true)
	if err != nil {
		return err
	}
	data, err := json.Marshal(snapshot)
	if err != nil {
		return err
	}
	if len(data) > closedTerminalBytes {
		return errors.New("closed terminal snapshot exceeds its bound")
	}
	return writeClosedFile(filepath.Join(dir, snapshot.OperationID+".json"), append(data, '\n'))
}

func (r *Runtime) intentionalClosedTerminals() (map[string]string, error) {
	dir, err := r.closedDirectory(false)
	if os.IsNotExist(err) {
		return map[string]string{}, nil
	}
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	closed := map[string]string{}
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		id := strings.TrimSuffix(entry.Name(), ".json")
		if !validID.MatchString(id) {
			return nil, errors.New("invalid closed terminal storage entry")
		}
		snapshot, err := r.readClosedTerminal(id)
		if err != nil {
			return nil, err
		}
		if snapshot.Phase == "committing" || snapshot.Phase == "closed" || snapshot.Phase == "reopening" {
			closed[snapshot.SessionID] = snapshot.OperationID
		}
	}
	return closed, nil
}

func (r *Runtime) routeClosedTerminal(request Request) (ClosedTerminalResult, error) {
	var id, operationID, generation string
	var pid int
	for key, raw := range request.Params {
		var target any
		switch key {
		case "id":
			target = &id
		case "operationID":
			target = &operationID
		case "expectedPID":
			target = &pid
		case "expectedGeneration":
			target = &generation
		default:
			return ClosedTerminalResult{}, errors.New("unknown close parameter")
		}
		if err := json.Unmarshal(raw, target); err != nil {
			return ClosedTerminalResult{}, errors.New("invalid close parameter")
		}
	}
	if !validID.MatchString(id) || !validID.MatchString(operationID) || pid < 0 || len(generation) > 256 {
		return ClosedTerminalResult{}, errors.New("invalid close operation identity")
	}
	if request.Method == "close.cancel" && (pid < 1 || generation == "") {
		return ClosedTerminalResult{}, errors.New("close cancellation requires the prepared process token")
	}
	lock, err := r.lock()
	if err != nil {
		return ClosedTerminalResult{}, err
	}
	defer lock.Close()
	snapshot, err := r.readClosedTerminal(operationID)
	if os.IsNotExist(err) && request.Method == "close.prepare" {
		return r.prepareClosedTerminal(id, operationID, pid, generation)
	}
	if os.IsNotExist(err) && request.Method == "close.cancel" {
		return ClosedTerminalResult{CloseProtocol: 1, OperationID: operationID, SessionID: id, ExpectedPID: pid, Generation: generation, Phase: "cancelled", HistoryProvenance: "unavailable"}, nil
	}
	if err != nil {
		return ClosedTerminalResult{}, err
	}
	if snapshot.SessionID != id || pid != 0 && snapshot.ExpectedPID != pid || generation != "" && snapshot.Generation != generation {
		return ClosedTerminalResult{}, errors.New("close operation belongs to another terminal generation")
	}
	switch request.Method {
	case "close.cancel":
		if snapshot.Phase != "prepared" {
			return ClosedTerminalResult{}, errors.New("cannot cancel a remote close after commit has begun")
		}
		dir, err := r.closedDirectory(false)
		if err != nil {
			return ClosedTerminalResult{}, err
		}
		if err := os.Remove(filepath.Join(dir, operationID+".json")); err != nil {
			return ClosedTerminalResult{}, err
		}
		file, err := os.Open(dir)
		if err != nil {
			return ClosedTerminalResult{}, err
		}
		err = file.Sync()
		file.Close()
		if err != nil {
			return ClosedTerminalResult{}, err
		}
		snapshot.Phase = "cancelled"
		return snapshot.ClosedTerminalResult, nil
	case "close.prepare":
		return snapshot.ClosedTerminalResult, nil
	case "close.commit":
		return r.commitClosedTerminal(snapshot)
	case "close.reopen":
		return r.reopenClosedTerminal(snapshot)
	case "close.status":
		if snapshot.Phase == "committing" {
			_, observeErr := r.closedController().Observe(r, id)
			if errors.Is(observeErr, errClosedProcessMissing) && r.closedController().CheckStopped(snapshot.Witnesses) == nil {
				snapshot.Phase = "closed"
				if err := r.writeClosedTerminal(snapshot); err != nil {
					return ClosedTerminalResult{}, err
				}
			}
		}
		return snapshot.ClosedTerminalResult, nil
	}
	return ClosedTerminalResult{}, errors.New("invalid close method")
}

func (r *Runtime) prepareClosedTerminal(id, operationID string, expectedPID int, expectedGeneration string) (ClosedTerminalResult, error) {
	if expectedPID < 1 || expectedGeneration == "" {
		return ClosedTerminalResult{}, errors.New("close preparation requires a verified remote process generation")
	}
	if _, err := r.closedDirectory(true); err != nil {
		return ClosedTerminalResult{}, err
	}
	if err := r.ensureClosedTerminalCapacity(256); err != nil {
		return ClosedTerminalResult{}, err
	}
	closed, err := r.intentionalClosedTerminals()
	if err != nil {
		return ClosedTerminalResult{}, err
	}
	if closed[id] != "" {
		return ClosedTerminalResult{}, errors.New("terminal already has an unfinished close operation")
	}
	state, err := r.load()
	if err != nil {
		return ClosedTerminalResult{}, err
	}
	var original *Session
	for _, pane := range state.Sessions {
		if pane.ID == id {
			copy := pane
			original = &copy
			break
		}
	}
	if original == nil {
		return ClosedTerminalResult{}, errors.New("unknown close terminal")
	}
	process, err := r.closedController().Observe(r, id)
	if err != nil {
		return ClosedTerminalResult{}, err
	}
	if process.PID != expectedPID || process.Generation != expectedGeneration || !validDirectory(process.Cwd) || !closedShellPath(process.Shell) {
		return ClosedTerminalResult{}, errors.New("terminal generation or original shell changed before close")
	}
	original.PID, original.Cwd = process.PID, process.Cwd
	snapshot := closedTerminalSnapshot{ClosedTerminalResult: ClosedTerminalResult{CloseProtocol: 1, OperationID: operationID, SessionID: id, ExpectedPID: process.PID, Generation: process.Generation, Phase: "prepared"}, Original: *original, Shell: process.Shell, Witnesses: process.Witnesses, CreatedAt: now()}
	for _, launch := range state.AgentLaunches {
		if launch.SessionID == id && launch.Lifecycle == "active" {
			if snapshot.Launch != nil {
				return ClosedTerminalResult{}, errors.New("multiple active remote agent generations")
			}
			copy := launch
			snapshot.Launch = &copy
		}
	}
	display, err := r.commandLimit(snapshotBytes, "capture-pane", "-p", "-t", id+":0.0", "-S", "-10000")
	if err != nil {
		return ClosedTerminalResult{}, errors.New("could not capture terminal display; terminal remains running")
	}
	snapshot.Display = sanitizeSnapshot(display)
	snapshot.History, snapshot.HistoryProvenance, err = r.captureClosedHistory(id, process)
	if err != nil {
		return ClosedTerminalResult{}, err
	}
	current, err := r.closedController().Observe(r, id)
	if err != nil || current.PID != process.PID || current.Generation != process.Generation || current.Cwd != process.Cwd || !sameClosedRootWitness(process.Witnesses, current.Witnesses, process.PID) {
		return ClosedTerminalResult{}, errors.New("terminal changed during close capture")
	}
	if err := r.writeClosedTerminal(snapshot); err != nil {
		return ClosedTerminalResult{}, err
	}
	return snapshot.ClosedTerminalResult, nil
}

func sameClosedLaunch(saved *AgentLaunch, state State, id string) bool {
	var current *AgentLaunch
	for _, launch := range state.AgentLaunches {
		if launch.SessionID == id && launch.Lifecycle == "active" {
			if current != nil {
				return false
			}
			copy := launch
			current = &copy
		}
	}
	if saved == nil || current == nil {
		return saved == nil && current == nil
	}
	return saved.ID == current.ID && saved.Provider == current.Provider && saved.ProviderSessionID == current.ProviderSessionID && saved.ConfigurationRoot == current.ConfigurationRoot && saved.Cwd == current.Cwd && saved.ProcessID == current.ProcessID && saved.ProviderPID == current.ProviderPID
}

func (r *Runtime) commitClosedTerminal(snapshot closedTerminalSnapshot) (ClosedTerminalResult, error) {
	if snapshot.Phase == "closed" || snapshot.Phase == "reopening" || snapshot.Phase == "reopened" {
		return snapshot.ClosedTerminalResult, nil
	}
	closed, err := r.intentionalClosedTerminals()
	if err != nil {
		return ClosedTerminalResult{}, err
	}
	if operation := closed[snapshot.SessionID]; operation != "" && operation != snapshot.OperationID {
		return ClosedTerminalResult{}, errors.New("another close operation owns this terminal")
	}
	state, err := r.load()
	if err != nil {
		return ClosedTerminalResult{}, err
	}
	process, observeErr := r.closedController().Observe(r, snapshot.SessionID)
	if observeErr != nil && !errors.Is(observeErr, errClosedProcessMissing) {
		return ClosedTerminalResult{}, observeErr
	}
	if observeErr == nil && (process.PID != snapshot.ExpectedPID || process.Generation != snapshot.Generation || process.Cwd != snapshot.Original.Cwd || !sameClosedRootWitness(snapshot.Witnesses, process.Witnesses, snapshot.ExpectedPID)) {
		return ClosedTerminalResult{}, errors.New("terminal generation changed after close capture")
	}
	if snapshot.Phase == "prepared" && !sameClosedLaunch(snapshot.Launch, state, snapshot.SessionID) {
		return ClosedTerminalResult{}, errors.New("agent conversation changed after close capture")
	}
	if observeErr == nil {
		seen := map[closedProcessWitness]bool{}
		for _, witness := range snapshot.Witnesses {
			seen[witness] = true
		}
		for _, witness := range process.Witnesses {
			if !seen[witness] {
				snapshot.Witnesses = append(snapshot.Witnesses, witness)
				seen[witness] = true
			}
		}
		if len(snapshot.Witnesses) > 1024 {
			return ClosedTerminalResult{}, errors.New("remote terminal process tree exceeds the safe close bound")
		}
	}
	snapshot.Phase = "committing"
	if err := r.writeClosedTerminal(snapshot); err != nil {
		return ClosedTerminalResult{}, err
	}
	for i := range state.Sessions {
		if state.Sessions[i].ID == snapshot.SessionID {
			state.Sessions[i].Alive = false
		}
	}
	for i := range state.AgentLaunches {
		if state.AgentLaunches[i].SessionID == snapshot.SessionID {
			state.AgentLaunches[i].Lifecycle = "closed"
		}
	}
	if err := r.save(state); err != nil {
		return ClosedTerminalResult{}, err
	}
	_, _ = r.command("kill-session", "-t", "="+snapshot.SessionID)
	if err := r.closedController().Stop(snapshot.Witnesses); err != nil {
		return ClosedTerminalResult{}, err
	}
	_, err = r.closedController().Observe(r, snapshot.SessionID)
	if !errors.Is(err, errClosedProcessMissing) {
		if err != nil {
			return ClosedTerminalResult{}, err
		}
		return ClosedTerminalResult{}, errors.New("remote terminal did not stop")
	}
	if err := r.closedController().CheckStopped(snapshot.Witnesses); err != nil {
		return ClosedTerminalResult{}, err
	}
	snapshot.Phase = "closed"
	if err := r.writeClosedTerminal(snapshot); err != nil {
		return ClosedTerminalResult{}, err
	}
	return snapshot.ClosedTerminalResult, nil
}

func (r *Runtime) reopenClosedTerminal(snapshot closedTerminalSnapshot) (ClosedTerminalResult, error) {
	if snapshot.Phase != "closed" && snapshot.Phase != "reopening" && snapshot.Phase != "reopened" {
		return ClosedTerminalResult{}, errors.New("terminal close must finish before reopening")
	}
	if err := r.closedController().CheckStopped(snapshot.Witnesses); err != nil {
		return ClosedTerminalResult{}, err
	}
	process, observeErr := r.closedController().Observe(r, snapshot.SessionID)
	if observeErr != nil && !errors.Is(observeErr, errClosedProcessMissing) {
		return ClosedTerminalResult{}, observeErr
	}
	if snapshot.Phase == "reopened" {
		if observeErr != nil || snapshot.Session == nil || snapshot.Session.PID != process.PID || snapshot.RestoredGeneration != process.Generation {
			return ClosedTerminalResult{}, errors.New("reopened terminal changed; use terminal recovery instead of repeating reopen")
		}
		return snapshot.ClosedTerminalResult, nil
	}
	if observeErr == nil && (snapshot.Phase != "reopening" || process.OperationID != snapshot.OperationID) {
		return ClosedTerminalResult{}, errors.New("another live process owns the closed terminal ID")
	}
	if !validDirectory(snapshot.Original.Cwd) {
		return ClosedTerminalResult{}, errors.New("original remote working directory is missing")
	}
	if info, err := os.Stat(snapshot.Shell); err != nil || info.IsDir() || info.Mode()&0111 == 0 {
		return ClosedTerminalResult{}, errors.New("original remote shell is unavailable")
	}
	state, err := r.load()
	if err != nil {
		return ClosedTerminalResult{}, err
	}
	if snapshot.Phase == "closed" {
		snapshot.Phase = "reopening"
		if err := r.writeClosedTerminal(snapshot); err != nil {
			return ClosedTerminalResult{}, err
		}
	}
	if errors.Is(observeErr, errClosedProcessMissing) {
		if err := r.prepareClosedHistoryImport(snapshot); err != nil {
			return ClosedTerminalResult{}, err
		}
		if _, err := r.spawnClosedShell(snapshot); err != nil {
			return ClosedTerminalResult{}, err
		}
		process, err = r.closedController().Observe(r, snapshot.SessionID)
		if err != nil {
			return ClosedTerminalResult{}, err
		}
	}
	if err := r.monitor(snapshot.SessionID); err != nil {
		return ClosedTerminalResult{}, err
	}
	pane := snapshot.Original
	pane.PID, pane.Alive, pane.AgentTasks, pane.Cwd = process.PID, true, nil, snapshot.Original.Cwd
	pane.Agent, pane.Activity = "shell", Activity{State: "idle", Source: "closed-terminal", UpdatedAt: now()}
	pane.ShellInputIdentity, pane.InputBackendIdentity, pane.ForegroundProgram = nil, nil, ""
	found := false
	for i := range state.Sessions {
		if state.Sessions[i].ID == pane.ID {
			state.Sessions[i], found = pane, true
		}
	}
	if !found {
		state.Sessions = append(state.Sessions, pane)
	}
	launches := []AgentLaunch{}
	for _, launch := range state.AgentLaunches {
		if launch.SessionID != pane.ID {
			launches = append(launches, launch)
		}
	}
	result := RecoveryResult{SessionID: pane.ID, Status: "restored", Message: "Closed terminal reopened in a fresh shell", UpdatedAt: now()}
	snapshot.ResumeState = "none"
	if snapshot.Launch != nil {
		launch := *snapshot.Launch
		launch.ProcessID, launch.ProviderPID, launch.StartedSessionID = 0, 0, ""
		if validID.MatchString(launch.ProviderSessionID) && (launch.Provider == "claude" || launch.Provider == "codex") && validDirectory(launch.Cwd) && validDirectory(launch.ConfigurationRoot) && r.helper != "" && !closedConversationActiveElsewhere(launch, state) {
			launch.Lifecycle, snapshot.ResumeState = "active", "pending"
			result.Status, result.Message = "restoring", "Resuming the saved remote agent conversation"
		} else {
			launch.Lifecycle, snapshot.ResumeState = "closed", "unavailable"
			result.Status, result.Message = "needs_attention", "Shell reopened; the saved agent needs its exact conversation and original configuration directory before it can resume"
		}
		launches = append(launches, launch)
	}
	state.AgentLaunches = launches
	results := []RecoveryResult{}
	for _, previous := range state.Recovery {
		if previous.SessionID != pane.ID {
			results = append(results, previous)
		}
	}
	state.Recovery = append(results, result)
	if err := r.save(state); err != nil {
		return ClosedTerminalResult{}, err
	}
	snapshot.Phase, snapshot.Session, snapshot.RestoredGeneration = "reopened", &pane, process.Generation
	if err := r.writeClosedTerminal(snapshot); err != nil {
		return ClosedTerminalResult{}, err
	}
	return snapshot.ClosedTerminalResult, nil
}

func (r *Runtime) ReplayClosedTerminal(operationID string) (string, error) {
	lock, err := r.lock()
	if err != nil {
		return "", err
	}
	defer lock.Close()
	snapshot, err := r.readClosedTerminal(operationID)
	if err != nil {
		return "", err
	}
	if snapshot.Phase != "reopening" && snapshot.Phase != "reopened" {
		return "", errors.New("closed terminal is not reopening")
	}
	process, err := r.closedController().Observe(r, snapshot.SessionID)
	if err != nil || process.OperationID != operationID || process.PID != os.Getppid() {
		return "", errors.New("closed display belongs to another process")
	}
	return sanitizeSnapshot(snapshot.Display), nil
}

func (r *Runtime) StartClosedTerminal(operationID string) error {
	lock, err := r.lock()
	if err != nil {
		return err
	}
	snapshot, err := r.readClosedTerminal(operationID)
	if err != nil {
		lock.Close()
		return err
	}
	process, err := r.closedController().Observe(r, snapshot.SessionID)
	if err == nil && snapshot.Phase == "reopening" && process.PID == os.Getppid() && process.OperationID == operationID {
		if _, err := r.reopenClosedTerminal(snapshot); err != nil {
			lock.Close()
			return err
		}
		snapshot, err = r.readClosedTerminal(operationID)
		if err != nil {
			lock.Close()
			return err
		}
	}
	if err != nil || snapshot.Phase != "reopened" || snapshot.Session == nil || snapshot.Session.PID != process.PID || snapshot.RestoredGeneration != process.Generation || process.PID != os.Getppid() || process.OperationID != operationID {
		lock.Close()
		return errors.New("closed agent startup belongs to another process")
	}
	if snapshot.ResumeState != "pending" || snapshot.Launch == nil {
		if !snapshot.StartupAcknowledged {
			snapshot.StartupAcknowledged = true
			err = r.writeClosedTerminal(snapshot)
		}
		lock.Close()
		return err
	}
	state, err := r.load()
	if err != nil {
		lock.Close()
		return err
	}
	if closedConversationActiveElsewhere(*snapshot.Launch, state) {
		snapshot.ResumeState, snapshot.StartupAcknowledged = "unavailable", true
		for index := range state.AgentLaunches {
			if state.AgentLaunches[index].SessionID == snapshot.SessionID {
				state.AgentLaunches[index].Lifecycle = "closed"
			}
		}
		for index := range state.Recovery {
			if state.Recovery[index].SessionID == snapshot.SessionID {
				state.Recovery[index].Status = "needs_attention"
				state.Recovery[index].Message = "The saved conversation is already active in another remote terminal"
			}
		}
		if err := r.save(state); err != nil {
			lock.Close()
			return err
		}
		err := r.writeClosedTerminal(snapshot)
		lock.Close()
		return err
	}
	snapshot.ResumeState, snapshot.StartupAcknowledged = "claimed", true
	if err := r.writeClosedTerminal(snapshot); err != nil {
		lock.Close()
		return err
	}
	lock.Close()
	if err := r.ResumeAgent(snapshot.SessionID, snapshot.Launch.ID); err != nil {
		return fmt.Errorf("saved conversation could not resume: %w", err)
	}
	return nil
}

func closedConversationActiveElsewhere(saved AgentLaunch, state State) bool {
	if saved.ProviderSessionID == "" {
		return false
	}
	for _, launch := range state.AgentLaunches {
		if launch.SessionID != saved.SessionID && launch.Lifecycle == "active" && launch.Provider == saved.Provider && launch.ProviderSessionID == saved.ProviderSessionID {
			return true
		}
	}
	return false
}

func sameClosedRootWitness(saved, current []closedProcessWitness, pid int) bool {
	var expected, actual *closedProcessWitness
	for _, witness := range saved {
		if witness.PID == pid {
			copy := witness
			expected = &copy
			break
		}
	}
	for _, witness := range current {
		if witness.PID == pid {
			copy := witness
			actual = &copy
			break
		}
	}
	return expected != nil && actual != nil && *expected == *actual
}

func (r *Runtime) ensureClosedTerminalCapacity(limit int) error {
	dir, err := r.closedDirectory(false)
	if err != nil {
		return err
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	operations := []string{}
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".json") {
			operations = append(operations, strings.TrimSuffix(entry.Name(), ".json"))
		}
	}
	if len(operations) < limit {
		return nil
	}
	prunable := []closedTerminalSnapshot{}
	for _, operation := range operations {
		snapshot, err := r.readClosedTerminal(operation)
		if err != nil {
			return err
		}
		if snapshot.Phase == "reopened" && snapshot.StartupAcknowledged {
			prunable = append(prunable, snapshot)
		}
	}
	sort.Slice(prunable, func(i, j int) bool { return prunable[i].CreatedAt < prunable[j].CreatedAt })
	count := len(operations)
	for _, snapshot := range prunable {
		for _, suffix := range []string{".history", ".json"} {
			if err := os.Remove(filepath.Join(dir, snapshot.OperationID+suffix)); err != nil && !os.IsNotExist(err) {
				return err
			}
		}
		count--
		if count < limit {
			return nil
		}
	}
	return errors.New("remote closed terminal storage is full; reopen retained terminals before closing more")
}
