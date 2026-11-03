#!/usr/bin/env python3
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import tempfile

from check_hook_cli import run_case
from check_hook_worktrees import git


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--zig", type=Path, required=True)
    parser.add_argument("--cpp", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    report = {"checked_at": datetime.now(timezone.utc).isoformat(), "binaries": {}, "cases": [], "differences": []}
    for implementation in ("zig", "cpp"):
        binary = getattr(arguments, implementation).resolve()
        report["binaries"][implementation] = {"path": str(binary), "sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
    with tempfile.TemporaryDirectory(prefix="telar-hook-register-", dir="/tmp") as directory:
        root = Path(directory)
        repository = root / "repo"
        repository.mkdir()
        git(repository, "init", "-b", "main")
        git(repository, "config", "user.name", "Hook Fixture")
        git(repository, "config", "user.email", "fixture@example.invalid")
        git(repository, "config", "commit.gpgsign", "false")
        git(repository, "commit", "--allow-empty", "-m", "Fixture")
        cases = [("registered", {}, None), ("descent-refused", {}, 0x42), ("registration-refused", {}, 0x3c),
                 ("zero-generation", {"TELAR_PANE_GENERATION": "0"}, None), ("missing-generation", {"TELAR_PANE_GENERATION": None}, None),
                 ("invalid-generation", {"TELAR_PANE_GENERATION": "bad"}, None), ("zero-pane", {"TELAR_PANE_ID": "0"}, None),
                 ("zero-workspace", {"TELAR_WORKSPACE_ID": "0"}, None)]
        for name, environment, refusal in cases:
            case = {"provider": "claude", "refusal": refusal, "environment": {"TELAR_WORKSPACE_ID": "5", **environment},
                    "input": {"hook_event_name": "WorktreeCreate", "cwd": str(repository), "name": "fixture"}}
            result = {"name": name}
            for implementation in ("zig", "cpp"):
                result[implementation], _ = run_case(getattr(arguments, implementation).resolve(), root, case)
                checkout = root / "repo-worktrees" / "fixture"
                result[implementation]["checkout_exists"] = checkout.is_dir()
                if checkout.is_dir():
                    git(repository, "worktree", "remove", "--", str(checkout))
                git(repository, "branch", "-D", "fixture")
            result["equal"] = result["zig"] == result["cpp"]
            report["cases"].append(result)
            if not result["equal"]:
                report["differences"].append(name)
            arguments.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"cases": len(report["cases"]), "differences": report["differences"]}))
    raise SystemExit(bool(report["differences"]))


if __name__ == "__main__":
    main()
