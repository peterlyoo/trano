package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

var errClosedProcessMissing = errors.New("closed terminal process is absent")

type closedProcessWitness struct {
	PID    int    `json:"pid"`
	Birth  uint64 `json:"birth"`
	BootID string `json:"bootID"`
}

type closedProcess struct {
	PID         int
	Generation  string
	Cwd         string
	Shell       string
	OperationID string
	Witnesses   []closedProcessWitness
}

type closedProcessController interface {
	Observe(*Runtime, string) (closedProcess, error)
	Stop([]closedProcessWitness) error
	CheckStopped([]closedProcessWitness) error
}

type nativeClosedProcesses struct{}

func (r *Runtime) closedController() closedProcessController {
	if r.closedProcesses != nil {
		return r.closedProcesses
	}
	return nativeClosedProcesses{}
}

func closedShellPath(path string) bool {
	if !filepath.IsAbs(path) || strings.ContainsAny(path, "\x00\r\n") {
		return false
	}
	switch filepath.Base(path) {
	case "bash", "zsh", "fish", "sh", "dash", "ksh":
		return true
	}
	return false
}

func closedProcessGeneration(process programProcess) string {
	return strconv.Itoa(process.pid) + ":" + strconv.FormatUint(process.started, 10) + ":" + strconv.FormatInt(process.tty, 10) + ":" + strconv.Itoa(process.group)
}

func (nativeClosedProcesses) Observe(r *Runtime, id string) (closedProcess, error) {
	if !validID.MatchString(id) {
		return closedProcess{}, errors.New("invalid closed terminal process ID")
	}
	output, err := r.command("display-message", "-p", "-t", id+":0.0", "#{pane_pid}\n#{pane_dead}\n#{pane_current_path}")
	if err != nil {
		if missingServer(output) || strings.Contains(output, "can't find session") || strings.Contains(output, "can't find pane") || strings.Contains(output, "can't find window") {
			return closedProcess{}, errClosedProcessMissing
		}
		return closedProcess{}, errors.New("could not verify remote terminal process")
	}
	fields := strings.SplitN(strings.TrimSuffix(output, "\n"), "\n", 3)
	if len(fields) != 3 {
		return closedProcess{}, errors.New("invalid remote terminal process metadata")
	}
	if fields[1] == "1" {
		return closedProcess{}, errClosedProcessMissing
	}
	pid, err := strconv.Atoi(fields[0])
	if err != nil || pid <= 1 || fields[1] != "0" || !validDirectory(fields[2]) {
		return closedProcess{}, errors.New("invalid remote terminal process metadata")
	}
	probe := newProgramProbe("/proc", uint32(os.Getuid()))
	process, ok := probe.process(pid)
	if !ok {
		return closedProcess{}, errors.New("remote terminal process identity is unavailable")
	}
	boot := bootIdentity()
	if !validID.MatchString(boot) {
		return closedProcess{}, errors.New("remote boot identity is unavailable")
	}
	result := closedProcess{PID: pid, Cwd: fields[2], Shell: process.image, Generation: closedProcessGeneration(process)}
	if selection, err := r.readClosedShellSelection(id); err == nil && selection.PID == pid && selection.Generation == result.Generation && selection.BootID == boot && closedShellPath(selection.Shell) {
		result.Shell = selection.Shell
	}
	if value, err := r.command("show-environment", "-t", id, "TRANO_CLOSED_OPERATION"); err == nil {
		if operation := strings.TrimPrefix(strings.TrimSpace(value), "TRANO_CLOSED_OPERATION="); validID.MatchString(operation) {
			result.OperationID = operation
		}
	}
	queue := []int{pid}
	seen := map[int]bool{}
	for len(queue) > 0 {
		current := queue[0]
		queue = queue[1:]
		if seen[current] {
			continue
		}
		seen[current] = true
		if len(seen) > 1024 {
			return closedProcess{}, errors.New("remote terminal process tree exceeds the safe close bound")
		}
		record, ok := probe.process(current)
		if !ok {
			if _, err := os.Stat(filepath.Join("/proc", strconv.Itoa(current))); os.IsNotExist(err) {
				continue
			}
			return closedProcess{}, errors.New("remote terminal descendant identity is unavailable")
		}
		result.Witnesses = append(result.Witnesses, closedProcessWitness{PID: current, Birth: record.started, BootID: boot})
		data, ok := readProgramFile(filepath.Join("/proc", strconv.Itoa(current), "task", strconv.Itoa(current), "children"), 64*1024)
		if !ok {
			return closedProcess{}, errors.New("remote terminal descendants could not be verified")
		}
		for _, field := range strings.Fields(string(data)) {
			child, err := strconv.Atoi(field)
			if err != nil || child <= 1 {
				return closedProcess{}, errors.New("invalid remote terminal descendant")
			}
			childRecord, ok := probe.process(child)
			if ok && childRecord.parent == current {
				queue = append(queue, child)
			}
		}
	}
	current, ok := probe.process(pid)
	if !ok || current.started != process.started || current.tty != process.tty || current.group != process.group {
		return closedProcess{}, errors.New("remote terminal generation changed during inspection")
	}
	return result, nil
}

func nativeClosedProcessAlive(witness closedProcessWitness) (bool, error) {
	if witness.PID <= 1 || witness.Birth == 0 || !validID.MatchString(witness.BootID) {
		return false, errors.New("invalid captured remote process witness")
	}
	boot := bootIdentity()
	if !validID.MatchString(boot) {
		return false, errors.New("remote boot identity is unavailable")
	}
	if boot != witness.BootID {
		return false, nil
	}
	probe := newProgramProbe("/proc", uint32(os.Getuid()))
	if process, ok := probe.process(witness.PID); ok {
		return process.started == witness.Birth, nil
	}
	path := filepath.Join("/proc", strconv.Itoa(witness.PID))
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return false, nil
	}
	data, ok := readProgramFile(filepath.Join(path, "stat"), 8192)
	if ok {
		end := strings.LastIndexByte(string(data), ')')
		if end > 0 {
			fields := strings.Fields(string(data)[end+1:])
			if len(fields) > 19 {
				birth, err := strconv.ParseUint(fields[19], 10, 64)
				if err == nil && birth != witness.Birth {
					return false, nil
				}
				if err == nil && birth == witness.Birth && (fields[0] == "Z" || fields[0] == "X") {
					return false, nil
				}
			}
		}
	}
	return false, errors.New("captured remote process exit cannot be verified")
}

func (nativeClosedProcesses) Stop(witnesses []closedProcessWitness) error {
	for index := len(witnesses) - 1; index >= 0; index-- {
		witness := witnesses[index]
		alive, err := nativeClosedProcessAlive(witness)
		if err != nil {
			return err
		}
		if alive {
			if err := syscall.Kill(witness.PID, syscall.SIGKILL); err != nil && err != syscall.ESRCH {
				return errors.New("captured remote process could not be stopped")
			}
		}
	}
	deadline := time.Now().Add(2 * time.Second)
	for {
		err := (nativeClosedProcesses{}).CheckStopped(witnesses)
		if err == nil || time.Now().After(deadline) {
			return err
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func (nativeClosedProcesses) CheckStopped(witnesses []closedProcessWitness) error {
	for _, witness := range witnesses {
		alive, err := nativeClosedProcessAlive(witness)
		if err != nil {
			return err
		}
		if alive {
			return fmt.Errorf("remote process %d is still stopping; retry this close operation", witness.PID)
		}
	}
	return nil
}
