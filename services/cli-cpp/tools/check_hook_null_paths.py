#!/usr/bin/env python3
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

from check_hook_worktrees import git


def run(binary, root):
    repository = root / "repo"
    repository.mkdir(exist_ok=True)
    git(repository, "init", "-b", "main")
    git(repository, "config", "user.name", "Hook Fixture")
    git(repository, "config", "user.email", "fixture@example.invalid")
    git(repository, "config", "commit.gpgsign", "false")
    git(repository, "commit", "--allow-empty", "-m", "Fixture")
    environment = {key: value for key, value in os.environ.items() if not key.startswith("TELAR_")}
    environment["HOME"] = str(root)

    def hook(payload):
        result = subprocess.run([str(binary), "hook", "claude"], input=json.dumps(payload).encode(), env=environment, capture_output=True, timeout=15)
        return {"status": result.returncode, "stdout": result.stdout.decode(errors="replace"), "stderr": result.stderr.decode(errors="replace")}

    checkout = root / "repo-worktrees" / "null-cwd"
    created = hook({"hook_event_name": "WorktreeCreate", "cwd": str(repository) + "\0/suffix", "name": "null-cwd"})
    created["checkout_created"] = checkout.exists()
    if checkout.exists():
        git(repository, "worktree", "remove", "--", str(checkout))
        git(repository, "branch", "-D", "null-cwd")

    protected = root / "protected-checkout"
    git(repository, "worktree", "add", "-b", "protected", "--", str(protected), "main")
    removed = hook({"hook_event_name": "WorktreeRemove", "worktree_path": str(protected) + "\0/suffix"})
    removed["checkout_preserved"] = protected.exists()
    if protected.exists():
        git(repository, "worktree", "remove", "--", str(protected))
    git(repository, "branch", "-D", "protected")
    return {"create": created, "remove": removed}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--zig", type=Path, required=True)
    parser.add_argument("--cpp", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    report = {"checked_at": datetime.now(timezone.utc).isoformat(), "binaries": {}, "results": {}}
    for implementation in ("zig", "cpp"):
        binary = getattr(arguments, implementation).resolve()
        report["binaries"][implementation] = {"path": str(binary), "sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
        with tempfile.TemporaryDirectory(prefix="telar-hook-null-", dir="/tmp") as directory:
            report["results"][implementation] = run(binary, Path(directory))
    cpp = report["results"]["cpp"]
    report["cpp_safe"] = cpp["create"]["status"] == 1 and not cpp["create"]["checkout_created"] and cpp["remove"]["status"] == 1 and cpp["remove"]["checkout_preserved"]
    arguments.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
    raise SystemExit(not report["cpp_safe"])


if __name__ == "__main__":
    main()
