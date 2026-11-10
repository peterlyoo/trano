package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"image"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Implements: FR-REMOTE-2
func TestPathListingFitsRPCFrameWithLongPaths(t *testing.T) {
	r := recoveryRuntime(t)
	directory := r.root
	for i := 0; i < 8; i++ {
		directory = filepath.Join(directory, strings.Repeat("d", 100))
	}
	if err := os.MkdirAll(directory, 0700); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 1400; i++ {
		if err := os.WriteFile(filepath.Join(directory, fmt.Sprintf("file-%04d", i)), nil, 0600); err != nil {
			t.Fatal(err)
		}
	}
	listing, err := r.ListPaths(directory)
	if err != nil {
		t.Fatal(err)
	}
	encoded, _ := json.Marshal(Response{APIVersion: 1, Result: listing})
	if len(encoded) > maxFrame || !listing.Truncated || len(listing.Entries) == 0 {
		t.Fatalf("listing bound missing: %d bytes, truncated=%v", len(encoded), listing.Truncated)
	}
}

// Implements: FR-REMOTE-2
func TestImageUploadAndRemotePathListing(t *testing.T) {
	root, err := os.MkdirTemp("/tmp", "trano-files-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(root)
	runtime, err := NewRuntime(root)
	if err != nil {
		t.Fatal(err)
	}
	session, err := runtime.Create("Files", root)
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Terminate(session.ID)
	var data bytes.Buffer
	if err := png.Encode(&data, image.NewRGBA(image.Rect(0, 0, 2, 2))); err != nil {
		t.Fatal(err)
	}
	path, err := runtime.UploadPNG(session.ID, bytes.NewReader(data.Bytes()))
	if err != nil {
		t.Fatal(err)
	}
	actual, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(actual, data.Bytes()) {
		t.Fatal("uploaded image differs", err)
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0600 || filepath.Dir(path) != filepath.Join(root, "attachments") {
		t.Fatal("unsafe attachment destination")
	}
	if _, err := runtime.UploadPNG(session.ID, bytes.NewBufferString("not an image")); err == nil {
		t.Fatal("invalid PNG accepted")
	}
	if _, err := runtime.UploadPNG("../../escape", bytes.NewReader(data.Bytes())); err == nil {
		t.Fatal("invalid session accepted")
	}
	directory := filepath.Join(root, "한글 'folder';")
	if err := os.Mkdir(directory, 0700); err != nil {
		t.Fatal(err)
	}
	listing, err := runtime.ListPaths(root)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, entry := range listing.Entries {
		if entry.Path == directory && entry.Directory {
			found = true
		}
	}
	if !found {
		t.Fatal("Unicode directory missing")
	}
	if _, err := runtime.ListPaths("relative"); err == nil {
		t.Fatal("relative path accepted")
	}
}
