#!/usr/bin/env python3
"""Exercise the review widget with a real isolated agent and native AppKit input.

This calls a model unless --existing points at a running experiment. Even with
--existing, Send review makes the correction call. All GUI windows are closed.
"""

import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from review_live import request

FEEDBACK = ("Recorta los espacios de los extremos y colapsa cualquier secuencia de espacios "
            "o tabuladores en un solo guion. Conserva las minúsculas y Unicode.\n"
            'Por ejemplo, slugify("  Café  Mundo\\t ") debe devolver "café-mundo".')


def wait_file(path, seconds=180):
    deadline = time.monotonic() + seconds
    while not path.exists():
        if time.monotonic() >= deadline:
            raise TimeoutError(f"Missing experiment evidence: {path}")
        time.sleep(.1)


def native(binary, directory, library, actions, name):
    script = directory / (name + ".actions.json")
    script.write_text(json.dumps(actions))
    env = {key: value for key, value in os.environ.items() if not key.startswith("TELAR_")}
    env.update(TELAR_REVIEW_SOCKET=str(directory / "review.sock"), TELAR_GUI_ACTIONS=str(script),
               DYLD_INSERT_LIBRARIES=str(library))
    with (directory / (name + ".native.log")).open("w") as log:
        subprocess.run([str(binary), "gui"], env=env, stdout=log, stderr=log, timeout=210, check=True)


def exercise(binary, directory, library):
    socket_path = directory / "review.sock"
    initial = request(socket_path, dict(schema=1, action="load"))
    assert initial["status"] == "reviewable" and len(initial["revisions"]) == 1, initial
    assert initial["comments"] == [], initial
    actions = [{}, {}, {"text": "j"}, {"text": "j"}, {"text": "j"}, {"text": "v"}, {"text": "j"},
               {"capture": str(directory / "live-selection.png")}, {"text": "c"}, {}, {"text": FEEDBACK},
               {"expect_value": dict(label="Review comment", value=FEEDBACK)},
               {"key": "\r", "code": 36, "cmd": True}, {},
               {"capture": str(directory / "live-saved.png")}, {"click_label": "Send review"},
               {"wait": str(directory / "submission.json"), "wait_seconds": 20}, {},
               {"capture": str(directory / "live-delivery.png")}]
    native(binary, directory, library, actions, "submit")
    submitted = json.loads((directory / "submission.json").read_text())["request"]
    assert submitted["revision_id"] == initial["revisions"][0]["id"], submitted
    assert submitted["comments"] == [dict(file="slug.py", side="after", first_line=3, last_line=4, body=FEEDBACK)], submitted
    after_close = request(socket_path, dict(schema=1, action="load"))
    assert after_close["status"] in ("working", "complete"), after_close
    (directory / "after-window-close.json").write_text(json.dumps(after_close, ensure_ascii=False, indent=2))
    provider = json.loads((directory / "session.json").read_text())
    os.kill(provider["provider_pid"], 0)
    print("Native comment delivered with exact edition and lines 3–4; provider survived window close.", flush=True)

    actions = [{}, {}, {"wait": str(directory / "revision-1.json"), "wait_seconds": 150}, {}, {}, {}, {}, {},
               {"capture": str(directory / "live-returned.png")}, {"click_label": "Open edition 2"}, {}, {},
               {"capture": str(directory / "live-correction.png")}, {"click_label": "Back to edition 1"}, {},
               {"click_label": "Open"}, {}, {"click_label": "Edit"}, {},
               {"expect_value": dict(label="Review comment", value=FEEDBACK)},
               {"capture": str(directory / "live-original-comment.png")}]
    native(binary, directory, library, actions, "reconnect")
    final = request(socket_path, dict(schema=1, action="load"))
    assert final["status"] == "complete" and len(final["revisions"]) == 2, final
    assert final["session_id"] == initial["session_id"], final
    assert final["revisions"][0] == initial["revisions"][0], final
    assert final["comments"] == submitted["comments"], final
    revisions = [json.loads((directory / f"revision-{index}.json").read_text()) for index in range(2)]
    assert revisions[0]["after"] == revisions[1]["before"], revisions
    assert revisions[0]["turn_id"] != revisions[1]["turn_id"], revisions
    assert all(value["thread_id"] == initial["session_id"] and value["evidence"] for value in revisions), revisions
    before_turns = sorted(path.name for path in directory.glob("turn-*.json"))
    duplicate = request(socket_path, submitted)
    assert duplicate == final and before_turns == sorted(path.name for path in directory.glob("turn-*.json"))
    stale = dict(submitted, revision_id="stale-edition")
    assert request(socket_path, stale)["status"] == "error"
    verification = '''import runpy, sys
slugify = runpy.run_path(sys.argv[1])["slugify"]
for source, expected in [("  Café  Mundo\\t ", "café-mundo"), ("HELLO WORLD", "hello-world"), ("\\t A\\n B ", "a-b"), ("", "")]:
    assert slugify(source) == expected, (source, slugify(source), expected)
'''
    subprocess.run([sys.executable, "-B", "-c", verification, str(directory / "workspace" / "slug.py")], check=True)
    result = dict(success=True, session_id=initial["session_id"], turns=[value["turn_id"] for value in revisions],
                  revisions=[value["id"] for value in revisions], exact_range=[3, 4],
                  same_agent_session=True, native_feedback=True, correction_verified=True,
                  provider_survived_window_close=True, closed_during_correction=after_close["status"] == "working", original_comment_restored=True,
                  duplicate_did_not_repeat_turn=True, stale_revision_rejected=True,
                  capture="isolated single-writer turn snapshots", production_runtime_integrated=False,
                  unsent_drafts_persisted=False)
    (directory / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--existing", action="store_true", help="Use a running coordinator without taking ownership")
    args = parser.parse_args()
    directory = args.directory.resolve()
    binary = args.binary.resolve()
    coordinator = None
    try:
        if not args.existing:
            coordinator = subprocess.Popen([sys.executable, str(Path(__file__).with_name("review_live.py")), "start", str(directory)])
        wait_file(directory / "review.sock")
        library = directory / "driver.dylib"
        subprocess.run(["clang", "-dynamiclib", "-fobjc-arc", "-framework", "AppKit",
                        str(Path(__file__).with_name("gui_actions.m")), "-o", str(library)], check=True)
        exercise(binary, directory, library)
    finally:
        if coordinator:
            coordinator.send_signal(signal.SIGTERM)
            coordinator.wait(timeout=20)


if __name__ == "__main__":
    main()
