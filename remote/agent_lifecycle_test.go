package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func lifecycleRuntime(t *testing.T, mode string) *Runtime {
	t.Helper()
	root, err := os.MkdirTemp("/tmp", "tr-lifecycle-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	write := func(path, data string) {
		t.Helper()
		if err := os.WriteFile(path, []byte(data), 0700); err != nil {
			t.Fatal(err)
		}
	}
	helper := filepath.Join(root, "helper")
	write(helper, "#!/bin/sh\nshift\ncat <&3 >/dev/null\nexec \"$@\"\n")
	write(filepath.Join(root, "claude"), "#!/bin/sh\nexec "+shellQuote(executable)+" -test.run=^TestLifecycleProviderProcess$ -- \"$@\"\n")
	tmux := filepath.Join(root, "tmux")
	write(tmux, "#!/bin/sh\nexit 0\n")
	t.Setenv("HOME", root)
	t.Setenv("PATH", root+":"+os.Getenv("PATH"))
	t.Setenv("CLAUDE_CONFIG_DIR", root)
	t.Setenv("TRANO_SESSION", taskPaneID)
	t.Setenv("TRANO_REMOTE_ROOT", root)
	t.Setenv("TRANO_REMOTE_HELPER", helper)
	t.Setenv("TRANO_LIFECYCLE_TEST_MODE", mode)
	t.Chdir(root)
	r := &Runtime{root: root, helper: helper, tmux: tmux, socket: filepath.Join(root, "mux.sock")}
	state := State{SchemaVersion: 1, Sessions: []Session{{ID: taskPaneID, Cwd: root, Alive: true}},
		AgentLaunches: []AgentLaunch{{ID: taskGeneration, SessionID: taskPaneID, Provider: "claude", ProviderSessionID: taskConversation, Cwd: root, ConfigurationRoot: root, Lifecycle: "active"}},
		Recovery:      []RecoveryResult{{SessionID: taskPaneID, Status: "restoring", Message: "pending"}}}
	if err := r.save(state); err != nil {
		t.Fatal(err)
	}
	return r
}

func TestLifecycleProviderProcess(t *testing.T) {
	mode := os.Getenv("TRANO_LIFECYCLE_TEST_MODE")
	if mode == "" {
		return
	}
	root := os.Getenv("TRANO_REMOTE_ROOT")
	r := &Runtime{root: root}
	pid := os.Getpid()
	records := map[int]processRecord{pid: {parent: 1, image: "/fixture/claude"}, pid + 1000000: {parent: pid, image: "/fixture/claude"}}
	lookup := func(id int) (processRecord, error) {
		item, ok := records[id]
		if !ok {
			return item, errors.New("unknown fixture process")
		}
		return item, nil
	}
	hook := func(event, conversation, generation, source string, origin int, child bool) {
		payload := map[string]string{"session_id": conversation, "cwd": root, "hook_event_name": event, "source": source}
		if child {
			payload["agent_id"], payload["agent_type"] = "worker", "Explore"
		}
		data, _ := json.Marshal(payload)
		if err := r.recordHook("claude", taskPaneID, generation, data, origin, lookup); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(90)
		}
	}
	generation := os.Getenv("TRANO_LAUNCH_ID")
	switch mode {
	case "stop-only":
		hook("Stop", taskConversation, generation, "", pid, false)
	case "child-only":
		hook("SessionStart", taskConversation, generation, "", pid+1000000, false)
	case "stale-only":
		hook("SessionStart", taskConversation, taskGeneration, "", pid, false)
	case "wrong-only":
		hook("SessionStart", "dddddddd-dddd-4ddd-8ddd-dddddddddddd", generation, "", pid, false)
	case "wrong-clear":
		hook("SessionStart", "dddddddd-dddd-4ddd-8ddd-dddddddddddd", generation, "clear", pid, false)
	case "confirmed", "confirmed-clear", "interrupt-crash", "interrupt-exit", "interrupt-130", "group-crash", "terminal-interrupt":
		hook("SessionStart", taskConversation, generation, "", pid, false)
		hook("SubagentStart", taskConversation, generation, "", pid, true)
		if mode == "confirmed-clear" {
			hook("SessionStart", "dddddddd-dddd-4ddd-8ddd-dddddddddddd", generation, "clear", pid, false)
		}
	}
	if strings.HasPrefix(mode, "interrupt-") || mode == "group-crash" || mode == "terminal-interrupt" {
		signals := make(chan os.Signal, 8)
		signal.Notify(signals, syscall.SIGINT)
		_ = os.WriteFile(filepath.Join(root, "ready"), []byte(strconv.Itoa(syscall.Getpgrp())), 0600)
		if mode == "terminal-interrupt" {
			group, err := terminalGroup(os.Stdin.Fd())
			if err != nil || group != syscall.Getpgrp() {
				os.Exit(93)
			}
			fmt.Fprintln(os.Stdout, "TRANO_LIFECYCLE_PTY_READY")
		}
		select {
		case <-signals:
		case <-time.After(5 * time.Second):
			os.Exit(91)
		}
		count := 1
		deadline := time.NewTimer(80 * time.Millisecond)
	collect:
		for {
			select {
			case <-signals:
				count++
			case <-deadline.C:
				break collect
			}
		}
		_ = os.WriteFile(filepath.Join(root, "interrupts"), []byte(strconv.Itoa(count)), 0600)
		if mode == "interrupt-exit" {
			signal.Reset(syscall.SIGINT)
			_ = syscall.Kill(pid, syscall.SIGINT)
			time.Sleep(time.Second)
			os.Exit(92)
		}
		if mode == "interrupt-130" {
			os.Exit(130)
		}
		os.Exit(42)
	}
	os.Exit(0)
}

func interruptLifecycle(t *testing.T, r *Runtime, group bool) <-chan error {
	t.Helper()
	result := make(chan error, 1)
	go func() {
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			if data, err := os.ReadFile(filepath.Join(r.root, "ready")); err == nil {
				if !group {
					result <- syscall.Kill(os.Getpid(), syscall.SIGINT)
					return
				}
				pgid, err := strconv.Atoi(string(data))
				if err != nil || pgid <= 1 || pgid == syscall.Getpgrp() {
					result <- errors.New("provider shares wrapper process group")
					return
				}
				result <- syscall.Kill(-pgid, syscall.SIGINT)
				return
			}
			time.Sleep(5 * time.Millisecond)
		}
		result <- errors.New("provider did not become ready")
	}()
	return result
}

// Implements: FR-REMOTE-RECOVERY-2, FR-REMOTE-RECOVERY-3
func TestAgentHandledInterruptDoesNotHideLaterCrash(t *testing.T) {
	r := lifecycleRuntime(t, "interrupt-crash")
	sent := interruptLifecycle(t, r, false)
	err := r.RunAgent("claude", nil, "")
	if err := <-sent; err != nil {
		t.Fatal(err)
	}
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.ExitCode() != 42 {
		t.Fatalf("actual provider crash lost: %v", err)
	}
	state, _ := r.load()
	if state.AgentLaunches[0].Lifecycle != "active" || state.AgentLaunches[0].ProcessID != 0 || state.AgentLaunches[0].ProviderPID != 0 {
		t.Fatalf("handled interrupt hid later crash: %#v", state.AgentLaunches[0])
	}
	if data, _ := os.ReadFile(filepath.Join(r.root, "interrupts")); string(data) != "1" {
		t.Fatalf("targeted wrapper interrupt delivered %s times", data)
	}
}

// Implements: FR-REMOTE-RECOVERY-2
func TestAgentActualInterruptExitIsNormal(t *testing.T) {
	for _, mode := range []string{"interrupt-exit", "interrupt-130"} {
		t.Run(mode, func(t *testing.T) {
			r := lifecycleRuntime(t, mode)
			sent := interruptLifecycle(t, r, false)
			if err := r.RunAgent("claude", nil, ""); err == nil {
				t.Fatal("interrupt exit status disappeared")
			}
			if err := <-sent; err != nil {
				t.Fatal(err)
			}
			state, _ := r.load()
			if state.AgentLaunches[0].Lifecycle != "exited" {
				t.Fatalf("actual interrupt exit was not normal: %#v", state.AgentLaunches[0])
			}
		})
	}
}

// Implements: FR-REMOTE-RECOVERY-2, FR-REMOTE-RECOVERY-3
func TestAgentResumeRequiresCurrentRootSessionStart(t *testing.T) {
	for _, mode := range []string{"no-start", "stop-only", "child-only", "stale-only", "wrong-only", "wrong-clear"} {
		t.Run(mode, func(t *testing.T) {
			r := lifecycleRuntime(t, mode)
			err := r.RunAgent("claude", []string{"--resume", taskConversation}, taskGeneration)
			if err == nil || !strings.Contains(err.Error(), "confirm") {
				t.Fatalf("unconfirmed zero exit accepted: %v", err)
			}
			state, _ := r.load()
			launch := state.AgentLaunches[0]
			if launch.Lifecycle != "active" || launch.ProviderSessionID != taskConversation || launch.ConfigurationRoot != r.root || launch.Cwd != r.root || launch.ProcessID != 0 || launch.ProviderPID != 0 {
				t.Fatalf("unconfirmed resume lost retry metadata: %#v", launch)
			}
			if len(state.Recovery) != 1 || state.Recovery[0].Status != "needs_attention" || !strings.Contains(state.Recovery[0].Message, "confirm") {
				t.Fatalf("unconfirmed resume has no diagnostic: %#v", state.Recovery)
			}
		})
	}
}

// Implements: FR-REMOTE-RECOVERY-2, FR-REMOTE-RECOVERY-3
func TestAgentResumeCannotConfirmAnEmptyMapping(t *testing.T) {
	r := lifecycleRuntime(t, "no-start")
	state, _ := r.load()
	state.AgentLaunches[0].ProviderSessionID = ""
	if err := r.save(state); err != nil {
		t.Fatal(err)
	}
	if err := r.RunAgent("claude", nil, taskGeneration); err == nil {
		t.Fatal("empty inherited mapping counted as verified resume")
	}
	state, _ = r.load()
	if state.AgentLaunches[0].Lifecycle != "active" || state.Recovery[0].Status != "needs_attention" {
		t.Fatalf("unmapped resume is not retryable and diagnosed: %#v", state)
	}
}

// Implements: FR-REMOTE-RECOVERY-2, FR-HOVER-3, FR-HOVER-4
func TestAgentResumeRootConfirmationPreservesTaskContract(t *testing.T) {
	for _, mode := range []string{"confirmed", "confirmed-clear"} {
		t.Run(mode, func(t *testing.T) {
			r := lifecycleRuntime(t, mode)
			if err := r.RunAgent("claude", []string{"--resume", taskConversation}, taskGeneration); err != nil {
				t.Fatal(err)
			}
			state, _ := r.load()
			if state.AgentLaunches[0].Lifecycle != "exited" || state.Recovery[0].Status != "restored" {
				t.Fatalf("verified resume rejected: %#v", state)
			}
			if mode == "confirmed" && (len(state.Sessions[0].AgentTasks) != 1 || state.Sessions[0].AgentTasks[0].ID != "worker") {
				t.Fatal("root confirmation lost child task")
			}
			if mode == "confirmed-clear" && (len(state.Sessions[0].AgentTasks) != 0 || state.AgentLaunches[0].ProviderSessionID != "dddddddd-dddd-4ddd-8ddd-dddddddddddd") {
				t.Fatal("root clear stopped replacing identity and clearing tasks")
			}
		})
	}
}

// Implements: FR-REMOTE-RECOVERY-2
func TestAgentGroupInterruptReachesProviderOnce(t *testing.T) {
	r := lifecycleRuntime(t, "group-crash")
	sent := interruptLifecycle(t, r, true)
	err := r.RunAgent("claude", nil, "")
	if err := <-sent; err != nil {
		t.Fatal(err)
	}
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.ExitCode() != 42 {
		t.Fatalf("provider group interrupt did not reach provider: %v", err)
	}
	if data, _ := os.ReadFile(filepath.Join(r.root, "interrupts")); string(data) != "1" {
		t.Fatalf("provider group interrupt delivered %s times", data)
	}
}

func TestAgentTerminalHandoffAllowsNonTerminalInput(t *testing.T) {
	for _, path := range []string{"/dev/null"} {
		input, err := os.Open(path)
		if err != nil {
			t.Fatal(err)
		}
		restore, err := handoffAgentTerminal(input, os.Getpid())
		if err != nil {
			t.Errorf("non-terminal input prevented launch: %v", err)
		} else if err := restore(); err != nil {
			t.Error(err)
		}
		_ = input.Close()
	}
}

// Implements: FR-REMOTE-RECOVERY-2
func TestAgentTerminalInterruptAndForegroundRestore(t *testing.T) {
	group, err := terminalGroup(os.Stdin.Fd())
	if errors.Is(err, syscall.ENOTTY) || errors.Is(err, syscall.ENODEV) {
		t.Skip("requires an isolated controlling PTY")
	}
	if err != nil || group != syscall.Getpgrp() {
		t.Fatalf("test does not own foreground terminal: group=%d err=%v", group, err)
	}
	r := lifecycleRuntime(t, "terminal-interrupt")
	err = r.RunAgent("claude", nil, "")
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.ExitCode() != 42 {
		t.Fatalf("terminal interrupt did not reach provider: %v", err)
	}
	if data, _ := os.ReadFile(filepath.Join(r.root, "interrupts")); string(data) != "1" {
		t.Fatalf("terminal interrupt delivered %s times", data)
	}
	restored, err := terminalGroup(os.Stdin.Fd())
	if err != nil || restored != group {
		t.Fatalf("wrapper did not reclaim foreground: group=%d expected=%d err=%v", restored, group, err)
	}
	state, _ := r.load()
	if state.AgentLaunches[0].Lifecycle != "active" {
		t.Fatal("terminal interrupt hid the later crash")
	}
}
