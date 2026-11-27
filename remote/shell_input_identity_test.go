package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func shellInputWitness(probe *programProbe, pid int) string {
	_, shell := probe.inputIdentities(pid)
	return shell
}

func shellInputField(t *testing.T, session Session) string {
	t.Helper()
	data, err := json.Marshal(session)
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		t.Fatal(err)
	}
	var identity string
	if value, ok := fields["shellInputIdentity"]; ok {
		if err := json.Unmarshal(value, &identity); err != nil {
			t.Fatal(err)
		}
	}
	return identity
}

func TestShellInputIdentityRequiresExactForegroundBackendShell(t *testing.T) {
	for _, name := range []string{"zsh", "bash", "fish", "dash", "sh", "ksh"} {
		t.Run(name, func(t *testing.T) {
			proc := newProgramFixture(t)
			proc.process(100, 1, 100, 100, 15, 10, "/bin/"+name, nil, "")
			probe := newProgramProbe(proc.root, uint32(os.Getuid()))
			if got := shellInputWitness(probe, 100); got != "100:10:15:100" {
				t.Fatalf("backend shell witness=%q", got)
			}
		})
	}
}

func TestShellInputIdentityRejectsNonShellAndNonForegroundBackend(t *testing.T) {
	for _, test := range []struct {
		name, image       string
		group, foreground int
		tty               int64
		birth             uint64
	}{
		{"provider", "/opt/claude", 100, 100, 15, 10},
		{"codex", "/opt/codex", 100, 100, 15, 10},
		{"substring", "/bin/fake-zsh", 100, 100, 15, 10},
		{"unknown", "/bin/python", 100, 100, 15, 10},
		{"child foreground", "/bin/zsh", 100, 200, 15, 10},
		{"nonleader backend", "/bin/zsh", 200, 200, 15, 10},
		{"no tty", "/bin/zsh", 100, 100, 0, 10},
		{"no foreground", "/bin/zsh", 100, -1, 15, 10},
		{"no birth", "/bin/zsh", 100, 100, 15, 0},
	} {
		t.Run(test.name, func(t *testing.T) {
			proc := newProgramFixture(t)
			proc.process(100, 1, test.group, test.foreground, test.tty, test.birth, test.image, nil, "200")
			proc.process(200, 100, 200, 200, 15, 20, "/bin/zsh", nil, "")
			probe := newProgramProbe(proc.root, uint32(os.Getuid()))
			if got := shellInputWitness(probe, 100); got != "" {
				t.Fatalf("unready backend witness=%q", got)
			}
		})
	}
}

func TestShellInputIdentityRejectsForeignUIDDeadAndMissingProcesses(t *testing.T) {
	proc := newProgramFixture(t)
	proc.process(100, 1, 100, 100, 15, 10, "/bin/zsh", nil, "")
	if got := shellInputWitness(newProgramProbe(proc.root, uint32(os.Getuid()+1)), 100); got != "" {
		t.Fatalf("foreign uid witness=%q", got)
	}
	probe := newProgramProbe(proc.root, uint32(os.Getuid()))
	path := filepath.Join(proc.root, "100", "stat")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, state := range []string{"Z", "X"} {
		if err := os.WriteFile(path, []byte(strings.Replace(string(data), ") S ", ") "+state+" ", 1)), 0600); err != nil {
			t.Fatal(err)
		}
		if got := shellInputWitness(probe, 100); got != "" {
			t.Fatalf("dead process witness=%q", got)
		}
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	for _, pid := range []int{0, 1, 100, 999} {
		if got := shellInputWitness(probe, pid); got != "" {
			t.Fatalf("missing process witness=%q", got)
		}
	}
}

func TestShellInputIdentityInvalidatesPIDBirthTTYAndForegroundTransitions(t *testing.T) {
	proc := newProgramFixture(t)
	probe := newProgramProbe(proc.root, uint32(os.Getuid()))
	proc.process(100, 1, 100, 100, 15, 10, "/bin/zsh", nil, "")
	first := shellInputWitness(probe, 100)
	proc.process(100, 1, 100, 100, 15, 11, "/bin/zsh", nil, "")
	second := shellInputWitness(probe, 100)
	proc.process(100, 1, 100, 100, 16, 11, "/bin/zsh", nil, "")
	third := shellInputWitness(probe, 100)
	if first == "" || second == "" || third == "" || first == second || second == third {
		t.Fatalf("identity not invalidated by birth or tty: %q %q %q", first, second, third)
	}
	proc.process(100, 1, 100, 200, 16, 11, "/bin/zsh", nil, "200")
	proc.process(200, 100, 200, 200, 16, 20, "/opt/codex", nil, "")
	if got := shellInputWitness(probe, 100); got != "" {
		t.Fatalf("active provider witness=%q", got)
	}
	proc.process(100, 1, 100, 100, 16, 11, "/bin/zsh", nil, "")
	if got := shellInputWitness(probe, 100); got != third {
		t.Fatalf("same shell witness changed: %q != %q", got, third)
	}
	proc.process(100, 1, 100, 100, 16, 11, "/opt/codex", nil, "")
	if got := shellInputWitness(probe, 100); got != "" {
		t.Fatalf("replacement executable witness=%q", got)
	}
}

func TestShellInputIdentityProjectionIsEphemeralAndClearsUnprovedMetadata(t *testing.T) {
	var live Session
	if err := json.Unmarshal([]byte(`{"id":"live","pid":100,"alive":true,"agent":"claude","shellInputIdentity":"stale"}`), &live); err != nil {
		t.Fatal(err)
	}
	if got := shellInputField(t, live); got != "stale" {
		t.Fatalf("optional reply field not decoded: %q", got)
	}
	dead := live
	dead.ID = "dead"
	dead.Alive = false
	input := []Session{live, dead}
	before, err := json.Marshal(input)
	if err != nil {
		t.Fatal(err)
	}
	calls := 0
	result := projectForegroundPrograms(input, func(int) string { return "zsh" }, func(pid int) (string, string) {
		calls++
		if pid != 100 {
			t.Fatalf("unexpected backend pid=%d", pid)
		}
		return "100:10:15:100", "100:10:15:100"
	})
	if calls != 1 || shellInputField(t, result[0]) != "100:10:15:100" || shellInputField(t, result[1]) != "" {
		t.Fatalf("wrong ephemeral projection: calls=%d result=%+v", calls, result)
	}
	after, err := json.Marshal(input)
	if err != nil || string(before) != string(after) {
		t.Fatalf("projection changed stored sessions: %v", err)
	}
	if result[0].Agent != "claude" || result[0].ForegroundProgram != "zsh" {
		t.Fatalf("projection changed identity: %+v", result[0])
	}
	result = projectForegroundPrograms(input, func(int) string { return "zsh" })
	for _, session := range result {
		data, err := json.Marshal(session)
		if err != nil || !strings.Contains(string(data), `"shellInputIdentity":""`) || !strings.Contains(string(data), `"inputBackendIdentity":""`) {
			t.Fatalf("supported helper omitted its empty witness: %s %v", data, err)
		}
	}
}

func TestShellInputIdentityWireDistinguishesMissingSupportFromBusyShell(t *testing.T) {
	sessions := []Session{{ID: "busy", PID: 100, Alive: true}, {ID: "dead", PID: 101}}
	before, err := json.Marshal(sessions)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(before), "shellInputIdentity") || strings.Contains(string(before), "inputBackendIdentity") {
		t.Fatalf("source sessions contain response metadata: %s", before)
	}
	for _, source := range []func(int) (string, string){nil, func(int) (string, string) { return "", "" }} {
		result := projectForegroundPrograms(sessions, func(int) string { return "codex" }, source)
		for _, session := range result {
			data, err := json.Marshal(session)
			if err != nil || !strings.Contains(string(data), `"shellInputIdentity":""`) || !strings.Contains(string(data), `"inputBackendIdentity":""`) {
				t.Fatalf("new helper must return explicit empty witness: %s %v", data, err)
			}
		}
	}
	after, err := json.Marshal(sessions)
	if err != nil || string(before) != string(after) {
		t.Fatalf("source sessions gained response metadata: %s %v", after, err)
	}
}

func TestShellInputIdentityBackendIsStableWhileProviderOwnsForeground(t *testing.T) {
	proc := newProgramFixture(t)
	probe := newProgramProbe(proc.root, uint32(os.Getuid()))
	proc.process(100, 1, 100, 200, 15, 10, "/bin/zsh", nil, "200")
	proc.process(200, 100, 200, 200, 15, 20, "/opt/codex", nil, "")
	backend, shell := probe.inputIdentities(100)
	if backend != "100:10:15:100" || shell != "" {
		t.Fatalf("busy backend=%q shell=%q", backend, shell)
	}
	proc.process(100, 1, 100, 100, 15, 10, "/bin/zsh", nil, "")
	readyBackend, readyShell := probe.inputIdentities(100)
	if readyBackend != backend || readyShell != backend {
		t.Fatalf("handoff changed backend: %q %q", readyBackend, readyShell)
	}
	proc.process(100, 1, 100, 100, 15, 11, "/bin/zsh", nil, "")
	replacement, replacementShell := probe.inputIdentities(100)
	if replacement == "" || replacement == backend || replacementShell != replacement {
		t.Fatalf("respawn reused identity: %q %q", replacement, replacementShell)
	}
	if unknown, shell := newProgramProbe(proc.root, uint32(os.Getuid()+1)).inputIdentities(100); unknown != "" || shell != "" {
		t.Fatalf("foreign owner has witnesses: %q %q", unknown, shell)
	}
}

func TestShellInputIdentityBackendProjectionOverwritesStaleReplyMetadata(t *testing.T) {
	var old Session
	if err := json.Unmarshal([]byte(`{"id":"live","pid":100,"alive":true,"shellInputIdentity":"stale-shell","inputBackendIdentity":"stale-backend"}`), &old); err != nil {
		t.Fatal(err)
	}
	source := []Session{old}
	before, err := json.Marshal(source)
	if err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct{ backend, shell, expectedShell string }{
		{"100:10:15:100", "", ""},
		{"100:10:15:100", "100:10:15:100", "100:10:15:100"},
		{"", "stale-shell", ""},
		{"100:11:15:100", "100:10:15:100", ""},
	} {
		result := projectForegroundPrograms(source, func(int) string { return "codex" }, func(int) (string, string) { return test.backend, test.shell })
		data, err := json.Marshal(result[0])
		if err != nil {
			t.Fatal(err)
		}
		var fields map[string]json.RawMessage
		if err := json.Unmarshal(data, &fields); err != nil {
			t.Fatal(err)
		}
		for key, expected := range map[string]string{"inputBackendIdentity": test.backend, "shellInputIdentity": test.expectedShell} {
			raw, ok := fields[key]
			var actual string
			if !ok || json.Unmarshal(raw, &actual) != nil || actual != expected {
				t.Fatalf("projection %s=%s expected %q", key, raw, expected)
			}
		}
	}
	after, err := json.Marshal(source)
	if err != nil || string(before) != string(after) {
		t.Fatalf("projection changed older source metadata: %s %v", after, err)
	}
}
