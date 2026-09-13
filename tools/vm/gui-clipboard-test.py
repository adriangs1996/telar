#!/usr/bin/env python3
"""Verify copy-mode yank and native paste against the Wayland clipboard."""

import argparse
import importlib.util
from pathlib import Path
import secrets
import shlex
import time


def load_driver():
    path = Path(__file__).with_name("gui-multiplexer-test.py")
    spec = importlib.util.spec_from_file_location("telar_gui_multiplexer", path)
    driver = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(driver)
    return driver


def expect_clipboard(window, expected):
    deadline = time.monotonic() + 5
    actual = ""
    while time.monotonic() < deadline:
        actual = window.guest('timeout 2 wl-paste --no-newline --type "$1"',
                              "text/plain;charset=utf-8")
        if actual == expected:
            break
        time.sleep(0.05)
    if actual != expected:
        raise AssertionError(f"Copy-mode UTF-8 clipboard mismatch: {actual!r} != {expected!r}")

    plain = window.guest('timeout 2 wl-paste --no-newline --type text/plain')
    if plain != expected:
        raise AssertionError(f"Copy-mode plain clipboard mismatch: {plain!r} != {expected!r}")


def round_trip(window, sample, marker):
    window.guest('printf %s "$1" | wl-copy --type text/plain;charset=utf-8', "stale-" + marker)
    # Leave the terminal cursor immediately after the marker, with no prompt.
    # End in copy mode selects the final nonblank cell, not the cursor's blank.
    command = "PS1=; printf '\\033[2J\\033[H%s' " + shlex.quote(marker)
    window.type(command)
    window.key("Return")
    time.sleep(0.25)
    window.action("[")
    window.key("Home")
    window.type("v")
    window.key("End")
    window.screenshot(sample + "-selection")
    window.type("y")
    expect_clipboard(window, marker)
    window.step(sample + " copy-mode yank publishes exact UTF-8 and plain clipboard bytes")

    destination = window.state + "/" + sample + "-pasted"
    command = "IFS= read -r clipboard_value; printf '%s' \"$clipboard_value\" > " + shlex.quote(destination)
    window.type(command)
    window.key("Return")
    window.key("v", "ctrl", "shift")
    window.key("Return")
    actual = window.guest('''
for attempt in {1..100}; do
    if test -s "$state/$1"; then cat "$state/$1"; exit 0; fi
    sleep .05
done
printf 'No native paste receipt: %s\\n' "$1" >&2
exit 1
''', sample + "-pasted")
    if actual != marker:
        raise AssertionError(f"Native paste changed clipboard bytes: {actual!r} != {marker!r}")
    window.step(sample + " Ctrl-Shift-V pastes the same bytes into the child")


def run(driver, arguments, mode):
    window = driver.Window(mode, arguments.output, arguments.binary)
    try:
        window.setup()
        first = window.mark("initial")
        marker = "telar-copy-" + secrets.token_hex(8)
        round_trip(window, "ascii", marker)
        window.same_pane(first, "after-ascii-copy-paste", same_size=True)
        round_trip(window, "unicode", marker + "-café-λ")
        window.same_pane(first, "after-unicode-copy-paste", same_size=True)
        window.guest('! grep -E "Validation Error|VUID-|clipboard failed|native input capacity exceeded" "$state/gui.log"')
        window.step("same shell and PTY geometry survive both clipboard round trips")
        window.collect("passed")
    except Exception as error:
        window.collect("failed", str(error))
        try:
            window.screenshot("failure")
        except Exception:
            pass
        raise
    finally:
        window.cleanup()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", nargs="?", type=Path, default=Path(".zig-out/gui-clipboard-test"))
    parser.add_argument("--skip-build", action="store_true", help="use the prepared guest binary without syncing or building")
    parser.add_argument("--binary", default="zig-out/bin/telar", help="guest executable, absolute or relative to its source directory")
    parser.add_argument("--mode", choices=("default", "configured", "both"), default="both")
    arguments = parser.parse_args()
    arguments.output = arguments.output.resolve()
    driver = load_driver()
    driver.vm.require_running()
    if not arguments.skip_build:
        driver.vm.sync()
        driver.vm.build()
    for mode in (("default", "configured") if arguments.mode == "both" else (arguments.mode,)):
        run(driver, arguments, mode)


if __name__ == "__main__":
    main()
