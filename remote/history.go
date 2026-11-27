package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
)

type HistoryResponse struct {
	HistoryProtocol int    `json:"historyProtocol"`
	ID              string `json:"id"`
	PID             int    `json:"pid"`
	Matched         bool   `json:"matched"`
	InputReady      bool   `json:"inputReady"`
}

type historyPosition struct {
	pid, mode, position int
	name                string
}

func parseHistoryPosition(report string) (historyPosition, error) {
	if len(report) > 512 {
		return historyPosition{}, errors.New("invalid terminal history metadata")
	}
	fields := strings.Split(strings.TrimRight(report, "\r\n"), "\t")
	if len(fields) != 4 {
		return historyPosition{}, errors.New("invalid terminal history metadata")
	}
	pid, e1 := strconv.Atoi(fields[0])
	mode, e2 := strconv.Atoi(fields[1])
	position := 0
	var e3 error
	if fields[2] != "" || mode != 0 {
		position, e3 = strconv.Atoi(fields[2])
	}
	if e1 != nil || e2 != nil || e3 != nil || pid <= 0 || pid > 2147483647 || (mode != 0 && mode != 1) || position < 0 || strings.ContainsAny(fields[3], "\r\n\x00") {
		return historyPosition{}, errors.New("invalid terminal history metadata")
	}
	return historyPosition{pid, mode, position, fields[3]}, nil
}

func routeTerminalHistory(request Request, run func(string, int, *int) (HistoryResponse, error)) (HistoryResponse, error) {
	for key := range request.Params {
		if key != "id" && key != "expectedPID" && (key != "lines" || request.Method != "panes.history.scroll") {
			return HistoryResponse{}, errors.New("unknown terminal history parameter")
		}
	}
	var id *string
	var pid *int
	if json.Unmarshal(request.Params["id"], &id) != nil || id == nil || !validID.MatchString(*id) {
		return HistoryResponse{}, errors.New("invalid terminal history id")
	}
	if json.Unmarshal(request.Params["expectedPID"], &pid) != nil || pid == nil || *pid <= 0 || *pid > 2147483647 {
		return HistoryResponse{}, errors.New("invalid terminal history expectedPID")
	}
	var lines *int
	if request.Method == "panes.history.scroll" {
		if json.Unmarshal(request.Params["lines"], &lines) != nil || lines == nil || *lines < -1000 || *lines > 1000 {
			return HistoryResponse{}, errors.New("invalid terminal history lines")
		}
	}
	return run(*id, *pid, lines)
}

func (r *Runtime) TerminalHistory(id string, expectedPID int, lines *int) (HistoryResponse, error) {
	result := HistoryResponse{HistoryProtocol: 1, ID: id}
	if !validID.MatchString(id) || expectedPID <= 0 || expectedPID > 2147483647 || (lines != nil && (*lines < -1000 || *lines > 1000)) {
		return result, errors.New("invalid terminal history target")
	}
	file, err := r.lock()
	if err != nil {
		return result, err
	}
	defer file.Close()
	state, err := r.load()
	if err != nil {
		return result, err
	}
	if err := require(state, id); err != nil {
		return result, err
	}
	for _, session := range state.Sessions {
		if session.ID == id {
			result.PID = session.PID
			if session.PID != expectedPID || !session.Alive {
				return result, nil
			}
			break
		}
	}
	execute := func(args ...string) (string, error) { return r.commandLimit(512, args...) }
	if r.historyExecute != nil {
		execute = r.historyExecute
	}
	target := id + ":0.0"
	inspect := func() (historyPosition, error) {
		report, err := execute("display-message", "-p", "-t", target, "#{pane_pid}\t#{pane_in_mode}\t#{scroll_position}\t#{pane_mode}")
		if err != nil {
			return historyPosition{}, err
		}
		return parseHistoryPosition(report)
	}
	before, err := inspect()
	if err != nil {
		return result, err
	}
	result.PID = before.pid
	if before.pid != expectedPID {
		return result, nil
	}
	result.Matched = true
	commands := [][]string{}
	if before.mode == 0 || before.name == "copy-mode" {
		if lines == nil {
			if before.mode == 1 {
				commands = append(commands, []string{"send-keys", "-X", "-t", target, "cancel"})
			}
		} else if *lines > 0 {
			if before.mode == 0 {
				commands = append(commands, []string{"copy-mode", "-t", target})
			}
			commands = append(commands, []string{"send-keys", "-X", "-N", strconv.Itoa(*lines), "-t", target, "scroll-up"})
		} else if *lines < 0 && before.mode == 1 && before.position > 0 {
			if -*lines >= before.position {
				commands = append(commands, []string{"send-keys", "-X", "-t", target, "cancel"})
			} else {
				commands = append(commands, []string{"send-keys", "-X", "-N", strconv.Itoa(-*lines), "-t", target, "scroll-down"})
			}
		}
	}
	for _, command := range commands {
		if _, err := execute(command...); err != nil {
			return result, fmt.Errorf("terminal history command failed: %w", err)
		}
	}
	after := before
	if len(commands) > 0 {
		after, err = inspect()
		if err != nil {
			return result, err
		}
	}
	result.PID = after.pid
	result.Matched = after.pid == expectedPID
	result.InputReady = result.Matched && after.mode == 0
	return result, nil
}
