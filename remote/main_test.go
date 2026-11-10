package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Implements: FR-REMOTE-1
func TestDurableRemoteSessionWithQuotedDirectory(t *testing.T) {
	root, err := os.MkdirTemp("/tmp", "at-remote-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(root)
	t.Setenv("SHELL", "/bin/sh")
	t.Setenv("HOME", root)
	runtime, err := NewRuntime(root)
	if err != nil {
		t.Fatal(err)
	}
	directory := filepath.Join(root, "한글 'directory';")
	if err := os.Mkdir(directory, 0700); err != nil {
		t.Fatal(err)
	}
	session, err := runtime.Create("remote test", directory)
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Terminate(session.ID)
	if err := runtime.Send(session.ID, "sleep 0.1; printf '\\nREMOTE_PERSIST_OK\\n'", true); err != nil {
		t.Fatal(err)
	}
	if err := runtime.Send(session.ID, "read -r literal; printf '%s' \"$literal\" > received", true); err != nil {
		t.Fatal(err)
	}
	time.Sleep(200 * time.Millisecond)
	if err := runtime.Send(session.ID, "literal\\;", true); err != nil {
		t.Fatal(err)
	}
	for attempt := 0; attempt < 50; attempt++ {
		data, err := os.ReadFile(filepath.Join(directory, "received"))
		if err == nil {
			if string(data) != "literal\\;" {
				t.Fatalf("literal altered: %q", data)
			}
			break
		}
		if attempt == 49 {
			captured, _ := runtime.Capture(session.ID, 100)
			t.Fatalf("%v\n%s", err, captured)
		}
		time.Sleep(20 * time.Millisecond)
	}
	restored, err := NewRuntime(root)
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	output := ""
	for time.Now().Before(deadline) {
		output, err = restored.Capture(session.ID, 100)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(output, "\nREMOTE_PERSIST_OK\n") {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !strings.Contains(output, "\nREMOTE_PERSIST_OK\n") {
		t.Fatalf("missing detached output: %s", output)
	}
	sessions, err := restored.List()
	if err != nil || len(sessions) != 1 || sessions[0].PID != session.PID {
		t.Fatalf("session identity lost: %#v %v", sessions, err)
	}
	if err := restored.Terminate(";kill-server"); err == nil {
		t.Fatal("invalid ID accepted")
	}
	if _, err := restored.Capture(session.ID, 10001); err == nil {
		t.Fatal("capture bound ignored")
	}
	if err := restored.Send(session.ID, strings.Repeat("x", 65537), false); err == nil {
		t.Fatal("input bound ignored")
	}
	mode, _ := os.Stat(root)
	if mode.Mode().Perm() != 0700 {
		t.Fatal("private directory permissions missing")
	}
}

// Implements: FR-REMOTE-1, FR-REMOTE-3
func TestRefusesUnmanagedDirectoryAndBadRPCVersion(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "keep"), []byte("user data"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := NewRuntime(root); err == nil {
		t.Fatal("unmanaged directory adopted")
	}
	clean, _ := os.MkdirTemp("/tmp", "at-rpc-")
	defer os.RemoveAll(clean)
	runtime, err := NewRuntime(clean)
	if err != nil {
		t.Fatal(err)
	}
	response := runtime.Route(Request{APIVersion: 99, Method: "health"})
	if response.Error == "" {
		t.Fatal("invalid API version accepted")
	}
}
