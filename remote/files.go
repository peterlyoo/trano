package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"image/png"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"unicode/utf8"
)

type PathEntry struct {
	Name      string `json:"name"`
	Path      string `json:"path"`
	Directory bool   `json:"directory"`
}
type PathListing struct {
	Path      string      `json:"path"`
	Parent    string      `json:"parent"`
	Entries   []PathEntry `json:"entries"`
	Truncated bool        `json:"truncated"`
}

func (r *Runtime) ListPaths(path string) (PathListing, error) {
	if path == "" {
		path, _ = os.UserHomeDir()
	}
	if !filepath.IsAbs(path) || len(path) > 4096 || strings.ContainsAny(path, "\x00\r\n") {
		return PathListing{}, errors.New("choose an absolute remote path")
	}
	path = filepath.Clean(path)
	directory, err := os.Open(path)
	if err != nil {
		return PathListing{}, err
	}
	defer directory.Close()
	entries, err := directory.ReadDir(2001)
	if err != nil && err != io.EOF {
		return PathListing{}, err
	}
	listing := PathListing{Path: path, Parent: filepath.Dir(path), Entries: []PathEntry{}, Truncated: len(entries) > 2000}
	if len(entries) > 2000 {
		entries = entries[:2000]
	}
	encodedSize := len(path) + len(filepath.Dir(path)) + 1024
	for _, entry := range entries {
		if !utf8.ValidString(entry.Name()) || strings.ContainsAny(entry.Name(), "\r\n") {
			continue
		}
		item := PathEntry{Name: entry.Name(), Path: filepath.Join(path, entry.Name()), Directory: entry.IsDir()}
		encoded, _ := json.Marshal(item)
		if encodedSize+len(encoded)+1 > maxFrame-8192 {
			listing.Truncated = true
			break
		}
		encodedSize += len(encoded) + 1
		listing.Entries = append(listing.Entries, item)
	}
	sort.Slice(listing.Entries, func(i, j int) bool {
		if listing.Entries[i].Directory != listing.Entries[j].Directory {
			return listing.Entries[i].Directory
		}
		return strings.ToLower(listing.Entries[i].Name) < strings.ToLower(listing.Entries[j].Name)
	})
	return listing, nil
}

func (r *Runtime) UploadPNG(id string, input io.Reader) (string, error) {
	data, err := io.ReadAll(io.LimitReader(input, 20*1024*1024+1))
	if err != nil {
		return "", err
	}
	if len(data) > 20*1024*1024 {
		return "", errors.New("image exceeds 20 MiB")
	}
	config, err := png.DecodeConfig(bytes.NewReader(data))
	if err != nil || config.Width < 1 || config.Height < 1 || config.Width > 8192 || config.Height > 8192 || config.Width*config.Height > 16777216 {
		return "", errors.New("invalid PNG or image exceeds 16 megapixels")
	}
	lock, err := r.lock()
	if err != nil {
		return "", err
	}
	defer lock.Close()
	state, err := r.load()
	if err != nil {
		return "", err
	}
	if err := require(state, id); err != nil {
		return "", err
	}
	directory := filepath.Join(r.root, "attachments")
	if err := os.Mkdir(directory, 0700); err != nil && !os.IsExist(err) {
		return "", err
	}
	info, err := os.Lstat(directory)
	if err != nil {
		return "", err
	}
	owner, ok := info.Sys().(*syscall.Stat_t)
	if !info.IsDir() || !ok || owner.Uid != uint32(os.Getuid()) {
		return "", errors.New("attachments must be an owned directory, not a symlink")
	}
	if err := os.Chmod(directory, 0700); err != nil {
		return "", err
	}
	name, err := uuid()
	if err != nil {
		return "", err
	}
	path := filepath.Join(directory, name+".png")
	return path, atomicWrite(path, data)
}
