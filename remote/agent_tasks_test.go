package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

const taskPaneID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
const taskGeneration = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
const taskConversation = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

type taskView struct {
	ID, Name, Agent      string
	ParentID, Generation *string
	Activity             Activity
}

func taskRuntime(t *testing.T, provider string) *Runtime {
	t.Helper()
	r := recoveryRuntime(t)
	state := State{SchemaVersion: 1, Sessions: []Session{{ID: taskPaneID, Cwd: r.root, Agent: provider, Alive: true, Activity: Activity{State: "running", Source: "hook", UpdatedAt: 1}}}}
	if provider != "shell" {
		state.AgentLaunches = []AgentLaunch{{ID: taskGeneration, SessionID: taskPaneID, Provider: provider, ProviderSessionID: taskConversation, ProviderPID: os.Getpid(), Cwd: r.root, Lifecycle: "active", UpdatedAt: 1}}
		state.Recovery = []RecoveryResult{{SessionID: taskPaneID, Status: "restoring", Message: "unchanged", UpdatedAt: 1}}
	}
	if err := r.save(state); err != nil {
		t.Fatal(err)
	}
	return r
}

func taskViews(t *testing.T, r *Runtime) []taskView {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(r.root, "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	var state struct {
		Sessions []struct{ AgentTasks []taskView }
	}
	if err := json.Unmarshal(data, &state); err != nil {
		t.Fatal(err)
	}
	return state.Sessions[0].AgentTasks
}

func reportTaskOSC(t *testing.T, r *Runtime, fields string) {
	t.Helper()
	report, ok := parseActivity("7501;" + fields)
	if !ok {
		t.Fatalf("child report rejected: %s", fields)
	}
	if err := r.Report(taskPaneID, report, "osc7501"); err != nil {
		t.Fatal(err)
	}
}

// Implements: FR-HOVER-3, FR-HOVER-4
func TestOSCChildrenPreserveRootAndCurrentGeneration(t *testing.T) {
	r := taskRuntime(t, "claude")
	before, _ := r.load()
	for _, status := range []string{"running", "blocked", "done"} {
		reportTaskOSC(t, r, "state="+status+":app=codex:id=review/tests:name=Tests")
		tasks := taskViews(t, r)
		if len(tasks) != 1 || tasks[0].ID != "review/tests" || tasks[0].Name != "Tests" || tasks[0].Agent != "codex" || tasks[0].Activity.State != status || tasks[0].Activity.Source != "osc7501" || tasks[0].Activity.UpdatedAt <= 1 {
			t.Fatalf("wrong child status: %#v", tasks)
		}
		if tasks[0].ParentID == nil || *tasks[0].ParentID != "review" || tasks[0].Generation == nil || *tasks[0].Generation != taskGeneration {
			t.Fatalf("missing child identity: %#v", tasks[0])
		}
	}
	after, _ := r.load()
	if after.Sessions[0].Agent != before.Sessions[0].Agent || after.Sessions[0].Activity != before.Sessions[0].Activity || after.Sessions[0].Cwd != before.Sessions[0].Cwd || !reflect.DeepEqual(after.AgentLaunches, before.AgentLaunches) || !reflect.DeepEqual(after.Recovery, before.Recovery) {
		t.Fatal("child changed root activity, conversation, working directory, or recovery")
	}
}

// Implements: FR-HOVER-3
func TestOSCChildrenRejectStaleGenerationAndClearSubtree(t *testing.T) {
	r := taskRuntime(t, "claude")
	reportTaskOSC(t, r, "state=running:app=claude:id=stale:generation=old")
	if len(taskViews(t, r)) != 0 {
		t.Fatal("stale generation accepted")
	}
	for _, fields := range []string{"id=review", "id=review/tests", "id=detached:parent=review", "id=kept"} {
		reportTaskOSC(t, r, "state=running:app=claude:"+fields)
	}
	reportTaskOSC(t, r, "state=clear:id=review")
	tasks := taskViews(t, r)
	if len(tasks) != 1 || tasks[0].ID != "kept" {
		t.Fatalf("child clear did not isolate subtree: %#v", tasks)
	}
	reportTaskOSC(t, r, "state=clear")
	if len(taskViews(t, r)) != 0 {
		t.Fatal("root clear retained children")
	}
}

// Implements: FR-HOVER-3
func TestOSCChildrenBoundStorageAndPreserveActiveTasks(t *testing.T) {
	r := taskRuntime(t, "shell")
	for i := 0; i < 64; i++ {
		reportTaskOSC(t, r, fmt.Sprintf("state=running:id=child-%02d", i))
	}
	reportTaskOSC(t, r, "state=running:id=overflow")
	if tasks := taskViews(t, r); len(tasks) != 64 || tasks[0].ID != "child-00" {
		t.Fatalf("active tasks evicted: %#v", tasks)
	}
	reportTaskOSC(t, r, "state=done:id=child-17")
	reportTaskOSC(t, r, "state=running:id=next")
	tasks := taskViews(t, r)
	if len(tasks) != 64 || tasks[len(tasks)-1].ID != "next" {
		t.Fatal("terminal task not replaced")
	}
	for _, task := range tasks {
		if task.ID == "child-17" {
			t.Fatal("terminal task retained at capacity")
		}
	}
}

// Implements: FR-HOVER-3, FR-HOVER-4
func TestOSCChildValidationAndLegacySessionRoundTrip(t *testing.T) {
	for _, fields := range []string{"state=running:id=", "state=running:id=/child", "state=running:id=child/", "state=running:id=parent//child", "state=running:id=" + strings.Repeat("x", 257), "state=running:id=child:parent=child", "state=running:id=child:name=" + strings.Repeat("x", 129)} {
		if _, ok := parseActivity("7501;" + fields); ok {
			t.Fatalf("invalid child metadata accepted: %s", fields)
		}
	}
	var old Session
	if err := json.Unmarshal([]byte(`{"id":"legacy","agent":"shell","activity":{"state":"idle"}}`), &old); err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(old)
	if err != nil || strings.Contains(string(encoded), "agentTasks") {
		t.Fatalf("legacy session gained child metadata: %s %v", encoded, err)
	}
}

// Implements: FR-HOVER-3
func TestOSCUnknownChildStatePreservesRootAndIdentity(t *testing.T) {
	r := taskRuntime(t, "codex")
	before, _ := r.load()
	reportTaskOSC(t, r, "id=worker:app=codex:state=running")
	report, ok := parseActivity("7501;id=worker:app=codex:state=unknown")
	if !ok {
		t.Fatal("identified unknown child state rejected")
	}
	if err := r.Report(taskPaneID, report, "osc7501"); err != nil {
		t.Fatal(err)
	}
	tasks := taskViews(t, r)
	if len(tasks) != 1 || tasks[0].ID != "worker" || tasks[0].Activity.State != "unknown" {
		t.Fatalf("wrong child: %#v", tasks)
	}
	after, _ := r.load()
	if !reflect.DeepEqual(before.AgentLaunches, after.AgentLaunches) || before.Sessions[0].Activity != after.Sessions[0].Activity {
		t.Fatal("unknown child changed root")
	}
	if _, ok := parseActivity("7501;state=unknown"); ok {
		t.Fatal("unidentified unknown root accepted")
	}
}

// Implements: FR-HOVER-3
func TestOSCChildCannotCreateParentCycle(t *testing.T) {
	r := taskRuntime(t, "shell")
	reportTaskOSC(t, r, "state=running:id=parent")
	reportTaskOSC(t, r, "state=running:id=child:parent=parent")
	reportTaskOSC(t, r, "state=blocked:id=parent:parent=child")
	tasks := taskViews(t, r)
	if len(tasks) != 2 || tasks[0].ParentID != nil || tasks[0].Activity.State != "running" {
		t.Fatalf("cycle accepted: %#v", tasks)
	}
}

// Implements: FR-HOVER-3
func TestProviderIntegrationRegistersChildLifecycleHooks(t *testing.T) {
	r := taskRuntime(t, "shell")
	for _, provider := range []string{"claude", "codex"} {
		args, err := r.withHooks(provider, nil)
		if err != nil {
			t.Fatal(err)
		}
		text := strings.Join(args, " ")
		if provider == "claude" {
			data, err := os.ReadFile(filepath.Join(r.root, "integration", "claude", "hooks", "hooks.json"))
			if err != nil {
				t.Fatal(err)
			}
			text = string(data)
		}
		for _, event := range []string{"SubagentStart", "SubagentStop"} {
			if !strings.Contains(text, event) {
				t.Fatalf("%s lacks %s", provider, event)
			}
		}
	}
}
