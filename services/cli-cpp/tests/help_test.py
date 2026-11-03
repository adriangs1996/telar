#!/usr/bin/env python3
"""Checks that `telar ... --help` prints each help/ text and finds help as the Zig CLI did."""
import argparse
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--telar", type=Path, required=True)
    parser.add_argument("--help-directory", type=Path, required=True)
    parser.add_argument("--version", required=True)
    arguments = parser.parse_args()
    environment = {key: value for key, value in os.environ.items() if not key.startswith("TELAR_")}
    environment["XDG_RUNTIME_DIR"] = "/nonexistent-telar-help-test"

    def run(*words):
        result = subprocess.run([str(arguments.telar), *words], capture_output=True, text=True, env=environment, timeout=10, stdin=subprocess.DEVNULL)
        return result.returncode, result.stdout

    def text(topic):
        return (arguments.help_directory / f"{topic}.txt").read_text().replace("@TELAR_VERSION@", arguments.version)

    topics = sorted(str(path.relative_to(arguments.help_directory))[:-4] for path in arguments.help_directory.rglob("*.txt"))
    for topic in topics:
        words = [] if topic == "telar" else topic.split("/")
        assert run(*words, "--help") == (0, text(topic)), topic

    assert run("-h") == (0, text("telar"))
    assert run("--help", "pane") == (0, text("telar"))
    assert run("pane", "-h") == (0, text("pane"))
    assert run("pane", "read", "--json", "--help") == (0, text("pane/read"))
    assert run("pane", "unknown-command", "--help") == (0, text("pane"))
    assert run("pane", "send-keys", "--", "--help")[1] != text("pane/send-keys")
    assert run("--version") == (0, f"telar {arguments.version}\n")
    print(f"{len(topics)} help topics passed")


if __name__ == "__main__":
    main()
