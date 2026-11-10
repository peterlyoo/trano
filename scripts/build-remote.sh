#!/bin/sh
set -eu
cd "$(dirname "$0")/../remote"
for arch in amd64 arm64; do
    output="../build/remote/linux-$arch"
    mkdir -p "$output"
    CGO_ENABLED=0 GOOS=linux GOARCH="$arch" go build -trimpath -ldflags='-s -w' -o "$output/trano-server" .
    (cd "$output" && shasum -a 256 trano-server > trano-server.sha256)
done
