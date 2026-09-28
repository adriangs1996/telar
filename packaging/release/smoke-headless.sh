#!/bin/sh
# Starts a headless telar runtime with its own state and socket, asks it for
# its agents and stops it. Fails when any step fails or the runtime does not
# come up; prints the runtime's log then.
#
#   packaging/release/smoke-headless.sh zig-out/headless/bin/telar
set -eu

telar=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
# Short, so the socket path fits sun_path.
state=$(mktemp -d /tmp/telar-smoke.XXXXXX)
server=
cleanup() {
    if [ -n "$server" ]; then
        kill "$server" 2>/dev/null || true
    fi

    rm -rf "$state"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -m 700 "$state/run"
export HOME="$state" XDG_CONFIG_HOME="$state/config" XDG_DATA_HOME="$state/data" XDG_STATE_HOME="$state/state"
export XDG_CACHE_HOME="$state/cache" XDG_RUNTIME_DIR="$state/run" TELAR_SOCKET_PATH="$state/run/telar.sock" SHELL=/bin/sh

fail() {
    printf 'smoke-headless: %s\n' "$1" >&2
    sed 's/^/  /' "$state/server.log" >&2
    exit 1
}

"$telar" --version
"$telar" server >"$state/server.log" 2>&1 &
server=$!
tries=0
while [ ! -S "$TELAR_SOCKET_PATH" ]; do
    tries=$((tries + 1))
    [ "$tries" -le 100 ] || fail "the runtime did not open $TELAR_SOCKET_PATH"
    sleep 0.1
done

"$telar" agent list || fail "telar agent list failed"
"$telar" server stop || fail "telar server stop failed"
wait "$server" || fail "the runtime exited with an error"
server=
printf 'smoke-headless: %s started, listed agents and stopped\n' "$telar"
