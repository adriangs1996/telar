#!/usr/bin/env python3
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import time

from check_clone_parity import environment_for
from check_legacy_checkpoints import text16


PROVIDERS = {"claude": 1, "codex": 2, "pi": 3, "cursor-agent": 4, "opencode": 5}
UUID = "01234567-89ab-cdef-0123-456789abcdef"
OPENCODE_SESSION = "ses_0123456789abABCDEFGHIJKLMN"


def session_for(provider):
    return OPENCODE_SESSION if provider == "opencode" else UUID


def checkpoint(root, panes):
    output = bytearray(b"TELARCKP" + struct.pack("<HQQQQ", 10, 2, 2, len(panes) + 1, 100))
    output += b"\x01" + struct.pack("<Q", 1) + text16(str(root / "workspace").encode()) + text16(b"Resume fixture")
    output += struct.pack("<Q", 1) + text16(b"Agents")
    for pane in panes:
        output += b"\x03" + struct.pack("<QQQ", pane["id"], 1, 1)
        output += text16(str(root / "workspace").encode()) + struct.pack("<HHH", 80, 24, len(pane["arguments"]))
        arguments = b"\0".join(argument.encode() for argument in pane["arguments"]) + b"\0"
        output += struct.pack("<I", len(arguments)) + arguments
        output += bytes([PROVIDERS[pane["provider"]]]) + text16(pane["session"].encode())
        output += text16(b"Restored title") + bytes([2, pane["in_pane"]])
    return output + b"\0"


def read_panes(data):
    offset = 42

    def number(format):
        nonlocal offset
        result, = struct.unpack_from("<" + format, data, offset)
        offset += struct.calcsize("<" + format)
        return result

    def text(format="H"):
        nonlocal offset
        length = number(format)
        result = data[offset:offset + length].decode()
        offset += length
        return result

    panes = []
    while kind := number("B"):
        if kind == 1:
            number("Q"), text(), text(), number("Q"), text()
        elif kind == 2:
            number("Q"), number("Q"), text()
        elif kind == 3:
            pane = dict(zip(("id", "workspace", "tab"), (number("Q") for _ in range(3))))
            pane.update(cwd=text(), columns=number("H"), rows=number("H"), argument_count=number("H"))
            pane.update(arguments=text("I").split("\0")[:-1], provider=number("B"), session=text(), title=text(), title_source=number("B"), in_pane=number("B"))
            panes.append(pane)
        else:
            raise AssertionError(f"Unexpected checkpoint record {kind}")
    assert offset == len(data)
    return sorted(panes, key=lambda pane: pane["id"])


def run(binary, probe, root, panes, enabled, label):
    runtime = root / "runtime"
    socket = runtime / "runtime.sock"
    environment = environment_for(runtime)
    environment.update(HOME=str(root / "home"), PATH=str(root / "bin") + os.pathsep + os.environ["PATH"],
                       CODEX_HOME=str(root / "codex"), RESUME_FIXTURE_OUTPUT=str(root / "output"))
    for path in (root / "output").iterdir():
        path.unlink()
    expected = root / "expected"
    expected.write_text("".join(f'{pane["id"]} {int(not pane["shell"] or pane["resumed"])}\n' for pane in panes))
    configuration = root / "resume.lua"
    configuration.write_text(f"return {{api_version=2, runtime={{session={{resume_agents={str(enabled).lower()}}}}}}}\n")
    command = [str(binary), "server", "--socket", str(socket), "--config", str(configuration)]
    with (root / f"{label}.log").open("w+") as log:
        server = subprocess.Popen(command, env=environment, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 15
            while not socket.exists():
                if server.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("Resume runtime did not start")
                time.sleep(0.01)
            result = subprocess.run([str(probe), str(socket), str(expected), str(root / "agents.bin")], env=environment,
                                    capture_output=True, text=True, timeout=30)
            assert result.returncode == 0, result.stderr
            server.wait(timeout=15)
            assert server.returncode == 0, f"Runtime exited {server.returncode}"
        except Exception as error:
            log.flush()
            log.seek(0)
            raise RuntimeError(f"{error}\n{log.read()}") from error
        finally:
            if server.poll() is None:
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()
    launched = {}
    for pane in panes:
        path = root / "output" / str(pane["id"])
        if pane["shell"] and not pane["resumed"]:
            assert not path.exists(), "Disabled or invalid session resumed"
            continue
        arguments = path.read_bytes().decode().split("\0")[:-1]
        arguments[0] = Path(arguments[0]).name
        expected_arguments = [pane["provider"], *pane["arguments"][1:]]
        if pane["resumed"]:
            flag = "resume" if pane["provider"] == "codex" else "--session" if pane["provider"] in ("pi", "opencode") else "--resume"
            expected_arguments = [pane["provider"], flag]
            if pane["provider"] == "codex" and pane["in_pane"]:
                expected_arguments.append("--no-daemon")
            expected_arguments.append(pane["session"])
        assert arguments == expected_arguments, (arguments, expected_arguments)
        launched[pane["id"]] = arguments
    restored = read_panes((runtime / "session.ckpt").read_bytes())
    assert len(restored) == len(panes), "Restart lost a restored pane"
    for original, saved in zip(sorted(panes, key=lambda pane: pane["id"]), restored):
        assert saved["arguments"] == original["arguments"], "Resume replaced the durable original launch"
        expected_session = original["session"] if original["resumed"] else ""
        assert saved["session"] == expected_session, (saved, expected_session)
    return {"arguments": launched, "checkpoint": restored, "agents": (root / "agents.bin").read_bytes().hex()}


def cases():
    for provider in PROVIDERS:
        for shell in (False, True):
            yield f"{provider}-{'shell' if shell else 'direct'}", provider, shell, True, True, False, False
        yield f"{provider}-disabled", provider, False, False, True, False, False
        yield f"{provider}-invalid", provider, False, True, False, False, False
    yield "codex-in-pane-direct", "codex", False, True, True, True, False
    yield "codex-in-pane-shell", "codex", True, True, True, True, False
    yield "claude-disabled-shell", "claude", True, False, True, False, False
    yield "claude-invalid-shell", "claude", True, True, False, False, False
    yield "claude-duplicate-session", "claude", False, True, True, False, True


def main():
    parser = argparse.ArgumentParser(description="Compare provider resume argv, live snapshots and durable launches across runtime restarts")
    for name in ("zig", "cpp", "probe", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--filter", default="")
    arguments = parser.parse_args()
    binaries = {name: getattr(arguments, name).resolve() for name in ("zig", "cpp", "probe")}
    report = {"checked_at": datetime.now(timezone.utc).isoformat(), "binaries": {
        name: {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
        for name, path in binaries.items()}, "cases": []}
    try:
        for name, provider, shell, enabled, valid, in_pane, duplicate in cases():
            if arguments.filter not in name:
                continue
            case = {"name": name, "sequences": {}}
            report["cases"].append(case)
            with tempfile.TemporaryDirectory(prefix="telar-resume-", dir="/tmp") as directory:
                root = Path(directory).resolve()
                for part in ("bin", "workspace", "runtime", "output", "home", "codex"):
                    (root / part).mkdir(mode=0o700)
                for executable in PROVIDERS:
                    shutil.copy2(binaries["probe"], root / "bin" / executable)
                original = ["/bin/sh", "-i"] if shell else [str(root / "bin" / provider), "--original"]
                panes = [{"id": index, "provider": provider, "session": session_for(provider) if valid else "not-a-session",
                          "shell": shell, "in_pane": in_pane, "arguments": original, "resumed": enabled and valid and index == 1}
                         for index in ([2, 1] if duplicate else [1])]
                seed = checkpoint(root, panes)
                for sequence in (("zig", "cpp"), ("cpp", "zig")):
                    destination = root / "runtime" / "session.ckpt"
                    destination.write_bytes(seed)
                    destination.chmod(0o600)
                    results = []
                    case["sequences"]["-".join(sequence)] = results
                    for index, implementation in enumerate(sequence):
                        results.append(run(binaries[implementation], binaries["probe"], root, panes, enabled, f"{'-'.join(sequence)}-{index}"))
                first, second = case["sequences"].values()
                assert first == second, f"{name}: runtime results differ"
                case["equal"] = True
                print(name, "passed", flush=True)
    except Exception as error:
        report["failure"] = str(error)
        raise
    finally:
        arguments.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
