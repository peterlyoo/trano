package main

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type AgentLaunch struct {
	ID                string  `json:"id"`
	SessionID         string  `json:"sessionID"`
	Provider          string  `json:"provider"`
	ProviderSessionID string  `json:"providerSessionID,omitempty"`
	StartedSessionID  string  `json:"startedSessionID,omitempty"`
	Cwd               string  `json:"cwd"`
	ConfigurationRoot string  `json:"configurationRoot"`
	BootID            string  `json:"bootID"`
	ProcessID         int     `json:"processID"`
	ProviderPID       int     `json:"providerPID"`
	Lifecycle         string  `json:"lifecycle"`
	UpdatedAt         float64 `json:"updatedAt"`
}
type RecoveryResult struct {
	SessionID string  `json:"sessionID"`
	Status    string  `json:"status"`
	Message   string  `json:"message"`
	UpdatedAt float64 `json:"updatedAt"`
}

func validDirectory(path string) bool {
	if !filepath.IsAbs(path) || strings.ContainsAny(path, "\x00\r\n") {
		return false
	}
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}
func (r *Runtime) spawnShell(id, cwd string) (int, error) {
	shell := os.Getenv("SHELL")
	if !filepath.IsAbs(shell) {
		shell = "/bin/sh"
	}
	if info, err := os.Stat(shell); err != nil || info.Mode()&0111 == 0 {
		shell = "/bin/sh"
	}
	extra, arguments, err := r.shellIntegration(shell)
	if err != nil {
		return 0, err
	}
	args := []string{"new-session", "-d", "-P", "-F", "#{pane_pid}", "-s", id, "-x", "100", "-y", "30", "-c", cwd,
		"-e", "TRANO_SESSION=" + id, "-e", "TRANO_REMOTE_ROOT=" + r.root, "-e", "COLORTERM=truecolor"}
	for _, value := range extra {
		args = append(args, "-e", value)
	}
	if r.helper != "" {
		command := shellQuote(r.helper) + " replay " + shellQuote(id) + "; exec " + shellQuote(shell)
		for _, argument := range arguments {
			command += " " + shellQuote(argument)
		}
		args = append(args, "--", "/bin/sh", "-c", command)
	} else {
		args = append(args, "--", shell)
		args = append(args, arguments...)
	}
	output, err := r.command(args...)
	for attempt := 0; err != nil && missingServer(output) && attempt < 3; attempt++ {
		time.Sleep(time.Duration(attempt+1) * 25 * time.Millisecond)
		if existing, check := r.command("display-message", "-p", "-t", id+":0.0", "#{pane_pid}"); check == nil {
			output, err = existing, nil
			break
		}
		output, err = r.command(args...)
	}
	if err != nil {
		return 0, err
	}
	pid, err := strconv.Atoi(strings.TrimSpace(output))
	if err != nil {
		_, _ = r.command("kill-session", "-t", "="+id)
	}
	return pid, err
}
func (r *Runtime) monitor(id string) error {
	if r.helper == "" {
		return nil
	}
	pid, err := r.command("display-message", "-p", "-t", id+":0.0", "#{pane_pid}")
	if err != nil {
		return err
	}
	command := "exec env " + shellQuote("TRANO_REMOTE_ROOT="+r.root) + " " + shellQuote(r.helper) + " monitor " + shellQuote(id) + " " + shellQuote(strings.TrimSpace(pid))
	_, err = r.command("pipe-pane", "-O", "-t", id+":0.0", command)
	return err
}
func (r *Runtime) RecordDirectory(id, cwd string) error {
	if !validDirectory(cwd) {
		return errors.New("invalid working directory")
	}
	lock, err := r.lock()
	if err != nil {
		return err
	}
	defer lock.Close()
	state, err := r.load()
	if err != nil {
		return err
	}
	if err := require(state, id); err != nil {
		return err
	}
	for i := range state.Sessions {
		if state.Sessions[i].ID == id {
			state.Sessions[i].Cwd = cwd
		}
	}
	return r.save(state)
}
func (r *Runtime) RecoveryResults() ([]RecoveryResult, error) {
	lock, err := r.lock()
	if err != nil {
		return nil, err
	}
	defer lock.Close()
	state, err := r.load()
	if state.Recovery == nil {
		state.Recovery = []RecoveryResult{}
	}
	return state.Recovery, err
}
func (r *Runtime) Recover(id string) ([]RecoveryResult, error) {
	lock, err := r.lock()
	if err != nil {
		return nil, err
	}
	defer lock.Close()
	state, err := r.load()
	if err != nil {
		return nil, err
	}
	if id != "" {
		if err := require(state, id); err != nil {
			return nil, err
		}
	}
	output, err := r.command("list-panes", "-a", "-F", "#{session_name}|#{pane_dead}")
	if err != nil && !missingServer(output) {
		return nil, err
	}
	live := map[string]bool{}
	for _, line := range strings.Split(output, "\n") {
		fields := strings.Split(line, "|")
		if len(fields) == 2 {
			live[fields[0]] = fields[1] == "0"
		}
	}
	results := []RecoveryResult{}
	for i := range state.Sessions {
		pane := &state.Sessions[i]
		if id != "" && pane.ID != id {
			continue
		}
		result := RecoveryResult{SessionID: pane.ID, Status: "live", Message: "Existing remote process preserved", UpdatedAt: now()}
		if !live[pane.ID] {
			result.Status, result.Message = "restored", "Remote shell restored"
			var launch *AgentLaunch
			for j := range state.AgentLaunches {
				if state.AgentLaunches[j].SessionID == pane.ID && state.AgentLaunches[j].Lifecycle == "active" {
					launch = &state.AgentLaunches[j]
					break
				}
			}
			cwd := pane.Cwd
			canResume := launch != nil && validID.MatchString(launch.ProviderSessionID) && validDirectory(launch.Cwd) && validDirectory(launch.ConfigurationRoot) && r.helper != ""
			if launch != nil {
				if canResume {
					cwd = launch.Cwd
				} else {
					result.Status, result.Message = "needs_attention", "Agent resume requires a verified conversation ID, configuration directory and working directory"
				}
			}
			if !validDirectory(cwd) {
				result.Status, result.Message = "failed", "Original working directory is missing"
			} else {
				_, _ = r.command("kill-session", "-t", "="+pane.ID)
				pid, startErr := r.spawnShell(pane.ID, cwd)
				if startErr == nil {
					startErr = r.monitor(pane.ID)
				}
				if startErr != nil {
					result.Status, result.Message = "failed", startErr.Error()
				} else {
					pane.PID, pane.Alive, pane.Cwd = pid, true, cwd
					if canResume {
						launch.ProcessID, launch.ProviderPID = 0, 0
						command := shellQuote(r.helper) + " resume " + shellQuote(pane.ID) + " " + shellQuote(launch.ID)
						if _, sendErr := r.command("send-keys", "-t", pane.ID+":0.0", "-l", "--", command); sendErr == nil {
							_, sendErr = r.command("send-keys", "-t", pane.ID+":0.0", "Enter")
							if sendErr != nil {
								result.Status, result.Message = "failed", sendErr.Error()
							} else {
								result.Status, result.Message = "restoring", "Resuming verified remote agent conversation"
							}
						} else {
							result.Status, result.Message = "failed", sendErr.Error()
						}
					}
				}
			}
		} else {
			for _, previous := range state.Recovery {
				if previous.SessionID == pane.ID {
					result = previous
				}
			}
		}
		kept := state.Recovery[:0]
		for _, previous := range state.Recovery {
			if previous.SessionID != pane.ID {
				kept = append(kept, previous)
			}
		}
		state.Recovery = append(kept, result)
		results = append(results, result)
	}
	return results, r.save(state)
}
