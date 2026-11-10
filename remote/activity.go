package main

import (
	"encoding/base64"
	"errors"
	"strings"
	"unicode/utf8"
)

type activityReport struct {
	state, agent, reason                   string
	taskID, parentID, taskName, generation string
	clears                                 bool
}
type activityScanner struct {
	phase     int
	payload   []byte
	discarded bool
}

func (s *activityScanner) feed(data []byte) []activityReport {
	reports := []activityReport{}
	finish := func() {
		if !s.discarded {
			if report, ok := parseActivity(string(s.payload)); ok {
				reports = append(reports, report)
			}
		}
		s.phase = 0
	}
	for _, b := range data {
		switch s.phase {
		case 0:
			if b == 27 {
				s.phase = 1
			}
		case 1:
			if b == ']' {
				s.phase = 2
				s.payload = s.payload[:0]
				s.discarded = false
			} else if b != 27 {
				s.phase = 0
			}
		case 2:
			if b == 7 {
				finish()
			} else if b == 27 {
				s.phase = 3
			} else if len(s.payload) < 4096 {
				s.payload = append(s.payload, b)
			} else {
				s.discarded = true
			}
		case 3:
			if b == '\\' {
				finish()
			} else if b == ']' {
				s.phase = 2
				s.payload = s.payload[:0]
				s.discarded = false
			} else if b == 27 {
				s.phase = 1
			} else {
				s.phase = 0
			}
		}
	}
	return reports
}

func parseActivity(raw string) (activityReport, bool) {
	report := activityReport{agent: "shell"}
	if raw == "133;A" || strings.HasPrefix(raw, "133;A;") {
		report.state = "idle"
		report.clears = true
		return report, true
	}
	if !strings.HasPrefix(raw, "7501;") || len(raw) > 4092 {
		return report, false
	}
	fields := map[string]string{}
	for _, field := range strings.Split(raw[5:], ":") {
		pair := strings.SplitN(field, "=", 2)
		if len(pair) != 2 {
			continue
		}
		key, value := strings.TrimSpace(pair[0]), strings.TrimSpace(pair[1])
		if len(key) > 16 {
			return report, false
		}
		for _, c := range value {
			if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || strings.ContainsRune("_.,+/=-", c)) {
				return report, false
			}
		}
		fields[key] = value
	}
	if id, child := fields["id"]; child {
		if !validTaskID(id) {
			return report, false
		}
		report.taskID, report.parentID, report.taskName, report.generation = id, fields["parent"], fields["name"], fields["generation"]
		if _, present := fields["parent"]; present {
			if !validTaskID(report.parentID) || report.parentID == id {
				return report, false
			}
		} else if end := strings.LastIndex(id, "/"); end >= 0 {
			report.parentID = id[:end]
		}
		if report.taskName == "" {
			report.taskName = fields["kind"]
		}
		if !validTaskName(report.taskName) || report.generation != "" && !validTaskToken(report.generation, 128) {
			return report, false
		}
	}
	report.state = fields["state"]
	if report.state == "working" {
		report.state = "running"
	}
	if report.state == "clear" {
		report.state = "unknown"
		report.clears = true
		return report, true
	}
	if !validActivity(report.state) || report.state == "unknown" && report.taskID == "" {
		return report, false
	}
	report.reason = fields["kind"]
	if encoded, ok := fields["msg"]; ok && report.taskID == "" {
		if len(encoded) > 2732 {
			return report, false
		}
		encoded += strings.Repeat("=", (4-len(encoded)%4)%4)
		decoded, err := base64.StdEncoding.DecodeString(encoded)
		if err != nil || len(decoded) > 2048 || !utf8.Valid(decoded) {
			return report, false
		}
		report.reason = string(decoded)
		for _, c := range report.reason {
			if c <= 31 || c >= 127 && c <= 159 {
				return report, false
			}
		}
	}
	if len([]rune(report.reason)) > 1000 {
		report.reason = string([]rune(report.reason)[:1000])
	}
	switch strings.ToLower(fields["app"]) {
	case "claude", "claude-code":
		report.agent = "claude"
	case "codex":
		report.agent = "codex"
	}
	return report, true
}

func validActivity(state string) bool {
	switch state {
	case "unknown", "idle", "running", "blocked", "done", "error":
		return true
	}
	return false
}

func (r *Runtime) Report(id string, report activityReport, source string) error {
	if !validActivity(report.state) || len(report.reason) > 4096 || (report.agent != "shell" && report.agent != "claude" && report.agent != "codex") {
		return errors.New("invalid activity")
	}
	file, err := r.lock()
	if err != nil {
		return err
	}
	defer file.Close()
	state, err := r.load()
	if err != nil {
		return err
	}
	if err := require(state, id); err != nil {
		return err
	}
	for index := range state.Sessions {
		session := &state.Sessions[index]
		if session.ID != id {
			continue
		}
		if report.taskID != "" {
			if !validTaskID(report.taskID) || report.parentID != "" && (!validTaskID(report.parentID) || report.parentID == report.taskID) || !validTaskName(report.taskName) {
				return errors.New("invalid child activity")
			}
			generation := ""
			for _, launch := range state.AgentLaunches {
				if launch.SessionID == id && launch.Lifecycle == "active" {
					generation = launch.ID
					break
				}
			}
			if report.generation != "" && report.generation != generation {
				return nil
			}
			if !applyAgentTask(session, report, source, generation) {
				return nil
			}
			return r.save(state)
		}
		clearedChildren := report.clears && len(session.AgentTasks) > 0
		if clearedChildren {
			session.AgentTasks = nil
		}
		if report.clears && session.Activity.State != "running" && session.Activity.State != "blocked" {
			if clearedChildren {
				return r.save(state)
			}
			return nil
		}
		if session.Activity.State == report.state && session.Activity.Reason == report.reason && session.Agent == report.agent {
			return nil
		}
		session.Agent = report.agent
		session.Activity = Activity{State: report.state, Reason: report.reason, Source: source, UpdatedAt: now()}
	}
	return r.save(state)
}

func shellQuote(value string) string { return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'" }
