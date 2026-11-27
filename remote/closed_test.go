package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

const closedID = "31a856b4-2222-4222-8222-222222222222"
const closeOperation = "42a856b4-2222-4222-8222-222222222222"
const closeLaunch = "53a856b4-2222-4222-8222-222222222222"
const closeConversation = "64a856b4-2222-4222-8222-222222222222"

type closedFixture struct {
	r              *Runtime
	live           bool
	pid            int
	generation     string
	captureError   bool
	spawnError     bool
	stopError      bool
	events         []string
	spawnArguments []string
	operationID    string
	extraWitness   bool
	bootID         string
}

func newClosedFixture(t *testing.T) *closedFixture {
	t.Helper()
	f := &closedFixture{live: true, pid: 42, generation: "fixture:42:700", bootID: "fixture"}
	f.r = &Runtime{root: t.TempDir(), helper: "/fixture/trano-server"}
	f.r.closedProcesses = f
	t.Setenv("HOME", f.r.root)
	t.Setenv("SHELL", "/bin/sh")
	if err := f.r.save(State{SchemaVersion: 1, Sessions: []Session{{ID: closedID, PID: f.pid, Alive: true, Title: "kept", Cwd: f.r.root, Agent: "shell", Host: "remote"}}}); err != nil {
		t.Fatal(err)
	}
	f.r.commandOverride = func(_ int, args ...string) (string, error) {
		switch args[0] {
		case "capture-pane":
			f.events = append(f.events, "capture")
			if f.captureError {
				return "", errors.New("fixture capture failure")
			}
			return "saved display\n\x1b]52;c;ignored\x07", nil
		case "kill-session":
			f.events = append(f.events, "kill")
			snapshot, err := f.r.readClosedTerminal(closeOperation)
			if err != nil || snapshot.Phase != "committing" {
				t.Fatal("termination preceded the durable committing record")
			}
			f.live = false
			return "", nil
		case "new-session":
			f.events = append(f.events, "spawn")
			f.spawnArguments = append([]string(nil), args...)
			if f.spawnError {
				return "", errors.New("fixture spawn failure")
			}
			if f.live {
				t.Fatal("duplicate process creation")
			}
			f.live, f.pid, f.generation = true, 84, "fixture:84:900"
			f.operationID = closeOperation
			return "84\n", nil
		case "display-message":
			if f.live {
				return strconv.Itoa(f.pid) + "\n", nil
			}
			return "no server running", errors.New("missing fixture process")
		case "list-panes":
			if f.live {
				return closedID + "|0|" + strconv.Itoa(f.pid) + "|" + f.r.root + "\n", nil
			}
			return "no server running", errors.New("missing fixture process")
		case "pipe-pane":
			return "", nil
		default:
			t.Fatalf("unexpected backend command %q", args[0])
			return "", errors.New("unexpected command")
		}
	}
	return f
}

func (f *closedFixture) Observe(_ *Runtime, id string) (closedProcess, error) {
	if !f.live {
		return closedProcess{}, errClosedProcessMissing
	}
	witnesses := []closedProcessWitness{{PID: f.pid, Birth: uint64(f.pid), BootID: f.bootID}}
	if f.extraWitness {
		witnesses = append(witnesses, closedProcessWitness{PID: 55, Birth: 55, BootID: "fixture"})
	}
	return closedProcess{PID: f.pid, Generation: f.generation, Cwd: f.r.root, Shell: "/bin/bash", OperationID: f.operationID, Witnesses: witnesses}, nil
}
func (f *closedFixture) Stop(witnesses []closedProcessWitness) error {
	f.events = append(f.events, "stop")
	if f.extraWitness && len(witnesses) != 2 {
		return errors.New("new descendant was not captured at commit")
	}
	if f.stopError {
		return errors.New("fixture process still alive")
	}
	return nil
}
func (f *closedFixture) CheckStopped(_ []closedProcessWitness) error {
	if f.stopError {
		return errors.New("fixture process still alive")
	}
	return nil
}
func closeRequest(method string) Request {
	return historyRequest(method, map[string]any{"id": closedID, "operationID": closeOperation, "expectedPID": 42, "expectedGeneration": "fixture:42:700"})
}
func closedResult(t *testing.T, response Response) ClosedTerminalResult {
	t.Helper()
	if response.Error != "" {
		t.Fatal(response.Error)
	}
	result, ok := response.Result.(ClosedTerminalResult)
	if !ok {
		t.Fatal("unexpected close response")
	}
	return result
}

// Implements: FR-CLOSE-6
func TestClosedTerminalCapabilityIsExplicit(t *testing.T) {
	r := &Runtime{root: t.TempDir()}
	response := r.Route(Request{APIVersion: 1, Method: "server.info"})
	info, ok := response.Result.(map[string]any)
	if response.Error != "" || !ok || info["closedTerminalProtocol"] != 1 {
		t.Fatal("remote helper must advertise the snapshot-before-terminate protocol")
	}
}

// Implements: FR-CLOSE-6
func TestClosedTerminalRoutesRecognizeOperationWithoutStartingProcesses(t *testing.T) {
	r := &Runtime{root: t.TempDir()}
	for _, method := range []string{"close.prepare", "close.commit", "close.status", "close.reopen", "close.cancel"} {
		response := r.Route(Request{APIVersion: 1, Method: method})
		if response.Error == "" || strings.Contains(response.Error, "unknown API method") {
			t.Fatalf("%s must validate its operation before any backend effect", method)
		}
	}
}

// Implements: FR-CLOSE-1, FR-CLOSE-6, FR-CLOSE-7
func TestClosedTerminalCancelOnlyMatchingPreparedSnapshotAndRetriesSafely(t *testing.T) {
	f := newClosedFixture(t)
	closedResult(t, f.r.Route(closeRequest("close.prepare")))
	wrong := closeRequest("close.cancel")
	wrong.Params["expectedGeneration"], _ = json.Marshal("another-generation")
	if f.r.Route(wrong).Error == "" {
		t.Fatal("mismatched cancellation deleted a snapshot")
	}
	for attempt := 0; attempt < 2; attempt++ {
		result := closedResult(t, f.r.Route(closeRequest("close.cancel")))
		if result.Phase != "cancelled" || result.OperationID != closeOperation || result.SessionID != closedID {
			t.Fatal("cancellation acknowledgment lost its target")
		}
	}
	if _, err := f.r.readClosedTerminal(closeOperation); !os.IsNotExist(err) {
		t.Fatal("prepared snapshot was retained after cancellation")
	}
	if !f.live || !reflect.DeepEqual(f.events, []string{"capture"}) {
		t.Fatal("cancellation touched terminal processes")
	}
	missing := closeRequest("close.cancel")
	delete(missing.Params, "expectedGeneration")
	if f.r.Route(missing).Error == "" {
		t.Fatal("missing cancellation must still require the expected token")
	}
}

// Implements: FR-CLOSE-1, FR-CLOSE-2, FR-CLOSE-6
func TestClosedTerminalCancelPreservesEveryOperationAfterCommitBegins(t *testing.T) {
	f := newClosedFixture(t)
	closedResult(t, f.r.Route(closeRequest("close.prepare")))
	snapshot, _ := f.r.readClosedTerminal(closeOperation)
	for _, phase := range []string{"committing", "closed", "reopening", "reopened"} {
		snapshot.Phase = phase
		if err := f.r.writeClosedTerminal(snapshot); err != nil {
			t.Fatal(err)
		}
		if f.r.Route(closeRequest("close.cancel")).Error == "" {
			t.Fatalf("cancellation accepted phase %s", phase)
		}
		retained, err := f.r.readClosedTerminal(closeOperation)
		if err != nil || retained.Phase != phase {
			t.Fatal("cancellation changed recoverable committed state")
		}
	}
	if !f.live || !reflect.DeepEqual(f.events, []string{"capture"}) {
		t.Fatal("cancellation touched terminal processes")
	}
}

// Implements: FR-CLOSE-1, FR-CLOSE-2, FR-CLOSE-6, FR-CLOSE-7
func TestClosedTerminalCapturesBeforeKillAndRetriesWithoutRepeatingEffects(t *testing.T) {
	f := newClosedFixture(t)
	prepared := closedResult(t, f.r.Route(closeRequest("close.prepare")))
	if prepared.Phase != "prepared" || !f.live || !reflect.DeepEqual(f.events, []string{"capture"}) {
		t.Fatal("prepare changed the process")
	}
	if info, err := os.Stat(filepath.Join(f.r.root, "closed-terminals", closeOperation+".json")); err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("snapshot is not durable and private")
	}
	closedResult(t, f.r.Route(closeRequest("close.prepare")))
	committed := closedResult(t, f.r.Route(closeRequest("close.commit")))
	closedResult(t, f.r.Route(closeRequest("close.commit")))
	status := closedResult(t, f.r.Route(closeRequest("close.status")))
	if committed.Phase != "closed" || status.Phase != "closed" || f.live || !reflect.DeepEqual(f.events, []string{"capture", "kill", "stop"}) {
		t.Fatal("close was not idempotent")
	}
	snapshot, err := f.r.readClosedTerminal(closeOperation)
	if err != nil || !strings.Contains(snapshot.Display, "saved display") || strings.ContainsAny(snapshot.Display, "\x1b\x07") {
		t.Fatal("snapshot display not retained safely")
	}
}

// Implements: FR-CLOSE-1, FR-CLOSE-6
func TestClosedTerminalCaptureFailureAndChangedGenerationNeverKill(t *testing.T) {
	f := newClosedFixture(t)
	f.captureError = true
	if f.r.Route(closeRequest("close.prepare")).Error == "" || !f.live {
		t.Fatal("capture failure must preserve process")
	}
	f.captureError = false
	closedResult(t, f.r.Route(closeRequest("close.prepare")))
	f.generation = "fixture:42:701"
	if f.r.Route(closeRequest("close.commit")).Error == "" || !f.live {
		t.Fatal("PID reuse must not terminate a new generation")
	}
	for _, event := range f.events {
		if event == "kill" || event == "spawn" {
			t.Fatal("unsafe effect after failed close")
		}
	}
}

// Implements: FR-CLOSE-1, FR-CLOSE-2
func TestClosedTerminalCommitRejectsMatchingPIDFromAnotherBoot(t *testing.T) {
	f := newClosedFixture(t)
	closedResult(t, f.r.Route(closeRequest("close.prepare")))
	f.bootID = "next-boot"
	if f.r.Route(closeRequest("close.commit")).Error == "" || !f.live {
		t.Fatal("matching PID and birth ticks from another boot must not be stopped")
	}
}

// Implements: FR-CLOSE-2, FR-CLOSE-7
func TestClosedTerminalExclusionSurvivesPrimaryStateRewrite(t *testing.T) {
	f := newClosedFixture(t)
	before, err := f.r.load()
	if err != nil {
		t.Fatal(err)
	}
	closedResult(t, f.r.Route(closeRequest("close.prepare")))
	closedResult(t, f.r.Route(closeRequest("close.commit")))
	if err := f.r.save(before); err != nil {
		t.Fatal(err)
	}
	results, err := f.r.Recover("")
	if err != nil {
		t.Fatal(err)
	}
	for _, result := range results {
		if result.Status == "restored" || result.Status == "restoring" {
			t.Fatal("ordinary recovery resurrected an intentional close")
		}
	}
	if f.live {
		t.Fatal("ordinary recovery restarted a closed process")
	}
}

// Implements: FR-CLOSE-3, FR-CLOSE-4, FR-CLOSE-6
func TestClosedTerminalReopenUsesSameShellAndExactConversationOnce(t *testing.T) {
	f := newClosedFixture(t)
	state, _ := f.r.load()
	state.AgentLaunches = []AgentLaunch{{ID: closeLaunch, SessionID: closedID, Provider: "claude", ProviderSessionID: closeConversation, ConfigurationRoot: f.r.root, Cwd: f.r.root, Lifecycle: "active", ProcessID: 50, ProviderPID: 51}}
	if err := f.r.save(state); err != nil {
		t.Fatal(err)
	}
	closedResult(t, f.r.Route(closeRequest("close.prepare")))
	closedResult(t, f.r.Route(closeRequest("close.commit")))
	first := closedResult(t, f.r.Route(closeRequest("close.reopen")))
	second := closedResult(t, f.r.Route(closeRequest("close.reopen")))
	if first.Phase != "reopened" || first.Session == nil || first.Session.PID != 84 || second.Session == nil || second.Session.PID != 84 {
		t.Fatal("reopen did not retain the fresh process")
	}
	joined := strings.Join(f.spawnArguments, " ")
	startup, _ := os.ReadFile(filepath.Join(f.r.root, "shell", "bashrc"))
	if !strings.Contains(joined, "/bin/bash") || !strings.Contains(joined, "closed-replay") || !strings.Contains(joined, closeOperation) || strings.Contains(joined, "--last") || !strings.Contains(string(startup), "closed-start") {
		t.Fatal("reopen did not bind the owned startup operation")
	}
	snapshot, _ := f.r.readClosedTerminal(closeOperation)
	if snapshot.Launch == nil || snapshot.Launch.ID != closeLaunch || snapshot.Launch.ProviderSessionID != closeConversation {
		t.Fatal("immutable exact agent binding lost")
	}
	spawns := 0
	for _, event := range f.events {
		if event == "spawn" {
			spawns++
		}
	}
	if spawns != 1 {
		t.Fatal("reopen retry spawned twice")
	}
}

// Implements: FR-CLOSE-3, FR-CLOSE-6
func TestClosedTerminalReopenAdoptsItsDurableStartedProcessAfterLostReply(t *testing.T) {
	f := newClosedFixture(t)
	closedResult(t, f.r.Route(closeRequest("close.prepare")))
	closedResult(t, f.r.Route(closeRequest("close.commit")))
	closedResult(t, f.r.Route(closeRequest("close.reopen")))
	snapshot, err := f.r.readClosedTerminal(closeOperation)
	if err != nil {
		t.Fatal(err)
	}
	snapshot.Phase, snapshot.Session, snapshot.RestoredGeneration = "reopening", nil, ""
	if err := f.r.writeClosedTerminal(snapshot); err != nil {
		t.Fatal(err)
	}
	result := closedResult(t, f.r.Route(closeRequest("close.reopen")))
	if result.Session == nil || result.Session.PID != 84 {
		t.Fatal("reopen did not reconcile its existing process")
	}
	spawns := 0
	for _, event := range f.events {
		if event == "spawn" {
			spawns++
		}
	}
	if spawns != 1 {
		t.Fatal("reconciliation repeated process creation")
	}
}

// Implements: FR-CLOSE-1, FR-CLOSE-4
func TestClosedTerminalCommitIncludesDescendantsBornAfterPreparation(t *testing.T) {
	f := newClosedFixture(t)
	closedResult(t, f.r.Route(closeRequest("close.prepare")))
	f.extraWitness = true
	closedResult(t, f.r.Route(closeRequest("close.commit")))
	snapshot, err := f.r.readClosedTerminal(closeOperation)
	if err != nil || len(snapshot.Witnesses) != 2 {
		t.Fatal("final process witnesses must be durable before kill")
	}
}

// Implements: FR-CLOSE-3, FR-CLOSE-4, FR-CLOSE-6
func TestClosedTerminalStartupReconcilesInterruptedReopenBeforeResumeClaim(t *testing.T) {
	f := newClosedFixture(t)
	closedResult(t, f.r.Route(closeRequest("close.prepare")))
	closedResult(t, f.r.Route(closeRequest("close.commit")))
	closedResult(t, f.r.Route(closeRequest("close.reopen")))
	snapshot, err := f.r.readClosedTerminal(closeOperation)
	if err != nil {
		t.Fatal(err)
	}
	snapshot.Phase, snapshot.Session, snapshot.RestoredGeneration = "reopening", nil, ""
	if err := f.r.writeClosedTerminal(snapshot); err != nil {
		t.Fatal(err)
	}
	f.pid, f.generation = os.Getppid(), "fixture:startup:900"
	if err := f.r.StartClosedTerminal(closeOperation); err != nil {
		t.Fatal(err)
	}
	snapshot, err = f.r.readClosedTerminal(closeOperation)
	if err != nil || snapshot.Phase != "reopened" || snapshot.Session == nil || snapshot.Session.PID != os.Getppid() {
		t.Fatal("startup lost the interrupted reopen result")
	}
}

// Implements: FR-CLOSE-1, FR-CLOSE-4
func TestClosedTerminalChangedAgentConversationAbortsBeforeKill(t *testing.T) {
	f := newClosedFixture(t)
	state, _ := f.r.load()
	state.AgentLaunches = []AgentLaunch{{ID: closeLaunch, SessionID: closedID, Provider: "claude", ProviderSessionID: closeConversation, ConfigurationRoot: f.r.root, Cwd: f.r.root, Lifecycle: "active"}}
	if err := f.r.save(state); err != nil {
		t.Fatal(err)
	}
	closedResult(t, f.r.Route(closeRequest("close.prepare")))
	state.AgentLaunches[0].ProviderSessionID = closeOperation
	if err := f.r.save(state); err != nil {
		t.Fatal(err)
	}
	if f.r.Route(closeRequest("close.commit")).Error == "" || !f.live {
		t.Fatal("changed conversation was terminated")
	}
}

// Implements: FR-CLOSE-3, FR-CLOSE-7
func TestClosedTerminalNativeHistoryPreservesCompleteRecordsAndDataOnlyImport(t *testing.T) {
	plain := []byte(strings.Repeat("echo old\n", 11000) + "echo retained\n")
	if got := boundNativeClosedHistory(plain, "bash", false); len(got) > closedHistoryBytes || strings.Count(string(got), "\n") != closedHistoryRecords || !strings.HasSuffix(string(got), "echo retained\n") {
		t.Fatal("native history limits lost complete records")
	}
	zsh := []byte("partial\\\ncontinued\n: 1700000000:0;echo multi\\\nline\n")
	if got := string(boundNativeClosedHistory(zsh, "zsh", true)); got != ": 1700000000:0;echo multi\\\nline\n" && got != "continued\n: 1700000000:0;echo multi\\\nline\n" {
		t.Fatal("zsh native records were split")
	}
	bash := []byte("partial\n#1700000000\necho multi\nline\n#1700000001\necho last\n")
	if got := string(boundNativeClosedHistory(bash, "bash", true)); !strings.HasPrefix(got, "#1700000000\n") {
		t.Fatal("timestamped bash native record was split")
	}
	for _, shell := range []string{"bash", "zsh"} {
		startup := closedHistoryStartup(shell)
		if strings.Contains(startup, "eval ") || strings.Contains(startup, "source ") || !strings.Contains(startup, "TRANO_HISTORY_OWNER") {
			t.Fatal("native history import must remain data-only and generation-owned")
		}
	}
}

// Implements: FR-CLOSE-4
func TestClosedTerminalReopenDoesNotDuplicateConversationRunningElsewhere(t *testing.T) {
	f := newClosedFixture(t)
	state, _ := f.r.load()
	launch := AgentLaunch{ID: closeLaunch, SessionID: closedID, Provider: "codex", ProviderSessionID: closeConversation, ConfigurationRoot: f.r.root, Cwd: f.r.root, Lifecycle: "active"}
	state.AgentLaunches = []AgentLaunch{launch}
	if err := f.r.save(state); err != nil {
		t.Fatal(err)
	}
	closedResult(t, f.r.Route(closeRequest("close.prepare")))
	closedResult(t, f.r.Route(closeRequest("close.commit")))
	state, _ = f.r.load()
	launch.SessionID, launch.ID = closeConversation, closeOperation
	state.AgentLaunches = append(state.AgentLaunches, launch)
	if err := f.r.save(state); err != nil {
		t.Fatal(err)
	}
	closedResult(t, f.r.Route(closeRequest("close.reopen")))
	snapshot, _ := f.r.readClosedTerminal(closeOperation)
	state, _ = f.r.load()
	if snapshot.ResumeState != "unavailable" || len(state.Recovery) != 1 || state.Recovery[0].Status != "needs_attention" {
		t.Fatal("conversation already running elsewhere must reopen as an actionable shell")
	}
	for _, current := range state.AgentLaunches {
		if current.SessionID == closedID && current.Lifecycle == "active" {
			t.Fatal("duplicate conversation became eligible to start")
		}
	}
}

// Implements: FR-CLOSE-7
func TestClosedTerminalPrivateReadersRejectFIFOWithoutBlocking(t *testing.T) {
	path := filepath.Join(t.TempDir(), "fifo")
	if err := syscall.Mkfifo(path, 0600); err != nil {
		t.Fatal(err)
	}
	for _, read := range []func() error{
		func() error { _, err := readClosedFile(path, 1024); return err },
		func() error { _, err := readNativeClosedHistory(path, "bash", true); return err },
	} {
		result := make(chan error, 1)
		go func(read func() error) { result <- read() }(read)
		select {
		case err := <-result:
			if err == nil {
				t.Fatal("FIFO accepted as a regular file")
			}
		case <-time.After(200 * time.Millisecond):
			t.Fatal("private history read blocked before validating file type")
		}
	}
}

// Implements: FR-CLOSE-1, FR-CLOSE-3, FR-CLOSE-7
func TestClosedTerminalPendingNativeHistoryExportNeverFallsBackBeforeKill(t *testing.T) {
	f := newClosedFixture(t)
	dir := filepath.Join(f.r.root, "shell-history")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	selection := closedShellSelection{Token: closeLaunch, Shell: "/bin/bash", PID: 42, Generation: f.generation, BootID: "fixture"}
	data, _ := json.Marshal(selection)
	if err := writeClosedFile(filepath.Join(dir, closedID+".json"), data); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, closeLaunch+".history")
	if err := writeClosedFile(path, []byte("echo complete\n")); err != nil {
		t.Fatal(err)
	}
	if err := writeClosedFile(path+".pending", []byte("42\n")); err != nil {
		t.Fatal(err)
	}
	if f.r.Route(closeRequest("close.prepare")).Error == "" || !f.live {
		t.Fatal("in-progress native export was treated as a complete snapshot")
	}
	if err := os.Remove(path + ".pending"); err != nil {
		t.Fatal(err)
	}
	result := closedResult(t, f.r.Route(closeRequest("close.prepare")))
	if result.HistoryProvenance != "journal" {
		t.Fatal("completed native history was not retained")
	}
}

// Implements: FR-CLOSE-1, FR-CLOSE-7
func TestClosedTerminalCapacityPreservesClosedDataAndPrunesOnlyAcknowledgedReopens(t *testing.T) {
	f := newClosedFixture(t)
	closedResult(t, f.r.Route(closeRequest("close.prepare")))
	snapshot, _ := f.r.readClosedTerminal(closeOperation)
	snapshot.OperationID = closeConversation
	if err := f.r.writeClosedTerminal(snapshot); err != nil {
		t.Fatal(err)
	}
	if err := f.r.ensureClosedTerminalCapacity(2); err == nil || !f.live {
		t.Fatal("full storage did not preserve pending closes")
	}
	snapshot.Phase, snapshot.StartupAcknowledged = "reopened", true
	if err := f.r.writeClosedTerminal(snapshot); err != nil {
		t.Fatal(err)
	}
	if err := f.r.ensureClosedTerminalCapacity(2); err != nil {
		t.Fatal(err)
	}
	if _, err := f.r.readClosedTerminal(closeOperation); err != nil {
		t.Fatal("capacity cleanup deleted a pending close")
	}
	if _, err := f.r.readClosedTerminal(closeConversation); !os.IsNotExist(err) {
		t.Fatal("acknowledged old reopen was not pruned")
	}
}

// Implements: FR-CLOSE-3, FR-CLOSE-4
func TestClosedTerminalStartupPreservesOriginalShellAndRunsAfterLoginConfiguration(t *testing.T) {
	f := newClosedFixture(t)
	if _, _, err := f.r.shellIntegration("/bin/zsh"); err != nil {
		t.Fatal(err)
	}
	login, err := os.ReadFile(filepath.Join(f.r.root, "shell", ".zlogin"))
	if err != nil || !strings.Contains(string(login), "closed-start") {
		t.Fatal("zsh close restore must run after login configuration")
	}
	rc, err := os.ReadFile(filepath.Join(f.r.root, "shell", ".zshrc"))
	if err != nil || strings.Contains(string(rc), "closed-start") {
		t.Fatal("agent resumed before remaining login configuration")
	}
	f.live = false
	if _, err := f.r.spawnSelectedShell(closedID, f.r.root, "/usr/bin/fish", closeOperation); err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(f.spawnArguments, " ")
	if !strings.Contains(joined, "/usr/bin/fish") || !strings.Contains(joined, "-C") || !strings.Contains(joined, "closed-start") {
		t.Fatal("fish needs its native post-configuration startup route")
	}
}

// Implements: FR-CLOSE-2, FR-CLOSE-3, FR-CLOSE-4
func TestClosedTerminalUncertainStopAndUnmappedAgentRetainRecovery(t *testing.T) {
	f := newClosedFixture(t)
	state, _ := f.r.load()
	state.AgentLaunches = []AgentLaunch{{ID: closeLaunch, SessionID: closedID, Provider: "codex", Cwd: f.r.root, ConfigurationRoot: f.r.root, Lifecycle: "active"}}
	if err := f.r.save(state); err != nil {
		t.Fatal(err)
	}
	closedResult(t, f.r.Route(closeRequest("close.prepare")))
	f.stopError = true
	if f.r.Route(closeRequest("close.commit")).Error == "" {
		t.Fatal("uncertain process stop reported success")
	}
	if f.r.Route(closeRequest("close.reopen")).Error == "" {
		t.Fatal("reopen raced a retained provider")
	}
	f.stopError = false
	closedResult(t, f.r.Route(closeRequest("close.commit")))
	closedResult(t, f.r.Route(closeRequest("close.reopen")))
	state, _ = f.r.load()
	if len(state.Recovery) != 1 || state.Recovery[0].Status != "needs_attention" {
		t.Fatal("unmapped conversation must remain actionable without guessed resume")
	}
}

// Implements: FR-CLOSE-6, FR-CLOSE-7
func TestClosedTerminalRejectsSnapshotSymlinkAndForeignOperation(t *testing.T) {
	f := newClosedFixture(t)
	dir := filepath.Join(f.r.root, "closed-terminals")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(f.r.root, "foreign")
	if err := os.WriteFile(target, []byte("private fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(dir, closeOperation+".json")); err != nil {
		t.Fatal(err)
	}
	if f.r.Route(closeRequest("close.prepare")).Error == "" || len(f.events) != 0 {
		t.Fatal("symlink snapshot should fail before capture or kill")
	}
	data, err := os.ReadFile(target)
	if err != nil || string(data) != "private fixture" {
		t.Fatal("unowned target changed")
	}
	f = newClosedFixture(t)
	closedResult(t, f.r.Route(closeRequest("close.prepare")))
	request := closeRequest("close.commit")
	request.Params["id"], _ = json.Marshal(closeConversation)
	if f.r.Route(request).Error == "" || !f.live {
		t.Fatal("operation was rebound to another pane")
	}
}

// Implements: FR-CLOSE-3, FR-CLOSE-7
func TestClosedTerminalHistoryFallbackIsBoundedAndNeverExecuted(t *testing.T) {
	f := newClosedFixture(t)
	if err := os.WriteFile(filepath.Join(f.r.root, ".bash_history"), []byte("echo older\ntouch never-executed\n"), 0600); err != nil {
		t.Fatal(err)
	}
	prepared := closedResult(t, f.r.Route(closeRequest("close.prepare")))
	snapshot, _ := f.r.readClosedTerminal(closeOperation)
	if prepared.HistoryProvenance != "persistedFallback" || !strings.Contains(string(snapshot.History), "touch never-executed") {
		t.Fatal("persisted native history fallback missing")
	}
	closedResult(t, f.r.Route(closeRequest("close.commit")))
	closedResult(t, f.r.Route(closeRequest("close.reopen")))
	if strings.Contains(strings.Join(f.spawnArguments, " "), "never-executed") {
		t.Fatal("archived history entered executable arguments")
	}
}
