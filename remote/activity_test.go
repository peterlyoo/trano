package main

import (
	"encoding/base64"
	"testing"
)

// Implements: FR-REMOTE-1, FR-ACTIVITY-1
func TestActivityScannerCrossChunkAndChildIsolation(t *testing.T) {
	scanner := activityScanner{}
	frame := "\x1b]7501;state=blocked:app=claude:msg=" + base64.StdEncoding.EncodeToString([]byte("승인 필요")) + "\x1b\\"
	var reports []activityReport
	for _, value := range []byte(frame) {
		reports = append(reports, scanner.feed([]byte{value})...)
	}
	if len(reports) != 1 || reports[0].state != "blocked" || reports[0].reason != "승인 필요" {
		t.Fatalf("bad report: %#v", reports)
	}
	if len(scanner.feed([]byte("\x1b]7501;state=done:app=codex:id=child\a"))) != 1 {
		t.Fatal("child activity was discarded")
	}
	reports = scanner.feed([]byte("\x1b]7501;state=working:app=codex\a"))
	if len(reports) != 1 || reports[0].state != "running" {
		t.Fatal("working state mapping failed")
	}
}
