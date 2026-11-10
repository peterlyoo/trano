package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"
)

const snapshotBytes = 4 * 1024 * 1024
const snapshotLines = 10000
const snapshotMarker = "trano-scrollback-v1\n"

type ScrollbackInfo struct {
	PaneID    string  `json:"paneID"`
	ByteCount int     `json:"byteCount"`
	LineCount int     `json:"lineCount"`
	UpdatedAt float64 `json:"updatedAt"`
}

func sanitizeSnapshot(text string) string {
	if len(text) > snapshotBytes {
		text = text[len(text)-snapshotBytes:]
		for len(text) > 0 && !utf8.RuneStart(text[0]) {
			text = text[1:]
		}
	}
	text = strings.ToValidUTF8(text, "")
	text = strings.Map(func(r rune) rune {
		if r == '\n' || r == '\t' || r >= 32 && (r < 127 || r > 159) {
			return r
		}
		return -1
	}, text)
	lines := strings.Split(text, "\n")
	if len(lines) > snapshotLines {
		lines = lines[len(lines)-snapshotLines:]
	}
	return strings.Join(lines, "\n")
}
func enabledScrollback(state State) bool {
	return state.PersistScrollback == nil || *state.PersistScrollback
}
func (r *Runtime) snapshotDirectory(create bool) (string, error) {
	dir := filepath.Join(r.root, "scrollback")
	info, err := os.Lstat(dir)
	if os.IsNotExist(err) && !create {
		return "", nil
	}
	if err != nil && !os.IsNotExist(err) {
		return "", err
	}
	if info != nil {
		owner, ok := info.Sys().(*syscall.Stat_t)
		if !info.IsDir() || !ok || owner.Uid != uint32(os.Getuid()) {
			return "", errors.New("scrollback directory must be owned and not symlinked")
		}
	}
	if create {
		if err := ownedDirectory(dir); err != nil {
			return "", err
		}
	}
	marker := filepath.Join(dir, ".trano-scrollback")
	markerInfo, err := os.Lstat(marker)
	if os.IsNotExist(err) && create {
		entries, err := os.ReadDir(dir)
		if err != nil {
			return "", err
		}
		if len(entries) != 0 {
			return "", errors.New("refusing unmanaged scrollback directory")
		}
		if err := atomicWrite(marker, []byte(snapshotMarker)); err != nil {
			return "", err
		}
	} else if err != nil {
		return "", err
	} else {
		if !markerInfo.Mode().IsRegular() || markerInfo.Size() != int64(len(snapshotMarker)) {
			return "", errors.New("invalid scrollback ownership marker")
		}
		data, err := os.ReadFile(marker)
		if err != nil || string(data) != snapshotMarker {
			return "", errors.New("invalid scrollback ownership marker")
		}
	}
	return dir, nil
}
func (r *Runtime) SaveScrollback(id, text string) error { return r.saveScrollback(id, text, 0) }
func (r *Runtime) saveScrollback(id, text string, expectedPID int) error {
	lock, err := r.lock()
	if err != nil {
		return err
	}
	defer lock.Close()
	state, err := r.load()
	if err != nil {
		return err
	}
	if err := require(state, id); err != nil {
		return err
	}
	if !enabledScrollback(state) {
		return nil
	}
	if expectedPID > 0 && !r.samePaneProcess(id, expectedPID) {
		return nil
	}
	dir, err := r.snapshotDirectory(true)
	if err != nil {
		return err
	}
	text = sanitizeSnapshot(text)
	count := 0
	if text != "" {
		count = len(strings.Split(text, "\n"))
	}
	info := ScrollbackInfo{PaneID: id, ByteCount: len(text), LineCount: count, UpdatedAt: now()}
	header, _ := json.Marshal(info)
	return atomicWrite(filepath.Join(dir, id+".snapshot"), append(append(header, '\n'), []byte(text)...))
}
func openSnapshot(path string) (*os.File, error) {
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), path)
	info, err := file.Stat()
	if err != nil {
		file.Close()
		return nil, err
	}
	owner, ok := info.Sys().(*syscall.Stat_t)
	if !info.Mode().IsRegular() || !ok || owner.Uid != uint32(os.Getuid()) || info.Size() > snapshotBytes+1024 {
		file.Close()
		return nil, errors.New("invalid scrollback archive")
	}
	return file, nil
}
func readSnapshotHeader(file *os.File) (ScrollbackInfo, *bufio.Reader, error) {
	reader := bufio.NewReaderSize(file, 1024)
	header, err := reader.ReadSlice('\n')
	if err != nil {
		return ScrollbackInfo{}, nil, errors.New("invalid scrollback header")
	}
	var info ScrollbackInfo
	if err := json.Unmarshal(header, &info); err != nil {
		return info, nil, err
	}
	stat, err := file.Stat()
	if err != nil {
		return info, nil, err
	}
	if !validID.MatchString(info.PaneID) || info.ByteCount < 0 || info.ByteCount > snapshotBytes || info.LineCount < 0 || info.LineCount > snapshotLines || int64(len(header)+info.ByteCount) != stat.Size() {
		return info, nil, errors.New("invalid scrollback metadata")
	}
	return info, reader, nil
}
func (r *Runtime) readScrollback(id string, content bool) (*ScrollbackInfo, string, error) {
	if !validID.MatchString(id) {
		return nil, "", errors.New("invalid scrollback pane")
	}
	lock, err := r.lock()
	if err != nil {
		return nil, "", err
	}
	defer lock.Close()
	state, err := r.load()
	if err != nil {
		return nil, "", err
	}
	if !enabledScrollback(state) {
		return nil, "", nil
	}
	dir, err := r.snapshotDirectory(false)
	if err != nil || dir == "" {
		return nil, "", err
	}
	file, err := openSnapshot(filepath.Join(dir, id+".snapshot"))
	if os.IsNotExist(err) {
		return nil, "", nil
	}
	if err != nil {
		return nil, "", err
	}
	defer file.Close()
	info, reader, err := readSnapshotHeader(file)
	if err != nil {
		return nil, "", err
	}
	if info.PaneID != id {
		return nil, "", errors.New("scrollback pane mismatch")
	}
	if !content {
		return &info, "", nil
	}
	data, err := io.ReadAll(io.LimitReader(reader, snapshotBytes+1))
	if err != nil {
		return nil, "", err
	}
	if len(data) > snapshotBytes || !utf8.Valid(data) {
		return nil, "", errors.New("invalid scrollback payload")
	}
	return &info, sanitizeSnapshot(string(data)), nil
}
func (r *Runtime) ReplayScrollback(id string) (string, error) {
	_, text, err := r.readScrollback(id, true)
	return text, err
}
func (r *Runtime) ScrollbackMetadata(id string) (*ScrollbackInfo, error) {
	info, _, err := r.readScrollback(id, false)
	return info, err
}
func (r *Runtime) SetScrollback(enabled bool) error {
	lock, err := r.lock()
	if err != nil {
		return err
	}
	defer lock.Close()
	state, err := r.load()
	if err != nil {
		return err
	}
	state.PersistScrollback = &enabled
	if err := r.save(state); err != nil {
		return err
	}
	if enabled {
		return nil
	}
	dir, err := r.snapshotDirectory(false)
	if err != nil || dir == "" {
		return err
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".snapshot") && validID.MatchString(strings.TrimSuffix(entry.Name(), ".snapshot")) {
			if err := os.Remove(filepath.Join(dir, entry.Name())); err != nil {
				return err
			}
		}
	}
	return nil
}
func (r *Runtime) samePaneProcess(id string, pid int) bool {
	value, err := r.command("display-message", "-p", "-t", id+":0.0", "#{pane_pid}")
	return err == nil && strings.TrimSpace(value) == strconv.Itoa(pid)
}
func (r *Runtime) captureScrollback(id string, expectedPID int) {
	lock, err := r.lock()
	if err != nil {
		return
	}
	state, err := r.load()
	lock.Close()
	if err != nil || !enabledScrollback(state) {
		return
	}
	output, err := r.commandLimit(snapshotBytes, "capture-pane", "-p", "-t", id+":0.0", "-S", "-10000")
	if err == nil {
		_ = r.saveScrollback(id, output, expectedPID)
	}
}
func (r *Runtime) Monitor(id string, input io.Reader, expectedPID int) error {
	type chunk struct {
		data []byte
		err  error
	}
	chunks := make(chan chunk, 2)
	go func() {
		for {
			buffer := make([]byte, 8192)
			n, err := input.Read(buffer)
			chunks <- chunk{buffer[:n], err}
			if err != nil {
				return
			}
		}
	}()
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	scanner := activityScanner{}
	dirty := false
	for {
		select {
		case next := <-chunks:
			if len(next.data) > 0 {
				dirty = true
			}
			for _, report := range scanner.feed(next.data) {
				if expectedPID == 0 || r.samePaneProcess(id, expectedPID) {
					_ = r.Report(id, report, "osc7501")
				}
			}
			if next.err != nil {
				if dirty {
					r.captureScrollback(id, expectedPID)
				}
				if next.err == io.EOF {
					return nil
				}
				return next.err
			}
		case <-ticker.C:
			if dirty {
				r.captureScrollback(id, expectedPID)
				dirty = false
			}
		}
	}
}
