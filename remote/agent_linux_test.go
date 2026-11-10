package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestMain(m *testing.M) {
	if filepath.Base(os.Args[0]) == "claude" || filepath.Base(os.Args[0]) == "codex" {
		fakeProvider()
		return
	}
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "agent", "agent-exec", "hook", "monitor", "cwd", "resume", "replay":
			if err := run(); err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			return
		}
	}
	os.Exit(m.Run())
}
func fakeProvider() {
	provider := filepath.Base(os.Args[0])
	id := "11111111-1111-4111-8111-111111111111"
	if provider == "codex" {
		id = "22222222-2222-4222-8222-222222222222"
	}
	child := len(os.Args) > 1 && os.Args[1] == "sdk"
	if child {
		id = "99999999-9999-4999-8999-999999999999"
	} else {
		cmd := exec.Command(os.Args[0], "sdk")
		cmd.Env = os.Environ()
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		_ = cmd.Run()
	}
	cwd, _ := os.Getwd()
	data, _ := json.Marshal(map[string]string{"session_id": id, "cwd": cwd, "hook_event_name": "SessionStart"})
	hook := exec.Command(os.Getenv("TRANO_REMOTE_HELPER"), "hook", provider)
	hook.Env = os.Environ()
	hook.Stdin = strings.NewReader(string(data))
	hook.Stderr = os.Stderr
	if err := hook.Run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
	}
	if child {
		return
	}
	doneData, _ := json.Marshal(map[string]string{"session_id": id, "cwd": cwd, "hook_event_name": "Stop"})
	doneHook := exec.Command(os.Getenv("TRANO_REMOTE_HELPER"), "hook", provider)
	doneHook.Env = os.Environ()
	doneHook.Stdin = strings.NewReader(string(doneData))
	_ = doneHook.Run()
	record, _ := json.Marshal(map[string]any{"provider": provider, "args": os.Args[1:], "cwd": cwd, "rex": os.Getenv("REX_BLOCK")})
	file, _ := os.OpenFile(os.Getenv("TRANO_FAKE_LOG"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0600)
	if file != nil {
		_, _ = file.Write(append(record, '\n'))
		file.Close()
	}
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		if scanner.Text() == "quit" {
			return
		}
	}
}
func waitFor(t *testing.T, f func() bool) {
	t.Helper()
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		if f() {
			return
		}
		time.Sleep(30 * time.Millisecond)
	}
	t.Fatal("timed out")
}

// Implements: FR-REMOTE-RECOVERY-2, FR-REMOTE-RECOVERY-3
func TestLinuxAgentRecoveryKeepsExactIdentityAndExcludesExited(t *testing.T) {
	r := recoveryRuntime(t)
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	r.helper = executable
	providers := filepath.Join(r.root, "providers")
	_ = os.Mkdir(providers, 0700)
	for _, provider := range []string{"claude", "codex"} {
		if err := os.Symlink(executable, filepath.Join(providers, provider)); err != nil {
			t.Fatal(err)
		}
		_ = os.Mkdir(filepath.Join(r.root, "."+provider), 0700)
	}
	t.Setenv("PATH", providers+":"+os.Getenv("PATH"))
	t.Setenv("REX_BLOCK", "must-not-inherit")
	if err := os.WriteFile(filepath.Join(r.root, ".profile"), []byte("export PATH="+shellQuote(os.Getenv("PATH"))+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	log := filepath.Join(r.root, "launches.jsonl")
	t.Setenv("TRANO_FAKE_LOG", log)
	claude, err := r.Create("claude", r.root)
	if err != nil {
		t.Fatal(err)
	}
	codex, err := r.Create("codex", r.root)
	if err != nil {
		t.Fatal(err)
	}
	activeCodex, err := r.Create("active codex", r.root)
	if err != nil {
		t.Fatal(err)
	}
	if err := r.Send(activeCodex.ID, "codex", true); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if t.Failed() {
			for _, id := range []string{claude.ID, codex.ID, activeCodex.ID} {
				output, _ := r.Capture(id, 100)
				t.Log(output)
			}
			s, _ := r.load()
			t.Logf("launches=%#v", s.AgentLaunches)
		}
	}()
	if err := r.Send(claude.ID, "claude", true); err != nil {
		t.Fatal(err)
	}
	if err := r.Send(codex.ID, "codex", true); err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool {
		state, _ := r.load()
		return len(state.AgentLaunches) == 3 && state.AgentLaunches[0].ProviderSessionID != "" && state.AgentLaunches[1].ProviderSessionID != "" && state.AgentLaunches[2].ProviderSessionID != ""
	})
	state, _ := r.load()
	for _, launch := range state.AgentLaunches {
		if launch.ProviderSessionID == "99999999-9999-4999-8999-999999999999" {
			t.Fatal("early SDK child won mapping")
		}
	}
	if err := r.Send(codex.ID, "quit", true); err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool {
		s, _ := r.load()
		for _, l := range s.AgentLaunches {
			if l.SessionID == codex.ID {
				return l.Lifecycle == "exited"
			}
		}
		return false
	})
	_, _ = r.command("kill-server")
	time.Sleep(150 * time.Millisecond)
	results, err := r.Recover("")
	if err != nil {
		t.Fatal(err)
	}
	if len(results) != 3 {
		t.Fatalf("bad recovery: %#v", results)
	}
	waitFor(t, func() bool {
		s, _ := r.load()
		for _, l := range s.AgentLaunches {
			if l.SessionID == claude.ID {
				return l.ProcessID > 0 && l.ProviderPID > 0 && l.ProviderSessionID == "11111111-1111-4111-8111-111111111111"
			}
		}
		return false
	})
	waitFor(t, func() bool {
		data, _ := os.ReadFile(log)
		return len(strings.Split(strings.TrimSpace(string(data)), "\n")) == 5
	})
	data, _ := os.ReadFile(log)
	if strings.Contains(string(data), "must-not-inherit") {
		t.Fatal("Rex identity inherited")
	}
	if !strings.Contains(string(data), "--resume\",\"11111111-1111-4111-8111-111111111111") {
		t.Fatalf("exact resume missing: %s", data)
	}
	if !strings.Contains(string(data), "resume\",\"22222222-2222-4222-8222-222222222222") {
		t.Fatalf("Codex exact resume missing: %s", data)
	}
	before, _ := r.List()
	if _, err := r.Recover(""); err != nil {
		t.Fatal(err)
	}
	after, _ := r.List()
	for i := range before {
		if before[i].PID != after[i].PID {
			t.Fatal("second restore replaced process")
		}
	}
}

// Implements: FR-RECOVERY-SCROLLBACK-1
func TestLinuxScrollbackRestoresOutputWithoutExecutingIt(t *testing.T) {
	r := recoveryRuntime(t)
	r.helper, _ = os.Executable()
	pane, err := r.Create("history", r.root)
	if err != nil {
		t.Fatal(err)
	}
	forbidden := filepath.Join(r.root, "must-not-execute")
	text := "printf '%s\\n' '__TRANO_SAVED_HISTORY__ 한글' " + shellQuote("touch "+forbidden)
	if err := r.Send(pane.ID, text, true); err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool { info, _ := r.ScrollbackMetadata(pane.ID); return info != nil && info.ByteCount > 0 })
	_, _ = r.command("kill-server")
	if _, err := r.Recover(pane.ID); err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool {
		text, _ := r.Capture(pane.ID, 100)
		return strings.Contains(text, "__TRANO_SAVED_HISTORY__ 한글")
	})
	if _, err := os.Stat(forbidden); !os.IsNotExist(err) {
		t.Fatal("saved terminal output was executed as shell input")
	}
	if err := r.SetScrollback(false); err != nil {
		t.Fatal(err)
	}
	_, _ = r.command("kill-server")
	if _, err := r.Recover(pane.ID); err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)
	if text, _ := r.Capture(pane.ID, 100); strings.Contains(text, "__TRANO_SAVED_HISTORY__") {
		t.Fatal("disabled scrollback replayed")
	}
}
