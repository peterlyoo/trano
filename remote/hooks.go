package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

type processRecord struct {
	parent int
	image  string
}

func linuxProcess(pid int) (processRecord, error) {
	base := "/proc/" + strconv.Itoa(pid)
	stat, err := os.ReadFile(base + "/stat")
	if err != nil {
		return processRecord{}, err
	}
	end := strings.LastIndex(string(stat), ")")
	if end < 0 {
		return processRecord{}, errors.New("invalid process stat")
	}
	fields := strings.Fields(string(stat[end+1:]))
	if len(fields) < 2 {
		return processRecord{}, errors.New("invalid process stat")
	}
	parent, err := strconv.Atoi(fields[1])
	if err != nil {
		return processRecord{}, err
	}
	image, err := os.Readlink(base + "/exe")
	return processRecord{parent: parent, image: image}, err
}
func rootHook(origin, providerPID int, lookup func(int) (processRecord, error)) bool {
	if origin <= 0 || providerPID <= 0 {
		return false
	}
	root, err := lookup(providerPID)
	if err != nil || root.image == "" {
		return false
	}
	current := origin
	seen := map[int]bool{}
	images := map[string]int{}
	for step := 0; step < 64 && current > 1; step++ {
		if seen[current] {
			return false
		}
		seen[current] = true
		item, err := lookup(current)
		if err != nil {
			return false
		}
		base := filepath.Base(item.image)
		shell := base == "sh" || base == "dash" || base == "bash" || base == "zsh" || base == "fish"
		if !shell || item.image == root.image {
			images[item.image]++
			if images[item.image] > 1 {
				return false
			}
		}
		if current == providerPID {
			return true
		}
		current = item.parent
	}
	return false
}
func (r *Runtime) RecordHook(provider, id, generation string, data []byte, origin int) error {
	return r.recordHook(provider, id, generation, data, origin, linuxProcess)
}
func (r *Runtime) recordHook(provider, id, generation string, data []byte, origin int, lookup func(int) (processRecord, error)) error {
	if len(data) > maxFrame {
		return errors.New("hook exceeds 1 MiB")
	}
	var payload map[string]json.RawMessage
	if err := json.Unmarshal(data, &payload); err != nil {
		return err
	}
	text := func(key string) string { var value string; _ = json.Unmarshal(payload[key], &value); return value }
	sessionID, event, cwd := strings.ToLower(text("session_id")), text("hook_event_name"), text("cwd")
	if !validID.MatchString(sessionID) || !filepath.IsAbs(cwd) || strings.ContainsAny(cwd, "\x00\r\n") {
		return nil
	}
	childID, childName := text("agent_id"), text("agent_type")
	rawChild, hasChild := payload["agent_id"]
	hasChild = hasChild && string(rawChild) != "null"
	childEvent := event == "SubagentStart" || event == "SubagentStop"
	if (hasChild || childEvent) && (!validTaskID(childID) || !validTaskName(childName)) {
		return nil
	}
	activity := ""
	if hasChild {
		switch event {
		case "SubagentStart":
			activity = "running"
		case "SubagentStop":
			activity = "done"
		default:
			if provider != "claude" {
				return nil
			}
			switch event {
			case "PreToolUse", "PostToolUse":
				activity = "running"
			case "PermissionRequest":
				activity = "blocked"
			case "PostToolUseFailure", "StopFailure":
				activity = "error"
			case "Stop":
				activity = "done"
			default:
				return nil
			}
		}
	} else {
		switch event {
		case "SessionStart":
			activity = "idle"
		case "UserPromptSubmit", "PreToolUse":
			activity = "running"
		case "PermissionRequest":
			activity = "blocked"
		case "Stop":
			activity = "done"
		case "SessionEnd":
		default:
			return nil
		}
	}
	lock, err := r.lock()
	if err != nil {
		return err
	}
	defer lock.Close()
	state, err := r.load()
	if err != nil {
		return err
	}
	accepted, confirmedStart := false, false
	for i := range state.AgentLaunches {
		launch := &state.AgentLaunches[i]
		if launch.SessionID != id || launch.ID != generation || launch.Provider != provider || launch.Lifecycle != "active" {
			continue
		}
		if !rootHook(origin, launch.ProviderPID, lookup) {
			return nil
		}
		if hasChild {
			if launch.ProviderSessionID == "" || launch.ProviderSessionID != sessionID {
				return nil
			}
			for j := range state.Sessions {
				if state.Sessions[j].ID == id {
					report := activityReport{state: activity, agent: provider, taskID: childID, taskName: childName}
					if applyAgentTask(&state.Sessions[j], report, "hook", generation) {
						return r.save(state)
					}
				}
			}
			return nil
		}
		replace := event == "SessionStart" && (text("source") == "clear" || text("source") == "fork")
		if launch.ProviderSessionID != "" && launch.ProviderSessionID != sessionID && !replace {
			return nil
		}
		if event == "SessionStart" && launch.StartedSessionID == "" {
			confirmedStart = launch.ProviderSessionID == "" || launch.ProviderSessionID == sessionID
			launch.StartedSessionID = sessionID
		}
		launch.ProviderSessionID, launch.Cwd, launch.UpdatedAt = sessionID, cwd, now()
		accepted = true
	}
	if !accepted {
		return nil
	}
	for i := range state.Sessions {
		if state.Sessions[i].ID == id {
			if event == "SessionStart" && (text("source") == "clear" || text("source") == "fork") {
				state.Sessions[i].AgentTasks = nil
			}
			state.Sessions[i].Cwd = cwd
			state.Sessions[i].Agent = provider
			if activity != "" {
				state.Sessions[i].Activity = Activity{State: activity, Source: "hook", UpdatedAt: now()}
			}
		}
	}
	if confirmedStart {
		for i := range state.Recovery {
			if state.Recovery[i].SessionID == id && state.Recovery[i].Status == "restoring" {
				state.Recovery[i].Status = "restored"
				state.Recovery[i].Message = "Remote agent conversation resumed"
				state.Recovery[i].UpdatedAt = now()
			}
		}
	}
	return r.save(state)
}
