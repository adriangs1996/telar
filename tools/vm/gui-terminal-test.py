#!/usr/bin/env python3
"""Exercise the three native-terminal increments on the existing Wayland VM."""
import importlib.util
from pathlib import Path
import sys
import secrets

spec = importlib.util.spec_from_file_location("telar_vm", Path(__file__).with_name("vm.py"))
vm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vm)

output = Path(sys.argv[1] if len(sys.argv) > 1 else ".zig-out/gui-terminal-test").resolve()
output.mkdir(parents=True, exist_ok=True)
vm.sync()
vm.build()
# One owner-only test directory identifies every resource the test may stop.
state_file = "/tmp/telar-native-terminal-test-" + secrets.token_hex(12)
setup = r'''set -euo pipefail
umask 077
cd "$HOME/__SOURCE__"
state=$(mktemp -d /tmp/telar-native-terminal.XXXXXX)
printf '%s' "$state" > __STATE_FILE__
export WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR="/run/user/$(id -u)"
export VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation
export VK_LAYER_VALIDATE_SYNC=1
export SWAYSOCK=$(find "$XDG_RUNTIME_DIR" -name 'sway-ipc*.sock' -print -quit)
export TELAR_SOCKET="$state/runtime.sock" TELAR_HISTORY="$state/history.db"
'''.replace("__SOURCE__", vm.GUEST_SRC).replace("__STATE_FILE__", state_file)
resume = setup[setup.index("export WAYLAND_DISPLAY"):]
resume = 'set -euo pipefail\ncd "$HOME/' + vm.GUEST_SRC + '"\nstate=$(cat ' + state_file + ')\n' + resume
try:
    vm.guest(setup + r'''
./zig-out/bin/telar gui --no-config /bin/bash --noprofile --norc -c "echo \$\$ > '$state/shell.pid'; for i in {1..50}; do printf 'frame %s\n' \$i; sleep .03; done; exec /bin/bash --noprofile --norc -i" > "$state/gui.log" 2>&1 &
printf '%s' "$!" > "$state/gui.pid"
sleep 5
kill -0 "$(cat "$state/gui.pid")"
cat "$state/gui.log"
''')
    vm.screenshot(output / "01-prompt.png")
    vm.guest(resume + r'''
gui=$(cat "$state/gui.pid")
swaymsg "[pid=$gui] focus" > /dev/null
wtype "printf 'native-input-ok\\n'; stty size > '$state/before'; printf typed > '$state/typed'"
wtype -k Return
sleep 1
test "$(cat "$state/typed")" = typed
printf "printf 'café pasted\\\\n'; printf pasted > '%s/pasted'" "$state" | wl-copy --paste-once > /dev/null 2>&1
wtype -M ctrl -M shift -k v -m shift -m ctrl
wtype -k Return
sleep 1
test "$(cat "$state/pasted")" = pasted
''')
    vm.screenshot(output / "02-command.png")
    vm.guest(resume + r'''
gui=$(cat "$state/gui.pid")
shell_pid=$(cat "$state/shell.pid")
swaymsg "[pid=$gui] floating enable" > /dev/null
sleep 1
swaymsg "[pid=$gui] resize set width 900 px height 600 px" > /dev/null
sleep 1
wtype "stty size > '$state/after'"
wtype -k Return
sleep 1
! cmp -s "$state/before" "$state/after"
printf 'before: '; cat "$state/before"
printf 'after: '; cat "$state/after"
swaymsg "[pid=$gui] kill" > /dev/null
sleep 2
if test -e "/proc/$gui/stat"; then test "$(awk '{print $3}' "/proc/$gui/stat")" = Z; fi
kill -0 "$shell_pid"
./zig-out/bin/telar gui --no-config > "$state/reattach.log" 2>&1 &
printf '%s' "$!" > "$state/gui.pid"
sleep 3
gui=$(cat "$state/gui.pid")
kill -0 "$gui"
swaymsg "[pid=$gui] focus" > /dev/null
wtype "echo \$\$ > '$state/reattached.pid'; printf 'reattach-ok\\n'"
wtype -k Return
sleep 1
test "$shell_pid" = "$(cat "$state/reattached.pid")"
printf 'reattached shell PID: %s\n' "$shell_pid"
cat "$state/gui.log" "$state/reattach.log"
! grep -E "Validation Error|VUID-" "$state/gui.log" "$state/reattach.log"
''')
    vm.screenshot(output / "03-reattach.png")
finally:
    vm.guest(resume + r'''
if test -f "$state/gui.pid"; then
    gui=$(cat "$state/gui.pid")
    swaymsg "[pid=$gui] kill" > /dev/null || true
fi
./zig-out/bin/telar server stop > /dev/null || true
''')
