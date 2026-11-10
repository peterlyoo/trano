package main

import (
	"strings"
	"unicode/utf8"
)

const maxAgentTasks = 64

func validTaskToken(value string, limit int) bool {
	if value == "" || len(value) > limit {
		return false
	}
	for _, c := range value {
		if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_' || c == '.' || c == '-') {
			return false
		}
	}
	return true
}

func validTaskID(value string) bool {
	if len(value) > 128 {
		return false
	}
	parts := strings.Split(value, "/")
	if len(parts) > 8 {
		return false
	}
	for _, part := range parts {
		if part == "." || part == ".." || !validTaskToken(part, 64) {
			return false
		}
	}
	return true
}

func validTaskName(value string) bool {
	if len(value) > 128 || !utf8.ValidString(value) {
		return false
	}
	for _, c := range value {
		if c <= 31 || c >= 127 && c <= 159 {
			return false
		}
	}
	return true
}

func removeAgentTask(session *Session, id string) bool {
	removed := map[string]bool{id: true}
	for changed := true; changed; {
		changed = false
		for _, task := range session.AgentTasks {
			if !removed[task.ID] && (strings.HasPrefix(task.ID, id+"/") || removed[task.ParentID]) {
				removed[task.ID], changed = true, true
			}
		}
	}
	kept := session.AgentTasks[:0]
	for _, task := range session.AgentTasks {
		if !removed[task.ID] {
			kept = append(kept, task)
		}
	}
	changed := len(kept) != len(session.AgentTasks)
	session.AgentTasks = kept
	return changed
}

func applyAgentTask(session *Session, report activityReport, source, generation string) bool {
	if report.clears {
		return removeAgentTask(session, report.taskID)
	}
	index := -1
	for i := range session.AgentTasks {
		if session.AgentTasks[i].ID == report.taskID {
			index = i
			break
		}
	}
	parent := report.parentID
	name := report.taskName
	if index >= 0 {
		if parent == "" {
			parent = session.AgentTasks[index].ParentID
		}
		if name == "" {
			name = session.AgentTasks[index].Name
		}
	}
	seen := map[string]bool{report.taskID: true}
	for current := parent; current != ""; {
		if seen[current] {
			return false
		}
		seen[current] = true
		next := ""
		for _, task := range session.AgentTasks {
			if task.ID == current {
				next = task.ParentID
				break
			}
		}
		current = next
	}
	if name == "" {
		parts := strings.Split(report.taskID, "/")
		name = parts[len(parts)-1]
	}
	task := AgentTask{ID: report.taskID, ParentID: parent, Name: name, Agent: report.agent, Generation: generation,
		Activity: Activity{State: report.state, Reason: report.reason, Source: source, UpdatedAt: now()}}
	if index >= 0 {
		session.AgentTasks[index] = task
		return true
	}
	if len(session.AgentTasks) >= maxAgentTasks {
		oldest := -1
		for i, candidate := range session.AgentTasks {
			if candidate.Activity.State != "running" && candidate.Activity.State != "blocked" && (oldest < 0 || candidate.Activity.UpdatedAt < session.AgentTasks[oldest].Activity.UpdatedAt) {
				oldest = i
			}
		}
		if oldest < 0 {
			return false
		}
		session.AgentTasks = append(session.AgentTasks[:oldest], session.AgentTasks[oldest+1:]...)
	}
	session.AgentTasks = append(session.AgentTasks, task)
	return true
}
