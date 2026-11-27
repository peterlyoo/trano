package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// Implements: FR-NAV-11
func TestProgramClassifierRequiresExactExecutableAndExecSubcommand(t *testing.T) {
	cases := []struct {
		name, image, want string
		args              []string
	}{
		{"zsh", "/bin/zsh", "zsh", nil},
		{"k9s", "/opt/k9s", "k9s", nil},
		{"claude", "/opt/claude", "claude", nil},
		{"codex", "/opt/codex", "codex", nil},
		{"not substring", "/opt/fake-k9s", "", nil},
		{"unknown", "/bin/bash", "", nil},
		{"exec", "/opt/kubectl", "kubectl_exec", []string{"kubectl", "exec", "pod", "--", "sh"}},
		{"context then exec", "/opt/kubectl", "kubectl_exec", []string{"kubectl", "--context", "fixture", "-n", "apps", "exec", "pod", "--", "sh"}},
		{"empty context then exec", "/opt/kubectl", "kubectl_exec", []string{"kubectl", "--context", "", "exec", "pod", "--", "sh"}},
		{"hyphen context then exec", "/opt/kubectl", "kubectl_exec", []string{"kubectl", "--context", "-fixture", "exec", "pod", "--", "sh"}},
		{"attached globals", "/opt/kubectl", "kubectl_exec", []string{"kubectl", "--context=fixture", "-napps", "-v9", "exec", "pod"}},
		{"bool then exec", "/opt/kubectl", "kubectl_exec", []string{"kubectl", "--insecure-skip-tls-verify", "exec", "pod"}},
		{"namespace value", "/opt/kubectl", "", []string{"kubectl", "--namespace", "exec", "get", "pods"}},
		{"context value", "/opt/kubectl", "", []string{"kubectl", "--context", "exec", "get", "pods"}},
		{"quoted positional", "/opt/kubectl", "", []string{"kubectl", "get", "exec"}},
		{"remote exec token", "/opt/kubectl", "", []string{"kubectl", "get", "pods", "--", "exec"}},
		{"root separator", "/opt/kubectl", "", []string{"kubectl", "--", "exec", "pod"}},
		{"missing global value", "/opt/kubectl", "", []string{"kubectl", "--context"}},
		{"unknown flag", "/opt/kubectl", "", []string{"kubectl", "--future-flag", "exec", "pod"}},
		{"version query", "/opt/kubectl", "", []string{"kubectl", "--version", "exec"}},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			if got := classifyProgram(test.image, test.args); got != test.want {
				t.Fatalf("program=%q want=%q", got, test.want)
			}
		})
	}
}

// Implements: FR-NAV-11
func TestProgramForegroundIgnoresBackgroundAndReturnsToZsh(t *testing.T) {
	proc := newProgramFixture(t)
	proc.process(100, 1, 100, 200, 15, 10, "/bin/zsh", nil, "200 300")
	proc.process(200, 100, 200, 200, 15, 20, "/opt/k9s", nil, "")
	proc.process(300, 100, 300, 200, 15, 30, "/opt/kubectl", []string{"kubectl", "exec", "background-pod"}, "")
	probe := newProgramProbe(proc.root, uint32(os.Getuid()))
	if got := probe.foreground(100); got != "k9s" {
		t.Fatalf("foreground=%q", got)
	}
	proc.process(100, 1, 100, 100, 15, 10, "/bin/zsh", nil, "200 300")
	if got := probe.foreground(100); got != "zsh" {
		t.Fatalf("background replaced shell: %q", got)
	}
}

// Implements: FR-NAV-11
func TestProgramForegroundFindsSameGroupDescendantAndRejectsForeignIdentity(t *testing.T) {
	proc := newProgramFixture(t)
	proc.process(100, 1, 100, 200, 15, 10, "/bin/zsh", nil, "200")
	proc.process(200, 100, 200, 200, 15, 20, "/opt/wrapper", nil, "201")
	proc.process(201, 200, 200, 200, 15, 21, "/opt/kubectl", []string{"kubectl", "--context", "fixture", "exec", "pod", "--", "sh"}, "")
	probe := newProgramProbe(proc.root, uint32(os.Getuid()))
	if got := probe.foreground(100); got != "kubectl_exec" {
		t.Fatalf("foreground descendant=%q", got)
	}
	proc.process(201, 200, 200, 200, 16, 21, "/opt/kubectl", []string{"kubectl", "exec", "pod"}, "")
	if got := probe.foreground(100); got != "" {
		t.Fatalf("foreign tty accepted: %q", got)
	}
	proc.process(201, 200, 201, 200, 15, 21, "/opt/kubectl", []string{"kubectl", "exec", "pod"}, "")
	if got := probe.foreground(100); got != "" {
		t.Fatalf("background group accepted: %q", got)
	}
	if got := newProgramProbe(proc.root, uint32(os.Getuid()+1)).foreground(100); got != "" {
		t.Fatalf("foreign uid accepted: %q", got)
	}
}

// Implements: FR-NAV-11
func TestProgramProbeBoundsArgsAndRejectsMissingOrMalformedProc(t *testing.T) {
	proc := newProgramFixture(t)
	proc.process(100, 1, 100, 200, 15, 10, "/bin/zsh", nil, "200")
	proc.process(200, 100, 200, 200, 15, 20, "/opt/kubectl", []string{"kubectl", "exec", strings.Repeat("x", 1<<17)}, "")
	probe := newProgramProbe(proc.root, uint32(os.Getuid()))
	if got := probe.foreground(100); got != "" {
		t.Fatalf("oversized argv accepted: %q", got)
	}
	if err := os.WriteFile(filepath.Join(proc.root, "200", "stat"), []byte("malformed"), 0600); err != nil {
		t.Fatal(err)
	}
	if got := probe.foreground(100); got != "" {
		t.Fatalf("malformed proc accepted: %q", got)
	}
	if got := probe.foreground(999); got != "" {
		t.Fatalf("missing proc accepted: %q", got)
	}
}

// Implements: FR-NAV-11
func TestProgramProjectionKeepsAgentIdentityAndOriginalStateUnchanged(t *testing.T) {
	before := []Session{{ID: "pane", PID: 100, Agent: "codex", Alive: true, Activity: Activity{State: "done", Source: "hook"}}, {ID: "dead", PID: 101, Agent: "claude"}}
	encoded, _ := json.Marshal(before)
	calls := 0
	projected := projectForegroundPrograms(before, func(pid int) string { calls++; return "k9s" })
	if calls != 1 || projected[0].ForegroundProgram != "k9s" || projected[1].ForegroundProgram != "" {
		t.Fatalf("metadata projection mismatch: calls=%d", calls)
	}
	after, _ := json.Marshal(before)
	if !bytes.Equal(encoded, after) || projected[0].Agent != before[0].Agent || projected[0].Activity != before[0].Activity {
		t.Fatal("program metadata changed agent/state identity")
	}
	var legacy Session
	if err := json.Unmarshal([]byte(`{"id":"legacy","pid":42,"agent":"shell","alive":true}`), &legacy); err != nil || legacy.ForegroundProgram != "" {
		t.Fatalf("legacy session decode failed: %v", err)
	}
}

// Implements: FR-NAV-11
func TestProgramProbeDoesNotReuseOldPIDMetadata(t *testing.T) {
	proc := newProgramFixture(t)
	proc.process(100, 1, 100, 200, 15, 10, "/bin/zsh", nil, "200")
	proc.process(200, 100, 200, 200, 15, 20, "/opt/k9s", nil, "")
	probe := newProgramProbe(proc.root, uint32(os.Getuid()))
	if got := probe.foreground(100); got != "k9s" {
		t.Fatalf("initial program=%q", got)
	}
	proc.process(200, 100, 200, 200, 15, 21, "/opt/kubectl", []string{"kubectl", "get", "pods"}, "")
	if got := probe.foreground(100); got != "" {
		t.Fatalf("old process metadata reused: %q", got)
	}
	proc.process(100, 1, 100, -1, 0, 10, "/bin/zsh", nil, "200")
	if got := probe.foreground(100); got != "" {
		t.Fatalf("process without controlling tty accepted: %q", got)
	}
}

// Implements: FR-NAV-11
func TestProgramRuntimeListLeavesStateBytesUnchanged(t *testing.T) {
	root, err := os.MkdirTemp("/tmp", "trano-program-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(root)
	root, err = filepath.EvalSymlinks(root)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("SHELL", "/bin/sh")
	t.Setenv("HOME", root)
	runtime, err := NewRuntime(root)
	if err != nil {
		t.Fatal(err)
	}
	pane, err := runtime.Create("Program fixture", root)
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Terminate(pane.ID)
	if _, err := runtime.List(); err != nil {
		t.Fatal(err)
	}
	state := filepath.Join(root, "state.json")
	before, err := os.ReadFile(state)
	if err != nil {
		t.Fatal(err)
	}
	for count := 0; count < 3; count++ {
		rows, err := runtime.List()
		if err != nil || len(rows) != 1 || rows[0].PID != pane.PID || !rows[0].Alive {
			t.Fatalf("list changed pane identity: %v", err)
		}
	}
	after, err := os.ReadFile(state)
	if err != nil || !bytes.Equal(before, after) || bytes.Contains(after, []byte("foregroundProgram")) {
		t.Fatalf("list persisted foreground metadata: %v", err)
	}
}

type programFixture struct {
	t    *testing.T
	root string
}

func newProgramFixture(t *testing.T) *programFixture {
	t.Helper()
	return &programFixture{t: t, root: t.TempDir()}
}

func (f *programFixture) process(pid, parent, group, foreground int, tty int64, started uint64, image string, args []string, children string) {
	f.t.Helper()
	dir := filepath.Join(f.root, strconv.Itoa(pid))
	if err := os.MkdirAll(filepath.Join(dir, "task", strconv.Itoa(pid)), 0700); err != nil {
		f.t.Fatal(err)
	}
	fields := []string{"S", strconv.Itoa(parent), strconv.Itoa(group), strconv.Itoa(parent), strconv.FormatInt(tty, 10), strconv.Itoa(foreground)}
	for len(fields) < 19 {
		fields = append(fields, "0")
	}
	fields = append(fields, strconv.FormatUint(started, 10))
	stat := fmt.Sprintf("%d (fixture ) name) %s\n", pid, strings.Join(fields, " "))
	for name, data := range map[string][]byte{"stat": []byte(stat), "cmdline": []byte(strings.Join(args, "\x00") + "\x00"), filepath.Join("task", strconv.Itoa(pid), "children"): []byte(children)} {
		if err := os.WriteFile(filepath.Join(dir, name), data, 0600); err != nil {
			f.t.Fatal(err)
		}
	}
	_ = os.Remove(filepath.Join(dir, "exe"))
	if err := os.Symlink(image, filepath.Join(dir, "exe")); err != nil {
		f.t.Fatal(err)
	}
}
