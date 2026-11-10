package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Implements: FR-RECOVERY-SCROLLBACK-1
func TestScrollbackBoundedSafeAndDisableRemovesArchive(t *testing.T) {
	r := recoveryRuntime(t)
	pane, err := r.Create("history", r.root)
	if err != nil {
		t.Fatal(err)
	}
	text := strings.Repeat("한글 line\n", 12000) + "끝\x1b]52;c;clipboard\a\u009b31m\n"
	if err := r.SaveScrollback(pane.ID, text); err != nil {
		t.Fatal(err)
	}
	replay, err := r.ReplayScrollback(pane.ID)
	if err != nil || !strings.Contains(replay, "끝") || strings.ContainsAny(replay, "\x1b\a\u009b") || len(strings.Split(replay, "\n")) > 10000 {
		t.Fatalf("unsafe or unbounded replay: %v", err)
	}
	info, err := r.ScrollbackMetadata(pane.ID)
	if err != nil || info == nil || info.ByteCount != len(replay) || info.LineCount > 10000 {
		t.Fatalf("bad metadata: %#v %v", info, err)
	}
	if err := r.SetScrollback(false); err != nil {
		t.Fatal(err)
	}
	if err := r.SaveScrollback(pane.ID, "disabled"); err != nil {
		t.Fatal(err)
	}
	if replay, _ := r.ReplayScrollback(pane.ID); replay != "" {
		t.Fatal("disabled archive replayed")
	}
	if _, err := os.Stat(filepath.Join(r.root, "scrollback", pane.ID+".snapshot")); !os.IsNotExist(err) {
		t.Fatal("disable retained archive")
	}
}

// Implements: FR-RECOVERY-SCROLLBACK-1
func TestScrollbackRejectsSymlinkAndSanitizesOnRead(t *testing.T) {
	r := recoveryRuntime(t)
	pane, err := r.Create("history", r.root)
	if err != nil {
		t.Fatal(err)
	}
	if err := r.SaveScrollback(pane.ID, "abc"); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(r.root, "scrollback", pane.ID+".snapshot")
	data, _ := os.ReadFile(path)
	copy(data[len(data)-3:], []byte{27, '[', 'm'})
	_ = os.WriteFile(path, data, 0600)
	if text, err := r.ReplayScrollback(pane.ID); err != nil || text != "[m" {
		t.Fatalf("unsafe replay %q %v", text, err)
	}
	_ = os.Remove(path)
	_ = os.Symlink(filepath.Join(r.root, "private"), path)
	if _, err := r.ReplayScrollback(pane.ID); err == nil {
		t.Fatal("symlink followed")
	}
}

// Implements: FR-RECOVERY-SCROLLBACK-1
func TestScrollbackRejectsStaleCollectorAndBoundsInvalidUTF8(t *testing.T) {
	r := recoveryRuntime(t)
	pane, err := r.Create("history", r.root)
	if err != nil {
		t.Fatal(err)
	}
	if err := r.SaveScrollback(pane.ID, "kept"); err != nil {
		t.Fatal(err)
	}
	if _, err := r.command("respawn-pane", "-k", "-t", pane.ID+":0.0", "/bin/sh"); err != nil {
		t.Fatal(err)
	}
	if err := r.saveScrollback(pane.ID, "stale", pane.PID); err != nil {
		t.Fatal(err)
	}
	if text, _ := r.ReplayScrollback(pane.ID); text != "kept" {
		t.Fatal("stale collector overwrote archive")
	}
	text := sanitizeSnapshot(strings.Repeat("\xff", snapshotBytes))
	if len(text) > snapshotBytes {
		t.Fatal("invalid UTF-8 expanded archive past byte limit")
	}
}
