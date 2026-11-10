#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
prefix="$PWD/build/ci-tools"
sources="$PWD/build/ci-sources"
mkdir -p "$prefix" "$sources"
signature=$(shasum -a 256 "$0" | awk '{print $1}')
if [[ -x "$prefix/bin/tmux" && -f "$prefix/.bootstrap-sha256" ]] && [[ "$(cat "$prefix/.bootstrap-sha256")" == "$signature" ]] && [[ "$("$prefix/bin/tmux" -V)" == 'tmux 3.6a' ]]; then
    printf '%s\n' "$prefix/bin"
    exit 0
fi
fetch() {
    local url=$1 checksum=$2 name=$3
    curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 "$url" -o "$sources/$name"
    printf '%s  %s\n' "$checksum" "$sources/$name" | shasum -a 256 -c -
    tar -xzf "$sources/$name" -C "$sources"
}
fetch https://github.com/libevent/libevent/releases/download/release-2.1.13-stable/libevent-2.1.13-stable.tar.gz f7e9383b8c0baa81b687e5b5eecc01beefaf1b19b64151d95ed61647fe7a315c libevent-2.1.13-stable.tar.gz
fetch https://github.com/tmux/tmux/releases/download/3.6a/tmux-3.6a.tar.gz b6d8d9c76585db8ef5fa00d4931902fa4b8cbe8166f528f44fc403961a3f3759 tmux-3.6a.tar.gz
fetch https://github.com/JuliaStrings/utf8proc/releases/download/v2.12.0/utf8proc-2.12.0.tar.gz a393fbef160835fb315bc3e91ba8d86f7a73a7cec9e6198b6c60b848b498bfeb utf8proc-2.12.0.tar.gz
jobs=${TRANO_BUILD_JOBS:-4}
if [[ ! -f "$prefix/lib/libevent.a" || ! -f "$prefix/.libevent-portable-pipe" ]]; then
    # New SDKs expose pipe2 as a weak symbol even on hosts that cannot call it.
    if [[ "$(uname -s)" == Darwin ]]; then export ac_cv_func_pipe2=no; fi
    (cd "$sources/libevent-2.1.13-stable" && if [[ -f Makefile ]]; then make clean; fi && ./configure --prefix="$prefix" --disable-shared --enable-static --disable-openssl --disable-samples --disable-libevent-regress && make -j "$jobs" && make install)
    touch "$prefix/.libevent-portable-pipe"
fi
(cd "$sources/utf8proc-2.12.0" && make -j "$jobs" libutf8proc.a)
cp "$sources/utf8proc-2.12.0/libutf8proc.a" "$prefix/lib/"
cp "$sources/utf8proc-2.12.0/utf8proc.h" "$prefix/include/"
(cd "$sources/tmux-3.6a" && PKG_CONFIG_PATH="$prefix/lib/pkgconfig" LIBUTF8PROC_LIBS="$prefix/lib/libutf8proc.a" LIBUTF8PROC_CFLAGS="-I$prefix/include" CFLAGS="-I$prefix/include" LDFLAGS="-L$prefix/lib" ./configure --prefix="$prefix" --enable-utf8proc && make -j "$jobs" && make install)
"$prefix/bin/tmux" -V
python3 - "$prefix/bin/tmux" <<'PY'
import pathlib, subprocess, sys, tempfile
with tempfile.TemporaryDirectory(prefix="trano-ci-probe-", dir="/tmp") as root:
    args = [sys.argv[1], "-u", "-S", str(pathlib.Path(root) / "socket"), "-f", "/dev/null"]
    try:
        subprocess.run(args + ["new-session", "-d", "-s", "check", "/bin/sh"], check=True, timeout=5)
        subprocess.run(args + ["list-sessions"], check=True, timeout=5)
    finally:
        subprocess.run(args + ["kill-server"], capture_output=True, timeout=5)
PY
printf '%s\n' "$signature" > "$prefix/.bootstrap-sha256"
printf '%s\n' "$prefix/bin"
