set -u
home=${HOME:-}
[ -n "$home" ] || { echo 'HOME is not set there' >&2; exit 3; }
printf 'os=%s\n' "$(uname -s)"
printf 'arch=%s\n' "$(uname -m)"
libc=gnu
if [ -f /etc/alpine-release ] || { command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; }; then libc=musl; fi
printf 'libc=%s\n' "$libc"
printf 'home=%s\n' "$home"
target=$home/.local/share/telar/versions/$dir/telar
printf 'target=%s\n' "$target"
if [ -x "$target" ]; then printf 'installed=%s\n' "$("$target" --version 2>/dev/null | head -n 1)"; fi
for tool in curl tar bash node npm; do
    if command -v "$tool" >/dev/null 2>&1; then printf 'tool=%s\n' "$tool"; fi
done
if command -v node >/dev/null 2>&1; then printf 'node=%s\n' "$(node --version 2>/dev/null | head -n 1)"; fi
found() {
    name=$1
    shift
    for candidate in "$@"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            printf 'agent=%s:%s\n' "$name" "$candidate"
            return
        fi
    done
}
found claude "$home/.local/bin/claude" "$(command -v claude 2>/dev/null)"
found codex "$home/.local/bin/codex" "$(command -v codex 2>/dev/null)"
found pi "$home/.local/bin/pi" "$home/.pi/agent/bin/pi" "$home/bin/pi" "$(command -v pi 2>/dev/null)"
found opencode "$home/.opencode/bin/opencode" "$(command -v opencode 2>/dev/null)"
found cursor "$home/.local/bin/agent" "$home/.local/bin/cursor-agent" "$(command -v cursor-agent 2>/dev/null)"
