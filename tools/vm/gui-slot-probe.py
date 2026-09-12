#!/usr/bin/env python3
"""Run one isolated native-slot workload in the existing Linux VM.

Build an instrumented source copy with tools/linux_slot_instrument.py first.
This driver starts and stops only its own runtime and window. It neither syncs
nor builds the shared VM checkout, so compilation can be scheduled separately
from performance measurements.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import secrets
import shlex
import subprocess
import tarfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--source", required=True, help="Absolute instrumented source root in guest")
    parser.add_argument("--binary", required=True, help="Absolute Telar executable in guest")
    parser.add_argument("--library", required=True, help="Absolute preload library in guest")
    parser.add_argument("--mode", choices=("scroll", "full"), required=True)
    parser.add_argument("--seconds", type=float, default=12)
    parser.add_argument("--rate", type=int, default=120)
    parser.add_argument("--viewport", nargs=2, type=int, default=(1900, 2112))
    parser.add_argument("--floating-maximum-restore", nargs=2, type=int,
                        help="Temporarily allow oversized floating windows; restore these known Sway limits")
    parser.add_argument("--validation", action="store_true")
    parser.add_argument("--no-gpu-timestamps", action="store_true",
                        help="Keep native/call timings and disable injected Vulkan timestamp queries")
    args = parser.parse_args()
    if not 1 <= args.seconds <= 60 or not 1 <= args.rate <= 240:
        parser.error("seconds must be 1..60; rate must be 1..240")
    if not all(320 <= dimension <= 8192 for dimension in args.viewport):
        parser.error("viewport dimensions must be 320..8192")
    directory = args.directory.resolve()
    directory.mkdir(parents=True, mode=0o700, exist_ok=False)
    spec = importlib.util.spec_from_file_location("telar_vm", Path(__file__).with_name("vm.py"))
    vm = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(vm)
    guest_dir = "/tmp/telar-slot-" + secrets.token_hex(6)
    values = {
        "directory": guest_dir, "source": args.source, "binary": args.binary, "library": args.library,
        "mode": args.mode, "seconds": str(args.seconds), "rate": str(args.rate),
        "width": str(args.viewport[0]), "height": str(args.viewport[1]),
        "restore_maximum": " x ".join(map(str, args.floating_maximum_restore)) if args.floating_maximum_restore else "",
        "gpu_timestamps": "0" if args.no_gpu_timestamps else "1",
    }
    prefix = "\n".join(f"probe_{key}={shlex.quote(value)}" for key, value in values.items())
    validation = "export VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation VK_LAYER_VALIDATE_SYNC=1" if args.validation else "unset VK_INSTANCE_LAYERS VK_LAYER_VALIDATE_SYNC"
    script = prefix + "\n" + r'''set -euo pipefail
umask 077
mkdir "$probe_directory"
export WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR="/run/user/$(id -u)"
export SWAYSOCK=$(find "$XDG_RUNTIME_DIR" -name 'sway-ipc*.sock' -print -quit)
export TELAR_SOCKET="$probe_directory/runtime.sock" TELAR_HISTORY="$probe_directory/history.db"
unset LD_PRELOAD TELAR_LINUX_SLOT_PROBE
probe_gui=
cleanup() {
    if test -n "$probe_gui"; then
        swaymsg "[pid=$probe_gui] kill" > /dev/null 2>&1 || true
        wait "$probe_gui" 2>/dev/null || true
    fi
    if test -n "$probe_restore_maximum"; then
        swaymsg "floating_maximum_size $probe_restore_maximum" > "$probe_directory/restore-maximum.json" || true
    fi
    "$probe_binary" server stop > /dev/null 2>&1 || true
}
trap cleanup EXIT
cd "$probe_source"
if test -n "$probe_restore_maximum"; then
    swaymsg -t get_config | python3 -c 'import hashlib,json,re,sys
text=json.load(sys.stdin)["config"]
settings=[list(map(int, pair)) for pair in re.findall(r"(?m)^\s*floating_maximum_size\s+(-?\d+)\s+x\s+(-?\d+)\s*(?:#.*)?$",text)]
expected=list(map(int,sys.argv[1].split(" x ")))
configured=settings[-1] if settings else [0,0]
if configured != expected:
    raise SystemExit("Configured floating maximum differs from requested restoration")
json.dump({"configuration_sha256":hashlib.sha256(text.encode()).hexdigest(),"configured_maximum":configured},sys.stdout)
' "$probe_restore_maximum" > "$probe_directory/sway-config.json"
    swaymsg "floating_maximum_size -1 x -1" > "$probe_directory/unbounded-maximum.json"
fi
"$probe_binary" server --background --no-config > "$probe_directory/runtime.log" 2>&1
''' + validation + "\n" + r'''
TELAR_LINUX_SLOT_PROBE="$probe_directory/raw.json" TELAR_LINUX_SLOT_TIMESTAMPS="$probe_gpu_timestamps" LD_PRELOAD="$probe_library" \
    "$probe_binary" gui --no-config /usr/bin/python3 "$probe_source/tools/gui_slot_workload.py" \
    --mode "$probe_mode" --rate "$probe_rate" --seconds "$probe_seconds" \
    --initial-delay 3 \
    --size-file "$probe_directory/workload.json" > "$probe_directory/gui.log" 2>&1 &
probe_gui=$!
for probe_attempt in $(seq 1 100); do
    kill -0 "$probe_gui"
    if swaymsg -t get_tree | python3 -c 'import json,sys; wanted=int(sys.argv[1]);
def contains(node):
    return node.get("pid")==wanted or any(contains(child) for child in node.get("nodes",[])+node.get("floating_nodes",[]))
sys.exit(not contains(json.load(sys.stdin)))' "$probe_gui"; then
        break
    fi
    sleep .05
done
swaymsg "[pid=$probe_gui] floating enable, border none" > "$probe_directory/floating.json"
sleep 1
swaymsg "[pid=$probe_gui] resize set width $probe_width px height $probe_height px" > "$probe_directory/resize.json"
sleep .5
swaymsg -t get_tree | python3 -c 'import json,sys; wanted=int(sys.argv[1])
def find(node):
    if node.get("pid")==wanted:
        return {key:node.get(key) for key in ("rect","window_rect","geometry","app_id")}
    for child in node.get("nodes",[])+node.get("floating_nodes",[]):
        found=find(child)
        if found:return found
json.dump(find(json.load(sys.stdin)),sys.stdout)' "$probe_gui" > "$probe_directory/window.json"
sleep "$(python3 -c 'import sys; print(float(sys.argv[1])+3.5)' "$probe_seconds")"
kill -0 "$probe_gui"
swaymsg -t get_outputs > "$probe_directory/outputs.json"
swaymsg "[pid=$probe_gui] kill" > /dev/null
wait "$probe_gui"
probe_gui=
test -s "$probe_directory/raw.json"
test -s "$probe_directory/workload.json"
sha256sum "$probe_binary" "$probe_library" > "$probe_directory/binaries.sha256"
cp linux-slot-instrumentation.json "$probe_directory/instrumentation.json"
uname -a > "$probe_directory/kernel.txt"
if grep -Eq 'Validation Error|VUID-' "$probe_directory/gui.log"; then
    cat "$probe_directory/gui.log"
    exit 1
fi
'''
    result = {"guest_directory": guest_dir, "source": args.source, "binary": args.binary,
              "library": args.library, "mode": args.mode, "seconds": args.seconds, "rate": args.rate,
              "requested_viewport": args.viewport, "validation": args.validation}
    result["floating_maximum_restore"] = args.floating_maximum_restore
    result["timestamp_queries"] = not args.no_gpu_timestamps
    (directory / "run.json").write_text(json.dumps(result, indent=2) + "\n")
    try:
        vm.guest(script)
    finally:
        archive_path = directory / "guest-results.tar"
        fetch = "tar -cf - -C " + shlex.quote(guest_dir) + " --exclude=runtime.sock --exclude='*.db*' ."
        with archive_path.open("wb") as archive:
            subprocess.run(vm.ssh_command("bash", "-c", fetch), stdout=archive, check=True)
        with tarfile.open(archive_path) as archive:
            archive.extractall(directory, filter="data")
        archive_path.unlink()
    if args.floating_maximum_restore:
        restored = json.loads((directory / "restore-maximum.json").read_text())
        if not restored or not all(entry.get("success") for entry in restored):
            raise RuntimeError("Sway did not confirm restoration of its floating-window limit")
    print(directory)


if __name__ == "__main__":
    main()
