#!/bin/sh
set -eu
installer=$1
root=$(mktemp -d /tmp/trano-installer-test.XXXXXXXX)
trap 'rm -rf "$root"' EXIT HUP INT TERM
binary="$root/server"
printf '#!/bin/sh\nexit 0\n' > "$binary"
checksum=$(sha256sum "$binary" | awk '{print $1}')
prefix="$root/user/bin"
sh "$installer" --binary "$binary" --sha256 "$checksum" --prefix "$prefix" --dry-run >/dev/null
[ ! -e "$prefix" ]
sh "$installer" --binary "$binary" --sha256 "$checksum" --prefix "$prefix" >/dev/null
sh "$installer" --prefix "$prefix" --check >/dev/null
sh "$installer" --binary "$binary" --sha256 "$checksum" --prefix "$prefix" >/dev/null
printf '\nchanged\n' >> "$prefix/trano-server"
if sh "$installer" --binary "$binary" --sha256 "$checksum" --prefix "$prefix" >/dev/null 2>&1; then printf '%s\n' 'Unmanaged binary was replaced without force' >&2; exit 1; fi
sh "$installer" --binary "$binary" --sha256 "$checksum" --prefix "$prefix" --force >/dev/null
[ "$(find "$prefix" -name 'trano-server.backup.*' | wc -l)" -eq 1 ]
sh "$installer" --prefix "$prefix" --check >/dev/null
rm "$prefix/.trano-server.sha256"
printf 'keep\n' > "$root/user-owned"
ln -s "$root/user-owned" "$prefix/.trano-server.sha256"
if sh "$installer" --binary "$binary" --sha256 "$checksum" --prefix "$prefix" --force >/dev/null 2>&1; then printf '%s\n' 'Symlink marker was followed' >&2; exit 1; fi
[ "$(cat "$root/user-owned")" = keep ]
ln -s "$prefix" "$root/linked"
if sh "$installer" --binary "$binary" --sha256 "$checksum" --prefix "$root/linked" --force >/dev/null 2>&1; then printf '%s\n' 'Symlink directory was followed' >&2; exit 1; fi
printf '%s\n' 'PASS: dry-run, idempotent install/check, unmanaged conflict, backup replacement, symlink protection'
