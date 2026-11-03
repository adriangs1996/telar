#!/usr/bin/env python3
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile


PROVIDERS = {
    "claude": (".claude", "settings.json", "CLAUDE_CONFIG_DIR"),
    "codex": (".codex", "hooks.json", "CODEX_HOME"),
    "cursor": (".cursor", "hooks.json", "CURSOR_CONFIG_DIR"),
    "pi": (".pi/agent", "extensions/telar.ts", "PI_CODING_AGENT_DIR"),
    "opencode": (".config/opencode", "plugins/telar.ts", "XDG_CONFIG_HOME"),
}


def identity(path):
    return {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def put(path, contents, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(contents.encode() if isinstance(contents, str) else contents)
    path.chmod(mode)


def normalize(text, root, binary):
    return text.replace(str(binary), "@EXECUTABLE@").replace(str(root), "@ROOT@")


def snapshot(root, binary):
    result = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            result[str(path.relative_to(root))] = {"symlink": normalize(os.readlink(path), root, binary)}
        elif path.is_file():
            raw = path.read_bytes()
            text = normalize(raw.decode("utf-8", errors="backslashreplace"), root, binary)
            try:
                content = json.loads(text) if path.suffix == ".json" else text
            except (json.JSONDecodeError, ValueError):
                content = text
            result[str(path.relative_to(root))] = {"content": content, "mode": stat.S_IMODE(path.stat().st_mode)}
    return result


def run_case(binary, provider, variant, seed, actions):
    with tempfile.TemporaryDirectory(prefix="telar-integration-", dir="/tmp") as temporary:
        root = Path(temporary).resolve()
        home = root / "home"
        home.mkdir(mode=0o700)
        directory, filename, variable = PROVIDERS[provider]
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith(("TELAR_", "XDG_")) and key not in {entry[2] for entry in PROVIDERS.values()}}
        environment.update(HOME=str(home), TMPDIR=str(root))
        settings = home / directory / filename
        extra = []
        if variant in ("override", "legacy", "same-legacy", "relative-override", "missing-home"):
            if variant == "relative-override":
                environment[variable] = "relative"
                override = root / "relative"
            else:
                environment[variable] = str(root / "configured")
                override = root / "configured"
            if provider == "opencode":
                override /= "opencode"
            if provider != "cursor":
                settings = override / filename
        if variant == "missing-home":
            environment.pop("HOME")
        if variant == "explicit":
            settings = root / "explicit" / filename
            extra = ["--settings", str(settings)]

        if seed is not None:
            put(settings, seed)
        if variant == "symlink":
            target = root / "dotfiles" / filename
            put(target, seed or "{}", mode=0o640)
            settings.parent.mkdir(parents=True, exist_ok=True)
            settings.unlink(missing_ok=True)
            settings.symlink_to(target)
        if variant in ("legacy", "same-legacy"):
            legacy = home / directory / filename
            put(legacy, json.dumps({"hooks": {"Stop": [{"hooks": [{"command": f"old hook {provider}"}]}]}}))
            if variant == "same-legacy":
                settings.parent.mkdir(parents=True, exist_ok=True)
                settings.symlink_to(legacy)
        if variant == "foreign-skills":
            for skill in ("telar", "telar-coordinator"):
                put(settings.parent / "skills" / skill / "SKILL.md", "User skill, keep it\n", mode=0o644)

        results = []
        for action in actions:
            command = [str(binary), "integration", action, provider, *extra]
            if variant in ("legacy", "same-legacy") and action == "uninstall":
                command.append("--legacy")
            result = subprocess.run(command, cwd=root, env=environment, capture_output=True, text=True, timeout=20)
            files = snapshot(root, binary)
            results.append({"action": action, "exit": result.returncode,
                            "stdout": normalize(result.stdout, root, binary),
                            "stderr": normalize(result.stderr, root, binary), "files": files})
        return results


def main():
    parser = argparse.ArgumentParser(description="Compare integration CLI outcomes and preserved provider files in private homes")
    parser.add_argument("--zig", type=Path, required=True)
    parser.add_argument("--cpp", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    arguments.zig = arguments.zig.resolve()
    arguments.cpp = arguments.cpp.resolve()
    scenarios = []
    lifecycle = ["status", "install", "install", "status", "uninstall", "status", "uninstall"]
    for provider in PROVIDERS:
        for variant in ("default", "override", "explicit", "relative-override"):
            scenarios.append((provider, variant, None, lifecycle))
        if provider in ("pi", "opencode"):
            scenarios.append((provider, "default", "// foreign user integration\n", ["status", "install", "uninstall"]))
            scenarios.append((provider, "default", f"// telar-integration: {provider}\nold source\n", lifecycle))
        else:
            for seed in ("[]", "{", '{"duplicate":1,"duplicate":2}', '{"unknown":{"nested":1,"nested":2}}',
                         '{"hooks":false}', '{"hooks":{"Stop":null,"stop":null}}', '{"version":false}',
                         '{"custom":{"text":"λ\\ntext","array":[1,null,true]},"hooks":{}}'):
                scenarios.append((provider, "default", seed, ["status", "install", "uninstall"]))
            scenarios.append((provider, "symlink", '{"custom":"preserved"}', lifecycle))
            scenarios.append((provider, "foreign-skills", "{}", lifecycle))
            if provider != "cursor":
                scenarios.append((provider, "legacy", "{}", ["status", "uninstall", "status"]))
                scenarios.append((provider, "same-legacy", None, ["status", "uninstall", "status"]))
                scenarios.append((provider, "missing-home", "{}", lifecycle))
            hook = {"command": f"old hook {provider}", "timeout": 91}
            foreign = {"command": "echo keep", "custom": True}
            event = "stop" if provider == "cursor" else "Stop"
            entries = [hook, foreign] if provider == "cursor" else [{"matcher": "*", "hooks": [hook, foreign, hook]}, {"hooks": []}, {"other": 1}]
            scenarios.append((provider, "default", json.dumps({"hooks": {event: entries}}), lifecycle))

    for label, seed in (
            ("settings-at-limit", b"{}" + b" " * (4 * 1024 * 1024 - 2)),
            ("settings-under-limit", b"{}" + b" " * (4 * 1024 * 1024 - 3)),
            ("large-object", json.dumps({f"field-{index}": index for index in range(10000)})),
            ("nested-settings", '{"nested":' + '[' * 120 + '0' + ']' * 120 + '}'),
            ("invalid-utf8", b'{"nested":"\xff"}')):
        scenarios.append(("claude", label, seed, ["status", "install", "uninstall"]))

    report = {"checked_at": datetime.now(timezone.utc).isoformat(), "binaries": {name: identity(getattr(arguments, name)) for name in ("zig", "cpp")},
              "normalization": "Executable and private-home paths; JSON file formatting. Exit status, stdout, structured file contents, permissions and symlinks must match. Error wording is retained separately.",
              "cases": [], "passed": False}
    try:
        for index, (provider, variant, seed, actions) in enumerate(scenarios):
            outcomes = {label: run_case(binary, provider, variant, seed, actions)
                        for label, binary in (("zig", arguments.zig), ("cpp", arguments.cpp))}
            differences = []
            for action_index, (zig, cpp) in enumerate(zip(outcomes["zig"], outcomes["cpp"])):
                for key in ("exit", "stdout", "files"):
                    if zig[key] != cpp[key]:
                        differences.append({"action": action_index, "field": key})
            report["cases"].append({"name": f"{index}-{provider}-{variant}", "equal": not differences, "differences": differences, **outcomes})
            print(f"{index + 1}/{len(scenarios)} {provider}/{variant}: {len(differences)} differences", flush=True)
        report["passed"] = all(case["equal"] for case in report["cases"])
    except Exception as error:
        report["failure"] = str(error)
        raise
    finally:
        arguments.output.write_text(json.dumps(report, indent=2) + "\n")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
