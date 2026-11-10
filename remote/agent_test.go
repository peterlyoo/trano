package main

import (
	"errors"
	"testing"
)

// Implements: FR-REMOTE-RECOVERY-2
func TestHookAncestryRejectsEarlyChildAndUnrelatedProcess(t *testing.T) {
	records := map[int]processRecord{100: {parent: 1, image: "/bin/claude"}, 101: {parent: 100, image: "/bin/sh"}, 102: {parent: 101, image: "/bin/claude"}, 103: {parent: 102, image: "/bin/sh"}, 104: {parent: 1, image: "/bin/sh"}}
	lookup := func(pid int) (processRecord, error) {
		v, ok := records[pid]
		if !ok {
			return v, errors.New("missing")
		}
		return v, nil
	}
	if !rootHook(101, 100, lookup) {
		t.Fatal("root hook was rejected")
	}
	if rootHook(103, 100, lookup) {
		t.Fatal("early SDK child adopted parent mapping")
	}
	if rootHook(104, 100, lookup) {
		t.Fatal("unrelated hook accepted")
	}
}

// Implements: FR-REMOTE-RECOVERY-2
func TestHookAncestryChecksNativeChildBehindNodeLauncher(t *testing.T) {
	records := map[int]processRecord{100: {parent: 1, image: "/usr/bin/node"}, 101: {parent: 100, image: "/opt/codex"}, 102: {parent: 101, image: "/bin/sh"}, 103: {parent: 101, image: "/opt/codex"}, 104: {parent: 103, image: "/bin/sh"}}
	lookup := func(pid int) (processRecord, error) {
		v, ok := records[pid]
		if !ok {
			return v, errors.New("missing")
		}
		return v, nil
	}
	if !rootHook(102, 100, lookup) {
		t.Fatal("root native child behind launcher rejected")
	}
	if rootHook(104, 100, lookup) {
		t.Fatal("SDK native child behind launcher accepted")
	}
}

// Implements: FR-REMOTE-RECOVERY-2
func TestInteractiveClassificationPreservesOptionValues(t *testing.T) {
	if !interactive("codex", []string{"--model", "review", "resume", "11111111-1111-4111-8111-111111111111"}) {
		t.Fatal("option value treated as subcommand")
	}
	if interactive("codex", []string{"--model", "test", "exec", "review"}) {
		t.Fatal("noninteractive exec tracked")
	}
	if interactive("claude", []string{"-p", "hello"}) {
		t.Fatal("print mode tracked")
	}
	if !interactive("claude", []string{"--resume", "11111111-1111-4111-8111-111111111111"}) {
		t.Fatal("resume not tracked")
	}
}
