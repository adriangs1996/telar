#!/usr/bin/env python3
"""Exercise the three native-terminal increments on the existing Wayland VM."""
import importlib.util
from pathlib import Path
import secrets
import argparse
import shlex
import subprocess

spec = importlib.util.spec_from_file_location("telar_vm", Path(__file__).with_name("vm.py"))
vm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vm)

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("output", nargs="?", type=Path, default=Path(".zig-out/gui-terminal-test"))
parser.add_argument("--config", type=Path, help="native appearance configuration to exercise")
parser.add_argument("--reload", action="store_true", help="exercise hot reload with an isolated generated config")
args = parser.parse_args()
if args.reload and args.config:
    parser.error("--reload supplies its own configuration; omit --config")
output = args.output.resolve()
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
config_args = '--config "$state/config.lua"' if args.config or args.reload else '--no-config'
trace = "WAYLAND_DEBUG=client " if args.reload else ""
if args.config or args.reload:
    source = args.config.read_text() if args.config else 'return { api_version = 2, gui = { cursor = { blink = false } } }'
    setup += "printf '%s' " + shlex.quote(source) + ' > "$state/config.lua"\n'
try:
    vm.guest(setup + r'''
__TRACE__./zig-out/bin/telar gui __CONFIG_ARGS__ /bin/bash --noprofile --norc -c "echo \$\$ > '$state/shell.pid'; for i in {1..50}; do printf 'frame %s\n' \$i; sleep .03; done; exec /bin/bash --noprofile --norc -i" > "$state/gui.log" 2>&1 &
printf '%s' "$!" > "$state/gui.pid"
sleep 5
kill -0 "$(cat "$state/gui.pid")"
sed '/^\[[[:space:]0-9.]*\]/d' "$state/gui.log"
'''.replace("__CONFIG_ARGS__", config_args).replace("__TRACE__", trace))
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
    if args.reload:
        vm.guest(resume + r'''
printf '%s' "return { api_version = 2, theme = 'catppuccin', gui = { font = { family = 'DejaVu Sans Mono', size = 22, line_height = 1.2 }, cursor = { style = 'bar', blink = true, blink_interval_ms = 250 } } }" > "$state/save.tmp"
mv "$state/save.tmp" "$state/config.lua"
for attempt in {1..40}; do
    wtype "stty size > '$state/font-size'"
    wtype -k Return
    sleep .2
    if test -s "$state/font-size" && ! cmp -s "$state/before" "$state/font-size"; then break; fi
done
! cmp -s "$state/before" "$state/font-size"
printf 'font before: '; cat "$state/before"
printf 'font reloaded: '; cat "$state/font-size"
''')
        vm.screenshot(output / "02a-reloaded.png")
        vm.guest(resume + r'''
printf '%s' "return { api_version = 2, theme = { terminal = { background = '#ff0000' } }, gui = { font = { family = 'Telar-Test-Missing-Family-98a34b1' } } }" > "$state/save.tmp"
mv "$state/save.tmp" "$state/config.lua"
for attempt in {1..40}; do
    if grep -q 'FontFamilyNotFound' "$state/gui.log"; then break; fi
    sleep .2
done
grep -q 'GUI configuration unchanged:.*FontFamilyNotFound' "$state/gui.log"
wtype "stty size > '$state/invalid-size'; printf survived > '$state/reload-input'"
wtype -k Return
sleep .5
cmp "$state/font-size" "$state/invalid-size"
test "$(cat "$state/reload-input")" = survived
printf '%s' "return { api_version = 2, theme = 'tokyo-night', gui = { font = { size = 17 }, cursor = { style = 'block', blink = false } } }" > "$state/save.tmp"
mv "$state/save.tmp" "$state/config.lua"
for attempt in {1..40}; do
    wtype "stty size > '$state/recovered-size'"
    wtype -k Return
    sleep .2
    if test -s "$state/recovered-size" && ! cmp -s "$state/font-size" "$state/recovered-size"; then break; fi
done
! cmp -s "$state/font-size" "$state/recovered-size"
printf 'font recovered: '; cat "$state/recovered-size"
''')
        vm.screenshot(output / "02b-recovered.png")
        vm.guest(resume + r'''
printf '%s' "return { api_version = 2, theme = 'tokyo-night', gui = { font = { size = 17 }, cursor = { blink = false }, window = { background_opacity = 0.5, background_blur = 20, titlebar = true, padding = { x = 16, y = 12 } } } }" > "$state/save.tmp"
mv "$state/save.tmp" "$state/config.lua"
for attempt in {1..40}; do
    wtype "stty size > '$state/padded-size'"
    wtype -k Return
    sleep .2
    if test -s "$state/padded-size" && ! cmp -s "$state/recovered-size" "$state/padded-size"; then break; fi
done
! cmp -s "$state/recovered-size" "$state/padded-size"
printf 'with padding: '; cat "$state/padded-size"
''')
        vm.screenshot(output / "02c-transparent-padding.png")
        vm.guest(resume + r'''
window_config() {
    local radius=$1 titlebar=$2 generation=$3
    cat > "$state/save.tmp" <<EOF
local telar = require("telar")
return telar.config({
    api_version = 2,
    theme = "tokyo-night",
    client = { keybindings = {
        telar.bind_expr_global({ "ctrl+alt+x" }, function()
            return telar.input.paste("printf '%s' '$generation' > '$state/window-generation'")
        end),
    } },
    gui = {
        font = { size = 17 }, cursor = { blink = false },
        window = { background_opacity = 0.5, background_blur = $radius,
                   titlebar = $titlebar, padding = { x = 16, y = 12 } },
    },
})
EOF
    mv "$state/save.tmp" "$state/config.lua"
    # A generation-specific binding proves adoption even if the compositor has
    # no blur protocol. A fixed delay or an unchanged stty size cannot do that.
    for attempt in {1..40}; do
        wtype -M ctrl -k u -m ctrl -M ctrl -M alt -k x -m alt -m ctrl -k Return
        sleep .2
        if test "$(cat "$state/window-generation" 2>/dev/null || true)" = "$generation"; then break; fi
    done
    test "$(cat "$state/window-generation")" = "$generation"
    wtype "stty size > '$state/$generation-size'"
    wtype -k Return
    for attempt in {1..40}; do
        if test -s "$state/$generation-size"; then break; fi
        sleep .1
    done
    test -s "$state/$generation-size"
    printf '%s: ' "$generation"; cat "$state/$generation-size"
}
window_config 20 true blur-20
window_config 80 true blur-80
window_config 0 true blur-off
cmp "$state/padded-size" "$state/blur-20-size"
cmp "$state/blur-20-size" "$state/blur-80-size"
cmp "$state/blur-20-size" "$state/blur-off-size"
window_config 0 false titlebar-hidden
window_config 0 true titlebar-visible
python3 - "$state/gui.log" <<'PY'
import re
import sys
import time
from pathlib import Path

deadline = time.monotonic() + 5
while True:
    trace = Path(sys.argv[1]).read_text()
    requests = [int(mode) for mode in re.findall(r"zxdg_toplevel_decoration_v1[@#]\d+\.set_mode\((\d+)\)", trace)]
    if not requests or requests == [2, 1, 2] or time.monotonic() >= deadline:
        break
    time.sleep(.05)
configured = [int(mode) for mode in re.findall(r"zxdg_toplevel_decoration_v1[@#]\d+\.configure\((\d+)\)", trace)]
if requests:
    assert requests == [2, 1, 2], requests
    print("titlebar requests: visible -> hidden -> visible", requests)
    print("compositor decoration modes:", configured)
    if 1 not in configured:
        print("compositor imposed server-side decorations; hidden preference was requested but not granted")
else:
    assert '"zxdg_decoration_manager_v1"' not in trace, "advertised decoration protocol was not used"
    print("compositor has no xdg-decoration; Telar draws no titlebar of its own")
blur = re.findall(r"ext_background_effect_surface_v1[@#]\d+\.set_blur_region\(([^)]*)\)", trace)
if blur:
    assert any(region != "nil" for region in blur), blur
    assert blur[-1] == "nil", blur
    print("blur region requests:", blur)
else:
    assert "compositor does not advertise background blur" in trace
    print("compositor has no usable blur capability; numeric reload retained transparency and grid")
PY
for attempt in {1..40}; do
    wtype "stty size > '$state/titlebar-restored-size'"
    wtype -k Return
    sleep .2
    if cmp -s "$state/blur-off-size" "$state/titlebar-restored-size"; then break; fi
done
cmp "$state/blur-off-size" "$state/titlebar-restored-size"
''')
        vm.screenshot(output / "02d-window-options.png")
        vm.guest(resume + r'''
printf '%s' "return { api_version = 2, theme = 'tokyo-night', gui = { font = { size = 17 }, cursor = { blink = false } } }" > "$state/save.tmp"
mv "$state/save.tmp" "$state/config.lua"
for attempt in {1..40}; do
    wtype "stty size > '$state/unpadded-size'"
    wtype -k Return
    sleep .2
    if cmp -s "$state/recovered-size" "$state/unpadded-size"; then break; fi
done
cmp "$state/recovered-size" "$state/unpadded-size"
printf 'padding removed: '; cat "$state/unpadded-size"
''')
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
./zig-out/bin/telar gui __CONFIG_ARGS__ > "$state/reattach.log" 2>&1 &
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
sed '/^\[[[:space:]0-9.]*\]/d' "$state/gui.log" "$state/reattach.log"
! grep -E "Validation Error|VUID-" "$state/gui.log" "$state/reattach.log"
'''.replace("__CONFIG_ARGS__", config_args))
    vm.screenshot(output / "03-reattach.png")
finally:
    for name in ("gui.log", "reattach.log"):
        with (output / name).open("wb") as logfile:
            subprocess.run(vm.ssh_command("bash", "-c", 'state=$(cat ' + state_file + '); cat "$state/' + name + '"'),
                           stdout=logfile, check=False)
    vm.guest(resume + r'''
if test -f "$state/gui.pid"; then
    gui=$(cat "$state/gui.pid")
    swaymsg "[pid=$gui] kill" > /dev/null || true
fi
./zig-out/bin/telar server stop > /dev/null || true
''')
