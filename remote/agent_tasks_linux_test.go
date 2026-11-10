package main

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
)

func childHookPayload(t *testing.T, event, child string) []byte {
	t.Helper()
	data, err := json.Marshal(map[string]any{"session_id": taskConversation, "cwd": "/child-directory", "hook_event_name": event, "agent_id": child, "agent_type": "Explore", "prompt": "must-not-save-prompt", "last_assistant_message": "must-not-save-message", "agent_transcript_path": "/not-readable"})
	if err != nil {
		t.Fatal(err)
	}
	return data
}

// Implements: FR-HOVER-3, FR-HOVER-4
func TestLinuxChildHooksPreserveRootConversationAndRecovery(t *testing.T) {
	for _, provider := range []string{"claude", "codex"} {
		t.Run(provider, func(t *testing.T) {
			r := taskRuntime(t, provider)
			before, _ := r.load()
			for _, transition := range []struct{ event, state string }{{"SubagentStart", "running"}, {"SubagentStop", "done"}} {
				if err := r.RecordHook(provider, taskPaneID, taskGeneration, childHookPayload(t, transition.event, "agent-one"), os.Getpid()); err != nil {
					t.Fatal(err)
				}
				tasks := taskViews(t, r)
				if len(tasks) != 1 || tasks[0].ID != "agent-one" || tasks[0].Name != "Explore" || tasks[0].Agent != provider || tasks[0].Activity.State != transition.state || tasks[0].Activity.Source != "hook" || tasks[0].ParentID != nil || tasks[0].Generation == nil || *tasks[0].Generation != taskGeneration {
					t.Fatalf("wrong hook child: %#v", tasks)
				}
			}
			after, _ := r.load()
			if after.Sessions[0].Activity != before.Sessions[0].Activity || after.Sessions[0].Cwd != before.Sessions[0].Cwd || !reflect.DeepEqual(after.AgentLaunches, before.AgentLaunches) || !reflect.DeepEqual(after.Recovery, before.Recovery) {
				t.Fatal("child hook mutated root state")
			}
		})
	}
}

// Implements: FR-HOVER-3
func TestLinuxClaudeChildOperationalHooks(t *testing.T) {
	r := taskRuntime(t, "claude")
	for _, transition := range []struct{ event, state string }{{"PreToolUse", "running"}, {"PermissionRequest", "blocked"}, {"PostToolUse", "running"}, {"PostToolUseFailure", "error"}, {"StopFailure", "error"}, {"Stop", "done"}} {
		if err := r.RecordHook("claude", taskPaneID, taskGeneration, childHookPayload(t, transition.event, "worker"), os.Getpid()); err != nil {
			t.Fatal(err)
		}
		tasks := taskViews(t, r)
		if len(tasks) != 1 || tasks[0].Activity.State != transition.state {
			t.Fatalf("%s did not update child: %#v", transition.event, tasks)
		}
	}
}

// Implements: FR-HOVER-3
func TestLinuxChildHooksRejectUnboundStaleAndSessionEvents(t *testing.T) {
	r := taskRuntime(t, "claude")
	if err := r.RecordHook("claude", taskPaneID, "stale", childHookPayload(t, "SubagentStart", "stale"), os.Getpid()); err != nil {
		t.Fatal(err)
	}
	for _, event := range []string{"SessionStart", "SessionEnd"} {
		if err := r.RecordHook("claude", taskPaneID, taskGeneration, childHookPayload(t, event, "child"), os.Getpid()); err != nil {
			t.Fatal(err)
		}
	}
	state, _ := r.load()
	state.AgentLaunches[0].ProviderSessionID = ""
	if err := r.save(state); err != nil {
		t.Fatal(err)
	}
	if err := r.RecordHook("claude", taskPaneID, taskGeneration, childHookPayload(t, "SubagentStart", "unbound"), os.Getpid()); err != nil {
		t.Fatal(err)
	}
	if len(taskViews(t, r)) != 0 {
		t.Fatal("untrusted child event accepted")
	}
	state, _ = r.load()
	if state.AgentLaunches[0].ProviderSessionID != "" {
		t.Fatal("child adopted root conversation identity")
	}
}

// Implements: FR-HOVER-3, FR-HOVER-4
func TestLinuxRootSessionReplacementClearsChildren(t *testing.T) {
	r := taskRuntime(t, "claude")
	reportTaskOSC(t, r, "state=running:app=claude:id=old")
	data, _ := json.Marshal(map[string]string{"session_id": "dddddddd-dddd-4ddd-8ddd-dddddddddddd", "cwd": r.root, "hook_event_name": "SessionStart", "source": "clear"})
	if err := r.RecordHook("claude", taskPaneID, taskGeneration, data, os.Getpid()); err != nil {
		t.Fatal(err)
	}
	if len(taskViews(t, r)) != 0 {
		t.Fatal("root replacement kept children")
	}
}
