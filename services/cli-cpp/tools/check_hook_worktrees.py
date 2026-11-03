#!/usr/bin/env python3
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def git(root, *arguments):
    return subprocess.run(["git", "-C", str(root), *arguments], check=True, capture_output=True).stdout


def run(binary, root):
    repository = root / "repo"
    repository.mkdir()
    git(repository, "init", "-b", "main")
    git(repository, "config", "user.name", "Hook Fixture")
    git(repository, "config", "user.email", "fixture@example.invalid")
    git(repository, "config", "commit.gpgsign", "false")
    (repository / "tracked").write_text("original\n")
    git(repository, "add", "tracked")
    git(repository, "commit", "-m", "Fixture")
    git(repository, "branch", "existing")
    environment = {key: value for key, value in os.environ.items() if not key.startswith("TELAR_")}
    environment["HOME"] = str(root)
    results = []

    def hook(name, payload):
        result = subprocess.run([str(binary), "hook", "claude"], input=json.dumps(payload).encode(),
                                env=environment, capture_output=True, timeout=15)
        results.append({"case": name, "status": result.returncode, "stdout": result.stdout.decode(), "stderr": result.stderr.decode()})
        return result

    try:
        checkout = root / "repo-worktrees" / "Fix-hooks"
        hook("create", {"hook_event_name": "WorktreeCreate", "cwd": str(repository), "name": "Fix hooks"})
        results.append({"case": "created", "exists": checkout.is_dir(), "tracked": (checkout / "tracked").read_text() if checkout.is_dir() else None})
        if checkout.is_dir():
            (checkout / "tracked").write_text("changed\n")
        hook("keep-dirty", {"hook_event_name": "WorktreeRemove", "worktree_path": str(checkout)})
        results.append({"case": "dirty-preserved", "exists": checkout.is_dir()})
        if checkout.is_dir():
            (checkout / "tracked").write_text("original\n")
        hook("remove-clean", {"hook_event_name": "WorktreeRemove", "worktree_path": str(checkout)})
        results.append({"case": "removed", "exists": checkout.exists()})
        hook("existing-branch", {"hook_event_name": "WorktreeCreate", "cwd": str(repository), "name": "existing"})
        existing = root / "repo-worktrees" / "existing"
        hook("nested-checkout", {"hook_event_name": "WorktreeCreate", "cwd": str(existing), "name": "nested/task"})
        nested = root / "repo-worktrees" / "nested-task"
        results.append({"case": "nested-is-sibling", "exists": nested.is_dir()})
        for path in (nested, existing):
            hook(f"remove-{path.name}", {"hook_event_name": "WorktreeRemove", "worktree_path": str(path)})
        hook("invalid-branch", {"hook_event_name": "WorktreeCreate", "cwd": str(repository), "name": "..."})
        hook("invalid-path", {"hook_event_name": "WorktreeRemove", "worktree_path": "relative"})
        hook("outside-repository", {"hook_event_name": "WorktreeCreate", "cwd": str(root), "name": "task"})
        return results
    finally:
        shutil.rmtree(root / "repo-worktrees", ignore_errors=True)
        shutil.rmtree(repository)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--zig", type=Path, required=True)
    parser.add_argument("--cpp", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    report = {"measured_at": datetime.now(timezone.utc).isoformat(), "binaries": {}, "results": {}}
    with tempfile.TemporaryDirectory(prefix="telar-hook-worktrees-", dir="/tmp") as directory:
        for implementation in ("zig", "cpp"):
            binary = getattr(arguments, implementation).resolve()
            report["binaries"][implementation] = {"path": str(binary), "sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
            report["results"][implementation] = run(binary, Path(directory))
    report["equal"] = report["results"]["zig"] == report["results"]["cpp"]
    arguments.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"cases": len(report["results"]["zig"]), "equal": report["equal"]}))
    raise SystemExit(not report["equal"])


if __name__ == "__main__":
    main()
