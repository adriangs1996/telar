#!/usr/bin/env python3
"""Exercise production review CLI and ordinary-pane hooks on an isolated runtime.

The pane runs a deterministic cooperative fixture recognized by a test-only
agent manifest. It sends official hook payloads to the real Telar executable;
there is no model call and no global hook or agent configuration change.
"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time

import headless_client
import perf_e2e

SESSION = "0192aaaa-bbbb-cccc-dddd-eeeeffff0000"
OTHER_SESSION = "0192aaaa-bbbb-cccc-dddd-eeeeffff0001"
FEEDBACK = "Trim and collapse whitespace, including tabs. Preserve café and 界."
BEFORE = "def slugify(label):\n    return label\n"
AFTER = 'def slugify(label):\n    lower = label.lower()\n    return lower.replace(" ", "-")\n'
CORRECTED = 'def slugify(label):\n    lower = label.lower()\n    return "-".join(lower.split())\n'


def atomic_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False))
    temporary.replace(path)


def wait_for(path, timeout=20):
    deadline = time.monotonic() + timeout
    while not path.exists():
        if time.monotonic() >= deadline:
            raise TimeoutError(f"Missing fixture response: {path}")
        time.sleep(.025)
    return json.loads(path.read_text())


def fixture(directory, binary):
    """Runs only inside the owned ordinary Telar pane."""
    atomic_json(directory / "identity.json", {key: value for key, value in os.environ.items()
                                             if key.startswith("TELAR_")})
    print("Cooperative review fixture ready", flush=True)
    heartbeat = 0.0
    while True:
        if time.monotonic() - heartbeat > .5:
            print("Review fixture waiting", flush=True)
            heartbeat = time.monotonic()
        for path in sorted((directory / "requests").glob("*.json")):
            request = json.loads(path.read_text())
            env = dict(os.environ, **request.get("environment", {}))
            completed = subprocess.run([str(binary), "hook", request["provider"]],
                                       input=json.dumps(request["payload"]), text=True,
                                       capture_output=True, env=env, timeout=8)
            atomic_json(directory / "responses" / path.name,
                        dict(code=completed.returncode, stdout=completed.stdout,
                             stderr=completed.stderr))
            path.unlink()
        time.sleep(.025)


class Runtime:
    def __init__(self, binary, directory, provider):
        self.binary = binary
        self.directory = directory
        self.provider = provider
        self.env = perf_e2e.isolated_environment(directory)
        self.workspace = directory / "workspace"
        self.workspace.mkdir()
        for name in ("requests", "responses", "codex"):
            (directory / name).mkdir(mode=0o700)
        self.env["CODEX_HOME"] = str(directory / "codex")
        self.config = directory / "config.lua"
        process_name = "Python" if sys.platform == "darwin" else Path(sys.executable).name
        self.config.write_text("return { api_version = 2, runtime = { agents = {{ name = "
                               + json.dumps(provider) + ", process_names = { " + json.dumps(process_name)
                               + " }, process_paths = { \"test_review_runtime.py\" } }} }, "
                               "client = { sidebar = { visible = false } } }\n")
        self.client = None
        self.sequence = 0
        self.launch = 0
        self.identity = {}

    def start(self):
        self.launch += 1
        (self.directory / "identity.json").unlink(missing_ok=True)
        self.client = headless_client.HeadlessClient(
            ["--config", self.config, "--fresh", sys.executable, Path(__file__).resolve(),
             "--fixture", self.directory, self.binary],
            env=self.env, cwd=self.workspace, size=(111, 35),
            log=self.directory / f"client-{self.launch}.log",
            binary=self.binary.with_name("telar-headless"),
        )
        self.identity = wait_for(self.directory / "identity.json")
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            self.hook("SessionStart")
            probe = self.cli("show", check=False)
            if probe.returncode == 0:
                return
            time.sleep(.25)
        raise AssertionError(f"Fixture identity never became reviewable: {probe.stderr}")

    def stop(self):
        if self.client is None:
            return
        try:
            shutdown = perf_e2e.stop_runtime(str(self.binary), self.env)
            atomic_json(self.directory / f"shutdown-{self.launch}.json", shutdown)
            assert shutdown["cleanup_complete"] and shutdown["children_exited"], shutdown
        finally:
            self.client.terminate()
            self.client = None

    def hook(self, event, tool="", tool_input=None, tool_id="", environment=None):
        self.sequence += 1
        name = f"{self.sequence:04}.json"
        payload = dict(hook_event_name=event, session_id=SESSION, cwd=str(self.workspace),
                       tool_name=tool, tool_use_id=tool_id, tool_input=tool_input or {})
        atomic_json(self.directory / "requests" / name,
                    dict(provider=self.provider, payload=payload, environment=environment or {}))
        response = wait_for(self.directory / "responses" / name)
        assert response["code"] == 0, response
        return response["stdout"]

    def cli(self, action, *arguments, check=True, environment=None):
        env = dict(self.env, **self.identity)
        env.update(environment or {})
        completed = subprocess.run([str(self.binary), "review", action, "--current", *map(str, arguments), "--json"],
                                   env=env, cwd=self.workspace, capture_output=True, text=True, timeout=10)
        if check:
            assert completed.returncode == 0, (action, arguments, completed.stderr)
            return json.loads(completed.stdout)
        return completed

    def edit(self, changes, tool_id):
        if self.provider == "codex":
            patch = "*** Begin Patch\n" + "".join(f"*** Update File: {name}\n@@\n-old\n+new\n" for name in changes) + "*** End Patch\n"
            tool, arguments = "apply_patch", dict(command=patch)
            self.hook("PreToolUse", tool, arguments, tool_id)
            for name, content in changes.items():
                (self.workspace / name).write_text(content)
            self.hook("PostToolUse", tool, arguments, tool_id)
            self.hook("PostToolUse", tool, arguments, tool_id)
        else:
            for index, (name, content) in enumerate(changes.items()):
                path = self.workspace / name
                arguments = dict(file_path=str(path), old_string=path.read_text(), new_string=content)
                identity = f"{tool_id}-{index}"
                self.hook("PreToolUse", "Edit", arguments, identity)
                path.write_text(content)
                self.hook("PostToolUse", "Edit", arguments, identity)
                self.hook("PostToolUse", "Edit", arguments, identity)


def exercise(runtime):
    runtime.start()
    workspace = runtime.workspace
    (workspace / "slug.py").write_text(BEFORE)
    (workspace / "notes.txt").write_text("before\n")
    (workspace / "unrelated.txt").write_text("user-owned unrelated edit\n")
    runtime.edit({"slug.py": AFTER, "notes.txt": "after\n"}, "initial-edit")
    listing = runtime.cli("list")
    assert len(listing) == 2, listing
    edition = runtime.cli("show", "--edition", 1)
    assert edition["session"] == SESSION, edition
    assert edition["source"] == "observed_snapshot" and edition["latest_edition_id"] == 2, edition
    assert "-    return label" in edition["patch"] and "+    lower = label.lower()" in edition["patch"], edition
    assert "unrelated" not in edition["patch"] and "notes.txt" not in edition["patch"], edition
    path = str(workspace / "slug.py")
    draft = runtime.cli("comment", "--edition", 1, "--file", path, "--first", 2, "--last", 3,
                        "--body", FEEDBACK, "--draft")
    assert draft["comments"][0]["draft"], draft
    assert runtime.cli("submit", "--edition", 1, check=False).returncode != 0
    assert runtime.cli("show", "--edition", 1)["comments"] == draft["comments"]
    comment_id = draft["comments"][0]["id"]
    stale = runtime.cli("comment", "--edition", 1, "--revision", edition["revision"], "--comment-id", comment_id,
                        "--file", path, "--first", 2, "--last", 3, "--body", "stale overwrite", check=False)
    assert stale.returncode != 0, stale.stdout
    saved = runtime.cli("comment", "--edition", 1, "--comment-id", comment_id, "--file", path,
                        "--first", 2, "--last", 3, "--body", FEEDBACK)
    assert not saved["comments"][0]["draft"] and saved["comments"][0]["last_line"] == 3
    submitted = runtime.cli("submit", "--edition", 1)
    assert submitted["delivery"] == "pending", submitted
    duplicate = runtime.cli("submit", "--edition", 1)
    assert duplicate["revision"] == submitted["revision"], duplicate
    identity = ("--provider", runtime.provider, "--session", SESSION)
    pending = runtime.cli("feedback", *identity)
    assert pending["feedback_id"] == 1 and FEEDBACK in pending["feedback"], pending
    assert runtime.cli("feedback", "--provider", runtime.provider, "--session", OTHER_SESSION, check=False).returncode != 0
    wrong_generation = dict(TELAR_PANE_GENERATION=str(int(runtime.identity["TELAR_PANE_GENERATION"]) + 1))
    assert runtime.cli("show", environment=wrong_generation, check=False).returncode != 0
    official = json.loads(runtime.hook("PreToolUse", "Bash", dict(command="true"), "feedback-receipt"))
    output = official["hookSpecificOutput"]
    assert output["hookEventName"] == "PreToolUse" and FEEDBACK in output["additionalContext"], official
    assert runtime.cli("feedback", *identity)["feedback_id"] == 0
    delivered = runtime.cli("show", "--edition", 1)
    assert delivered["delivery"] == "delivered", delivered
    ack = runtime.cli("ack", *identity, "--feedback-id", 1)
    assert ack["edition_id"] == 1 and ack["revision"] == delivered["revision"], ack
    runtime.edit({"slug.py": CORRECTED}, "correction")
    corrected = runtime.cli("show")
    assert corrected["edition_id"] == 3 and '+    return "-".join(lower.split())' in corrected["patch"], corrected
    assert runtime.cli("show", "--edition", 1)["patch"] == edition["patch"]
    namespace = {}
    exec((workspace / "slug.py").read_text(), namespace)
    assert namespace["slugify"]("  Café  Mundo\t ") == "café-mundo"
    for number in range(4, 21):
        runtime.edit({"notes.txt": f"Review iteration {number}.\n"}, f"archive-{number}")
    assert len(runtime.cli("list")) == 20
    assert runtime.cli("show", "--edition", 1)["patch"] == edition["patch"]
    archived = runtime.cli("comment", "--edition", 2, "--file", workspace / "notes.txt",
                           "--first", 1, "--body", "Keep this archived note.", "--draft")
    assert archived["edition_id"] == 2 and archived["comments"][0]["draft"], archived
    rejected = runtime.cli("reviewed", "--edition", 2, "--session", OTHER_SESSION, check=False)
    assert rejected.returncode != 0 and "current agent session" in rejected.stderr, rejected
    result = dict(provider=runtime.provider, ordinary_pane=True, official_hook_payloads=True,
                  deterministic_fixture=True, model_called=False, editions=20, exact_range=[2, 3],
                  drafts_retained=True, stale_revision_rejected=True, stale_generation_rejected=True,
                  wrong_session_rejected=True, duplicate_samples_deduplicated=True,
                  duplicate_submit_idempotent=True, official_additional_context=True,
                  older_feedback_acknowledged=True, original_edition_immutable=True,
                  unrelated_edits_excluded=True, correction_verified=True,
                  archived_editions_navigable=True, archived_edition_comment_saved=True,
                  wrong_session_mutation_rejected=True)
    runtime.stop()
    runtime.start()
    restored = runtime.cli("show", "--edition", 1)
    assert restored["patch"] == delivered["patch"] and restored["comments"] == delivered["comments"], restored
    assert restored["delivery"] == "delivered" and runtime.cli("show")["edition_id"] == 20
    assert runtime.cli("show", "--edition", 2)["comments"] == archived["comments"]
    result["runtime_restart_restored_comments_and_editions"] = True
    storage = list(runtime.directory.rglob("change-reviews/*.json"))
    assert len(storage) > 1, storage
    assert all(path.stat().st_mode & 0o077 == 0 for path in storage)
    result["private_storage"] = True
    atomic_json(runtime.directory / "result.json", result)
    print(json.dumps(result, indent=2), flush=True)
    return result


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "--fixture":
        fixture(Path(sys.argv[2]), Path(sys.argv[3]))
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("directory", type=Path, help="New artifact directory; must not exist")
    parser.add_argument("--provider", choices=("codex", "claude"), default="codex")
    args = parser.parse_args()
    binary = args.binary.resolve()
    directory = args.directory.resolve()
    if directory.exists():
        parser.error("the artifact directory must be new")
    runtime = Runtime(binary, directory, args.provider)
    try:
        exercise(runtime)
    finally:
        runtime.stop()


if __name__ == "__main__":
    main()
