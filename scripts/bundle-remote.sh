#!/bin/sh
set -eu
[ "$#" -eq 1 ] || { printf '%s\n' 'Usage: bundle-remote.sh RESOURCES_DIR' >&2; exit 2; }
repository=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
resources=$1
"$repository/scripts/build-remote.sh"
mkdir -p "$resources/Remote"
for arch in amd64 arm64; do
    mkdir -p "$resources/Remote/linux-$arch"
    cp "$repository/build/remote/linux-$arch/trano-server" "$resources/Remote/linux-$arch/"
    cp "$repository/build/remote/linux-$arch/trano-server.sha256" "$resources/Remote/linux-$arch/"
done
cp "$repository/scripts/install-remote.sh" "$resources/Remote/"
