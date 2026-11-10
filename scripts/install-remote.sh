#!/bin/sh
set -eu
prefix="$HOME/.local/bin"
binary=""
expected=""
mode=install
force=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix) prefix=$2; shift 2 ;;
        --binary) binary=$2; shift 2 ;;
        --sha256) expected=$2; shift 2 ;;
        --check) mode=check; shift ;;
        --dry-run) mode=dry-run; shift ;;
        --force) force=true; shift ;;
        *) printf '%s\n' 'Usage: install-remote.sh --binary PATH [--sha256 HASH] [--prefix DIR] [--dry-run|--check] [--force]' >&2; exit 2 ;;
    esac
done
case "$prefix" in /*) ;; *) printf '%s\n' 'Installation prefix must be absolute.' >&2; exit 2 ;; esac
check_path="$prefix"
while [ "$check_path" != / ]; do
    [ ! -L "$check_path" ] || { printf '%s\n' 'Refusing a symlinked installation directory.' >&2; exit 1; }
    check_path=$(dirname "$check_path")
done
target="$prefix/trano-server"
marker="$prefix/.trano-server.sha256"
[ ! -L "$marker" ] || { printf '%s\n' 'Refusing a symlinked checksum marker.' >&2; exit 1; }
hash() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}
if [ "$mode" = check ]; then
    command -v tmux >/dev/null 2>&1 || { printf '%s\n' 'Missing tmux' >&2; exit 1; }
    [ -x "$target" ] && [ -f "$marker" ] && [ "$(hash "$target")" = "$(cat "$marker")" ] || { printf '%s\n' 'Trano server missing or modified' >&2; exit 1; }
    printf '%s\n' "OK: $target"
    exit 0
fi
[ -n "$binary" ] && [ -f "$binary" ] || { printf '%s\n' '--binary is required' >&2; exit 2; }
if [ -z "$expected" ] && [ -f "$binary.sha256" ]; then expected=$(awk 'NR==1 {print $1}' "$binary.sha256"); fi
[ "${#expected}" -eq 64 ] && [ "$(hash "$binary")" = "$expected" ] || { printf '%s\n' 'SHA-256 mismatch or missing checksum' >&2; exit 1; }
if [ -e "$target" ] || [ -L "$target" ]; then
    managed=false
    if [ -f "$marker" ] && [ ! -L "$target" ] && [ "$(hash "$target")" = "$(cat "$marker")" ]; then managed=true; fi
    if [ "$managed" = false ] && [ "$force" = false ]; then printf '%s\n' 'Refusing to replace an unmanaged target; --force creates a backup.' >&2; exit 1; fi
fi
if [ "$mode" = dry-run ]; then printf '%s\n' "Would install verified server to $target (force=$force)"; exit 0; fi
command -v tmux >/dev/null 2>&1 || { printf '%s\n' 'Install tmux with your system package manager first.' >&2; exit 1; }
mkdir -p "$prefix"
if [ -e "$target" ] || [ -L "$target" ]; then
    if [ "$force" = true ]; then cp -Pp "$target" "$target.backup.$(date +%s).$$"; fi
fi
stage=$(mktemp "$prefix/.trano-install.XXXXXX")
marker_stage=$(mktemp "$prefix/.trano-marker.XXXXXX")
trap 'rm -f "$stage" "$marker_stage"' EXIT HUP INT TERM
cp "$binary" "$stage"
chmod 755 "$stage"
mv -f "$stage" "$target"
printf '%s\n' "$expected" > "$marker_stage"
chmod 600 "$marker_stage"
mv -f "$marker_stage" "$marker"
printf '%s\n' "Installed: $target" 'Use an existing SSH alias to connect from Trano.'
