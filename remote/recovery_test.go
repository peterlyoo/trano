package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func recoveryRuntime(t *testing.T) *Runtime {
	t.Helper()
	root, err := os.MkdirTemp("/tmp", "tr-recover-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })
	t.Setenv("HOME", root)
	t.Setenv("SHELL", "/bin/sh")
	r, err := NewRuntime(root)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = r.command("kill-server") })
	return r
}

// Implements: FR-REMOTE-RECOVERY-1
func TestRecoveryRestoresSameShellOnceAndPersistsDirectory(t *testing.T) {
	r := recoveryRuntime(t)
	session, err := r.Create("kept", r.root)
	if err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(r.root, "한글 space")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if _, err := r.command("respawn-pane", "-k", "-t", session.ID+":0.0", "-c", dir, "/bin/sh"); err != nil {
		t.Fatal(err)
	}
	listed, err := r.List()
	if err != nil || len(listed) != 1 {
		t.Fatalf("list %v %v", listed, err)
	}
	dir, _ = filepath.EvalSymlinks(dir)
	saved, _ := r.load()
	if saved.Sessions[0].Cwd != dir {
		t.Fatalf("latest cwd not saved: %q", saved.Sessions[0].Cwd)
	}
	_, _ = r.command("kill-server")
	response := r.Route(Request{APIVersion: 1, Method: "recovery.run"})
	if response.Error != "" {
		t.Fatalf("recovery unavailable: %s", response.Error)
	}
	listed, err = r.List()
	if err != nil || len(listed) != 1 || !listed[0].Alive || listed[0].ID != session.ID || listed[0].Cwd != dir {
		t.Fatalf("identity not restored: %#v %v", listed, err)
	}
	pid := listed[0].PID
	response = r.Route(Request{APIVersion: 1, Method: "recovery.run"})
	listed, _ = r.List()
	if response.Error != "" || listed[0].PID != pid {
		t.Fatal("repeated restore replaced live process")
	}
}

// Implements: FR-REMOTE-RECOVERY-2
func TestUnmappedActiveAgentFallsBackWithoutBlindReplay(t *testing.T) {
	r := recoveryRuntime(t)
	session, err := r.Create("unmapped", r.root)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = r.command("kill-server")
	data, _ := os.ReadFile(filepath.Join(r.root, "state.json"))
	var state map[string]any
	_ = json.Unmarshal(data, &state)
	state["agentLaunches"] = []any{map[string]any{"id": "11111111-1111-4111-8111-111111111111", "sessionID": session.ID, "provider": "claude", "cwd": r.root, "configurationRoot": r.root, "lifecycle": "active", "bootID": "old"}}
	data, _ = json.Marshal(state)
	_ = atomicWrite(filepath.Join(r.root, "state.json"), data)
	response := r.Route(Request{APIVersion: 1, Method: "recovery.run"})
	if response.Error != "" {
		t.Fatal(response.Error)
	}
	encoded, _ := json.Marshal(response.Result)
	var rows []struct {
		Status string `json:"status"`
	}
	if err := json.Unmarshal(encoded, &rows); err != nil || len(rows) != 1 || rows[0].Status != "needs_attention" {
		t.Fatalf("missing mapping not diagnosed: %s", encoded)
	}
	listed, _ := r.List()
	if !listed[0].Alive {
		t.Fatal("fallback shell missing")
	}
}

// Implements: FR-REMOTE-RECOVERY-1, FR-PERF-1
func TestUnchangedListDoesNotRewriteDurableState(t *testing.T) {
	r := recoveryRuntime(t)
	if _, err := r.Create("stable", r.root); err != nil {
		t.Fatal(err)
	}
	if _, err := r.List(); err != nil {
		t.Fatal(err)
	}
	before, _ := os.Stat(filepath.Join(r.root, "state.json"))
	if _, err := r.List(); err != nil {
		t.Fatal(err)
	}
	after, _ := os.Stat(filepath.Join(r.root, "state.json"))
	if !before.ModTime().Equal(after.ModTime()) {
		t.Fatal("read-only polling rewrote unchanged state")
	}
}
