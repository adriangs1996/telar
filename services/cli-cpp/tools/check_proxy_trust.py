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
import time


def identify(path):
    return {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def invoke(binary, arguments, environment):
    result = subprocess.run([str(binary), *map(str, arguments)], env=environment,
                            capture_output=True, text=True, timeout=20)
    return {"exit": result.returncode, "stdout": result.stdout, "stderr": result.stderr}


def check(arguments, report):
    with tempfile.TemporaryDirectory(prefix="telar-proxy-trust-", dir="/tmp") as temporary:
        root = Path(temporary).resolve()
        environment = {key: value for key, value in os.environ.items() if not key.startswith("TELAR_")}
        environment.update(HOME=str(root / "home"), TMPDIR=str(root))
        for kind in ("DATA", "CONFIG", "CACHE", "STATE"):
            environment[f"XDG_{kind}_HOME"] = str(root / kind.lower())
        environment["XDG_RUNTIME_DIR"] = str(root / "run")
        (root / "home").mkdir(mode=0o700)
        (root / "run").mkdir(mode=0o700)
        authority = root / "proxy"
        fixture = invoke(arguments.tls_probe, ["--system-authority", authority], environment)
        if fixture["exit"]:
            raise RuntimeError(f"Cannot prepare simulated trust record: {fixture}")
        originals = {entry.name: entry.read_bytes() for entry in authority.iterdir()}
        record = json.loads(originals["trust-install.json"])

        def reset():
            if authority.exists() or authority.is_symlink():
                if authority.is_symlink():
                    authority.unlink()
                else:
                    shutil.rmtree(authority)
            authority.mkdir(mode=0o700)
            for name, data in originals.items():
                (authority / name).write_bytes(data)
                (authority / name).chmod(0o600)

        def compare(name, command, exact_stdout=True):
            results = {label: invoke(binary, command, environment)
                       for label, binary in (("zig", arguments.zig), ("cpp", arguments.cpp))}
            equal = results["zig"]["exit"] == results["cpp"]["exit"]
            if exact_stdout:
                equal = equal and results["zig"]["stdout"] == results["cpp"]["stdout"]
            report["cases"].append({"name": name, "equal": equal, **results})
            return equal

        def status(name):
            return compare(name, ["proxy", "trust", "status", "--ca-dir", authority])

        if not status("installed"):
            raise RuntimeError("Generated authority is not accepted equally; install tests withheld")
        compare("already-installed", ["proxy", "trust", "install", "--ca-dir", authority])
        for version in (1.0, "1", "+1", "01", "1.0", 0, 2, 256, -1, True, None):
            reset()
            (authority / "trust-install.json").write_text(json.dumps({**record, "version": version}))
            status(f"version-{version!r}")

        for key in record:
            reset()
            (authority / "trust-install.json").write_text(json.dumps({name: value for name, value in record.items() if name != key}))
            status(f"missing-{key}")

        variants = {
            "lowercase-fingerprint": {**record, "fingerprint": record["fingerprint"].lower()},
            "different-fingerprint": {**record, "fingerprint": "0" * 40},
            "short-fingerprint": {**record, "fingerprint": "0" * 39},
            "nonhex-fingerprint": {**record, "fingerprint": "g" * 40},
            "linux-backend": {**record, "backend": "update-ca-certificates"},
            "trust-backend": {**record, "backend": "trust"},
            "unknown-backend": {**record, "backend": "unknown"},
            "different-store": {**record, "store_path": "/another/keychain"},
            "relative-store": {**record, "store_path": "relative"},
            "empty-store": {**record, "store_path": ""},
            "unknown-field": {**record, "unknown": 1},
        }
        for name, value in variants.items():
            reset()
            (authority / "trust-install.json").write_text(json.dumps(value))
            status(name)

        for name, data in (("empty-record", b""), ("truncated-record", b'{"version":'),
                           ("invalid-utf8", b'{"version":1,"backend":"\xff"}'),
                           ("duplicate-field", originals["trust-install.json"].replace(b'"version": 1,', b'"version": 1,"version": 1,')),
                           ("record-limit", originals["trust-install.json"] + b" " * (4096 - len(originals["trust-install.json"]))),
                           ("record-over-limit", b" " * 4097)):
            reset()
            (authority / "trust-install.json").write_bytes(data)
            status(name)

        for name in originals:
            reset()
            (authority / name).unlink()
            status(f"missing-file-{name}")
            reset()
            (authority / name).chmod(0o644)
            status(f"public-file-{name}")
            reset()
            (authority / name).rename(root / f"saved-{name}")
            (authority / name).symlink_to(root / f"saved-{name}")
            status(f"symlink-file-{name}")

        reset()
        authority.chmod(0o755)
        status("public-directory")
        reset()
        (authority / "trust-install.json").write_bytes(b"invalid")
        for action in ("install", "uninstall"):
            compare(f"invalid-record-{action}", ["proxy", "trust", action, "--ca-dir", authority])
        (authority / "trust-install.json").unlink()
        status("absent-record")
        compare("uninstall-absent", ["proxy", "trust", "uninstall", "--ca-dir", authority])
        shutil.rmtree(authority)
        status("absent-directory")

        for action in ("status", "install", "uninstall"):
            compare(f"relative-directory-{action}", ["proxy", "trust", action, "--ca-dir", "relative"])
        for command in ([], ["trust"], ["trust", "unknown"], ["trust", "status", "--ca-dir"],
                        ["trust", "status", "--ca-dir", ""], ["trust", "status", "--linux", "unknown"],
                        ["trust", "install", "--linux", "trust", "--ca-dir", str(authority)]):
            compare(f"invalid-arguments-{command}", ["proxy", *command], exact_stdout=False)

        compare("default-directory", ["proxy", "trust", "status"])
        environment["XDG_DATA_HOME"] = "relative"
        compare("relative-xdg", ["proxy", "trust", "status"])
        environment["XDG_DATA_HOME"] = str(root / "data")

        reset()
        configuration = root / "proxy.lua"
        configuration.write_text('return {api_version=2,runtime={session={persist=false},proxy={enabled=true,ca_dir=' + json.dumps(str(authority)) + '}}}\n')
        outputs = []
        for label, binary in (("zig", arguments.zig), ("cpp", arguments.cpp)):
            endpoint = root / f"{label}.sock"
            with (root / f"{label}.log").open("w+") as log:
                server = subprocess.Popen([str(binary), "server", "--socket", str(endpoint), "--config", str(configuration)],
                                          env=environment, stdout=log, stderr=log)
                try:
                    deadline = time.monotonic() + 15
                    while not endpoint.exists():
                        if server.poll() is not None or time.monotonic() > deadline:
                            log.seek(0)
                            raise RuntimeError(f"{label} system authority startup failed: {log.read()}")
                        time.sleep(0.01)
                    output = root / f"{label}.bin"
                    result = invoke(arguments.proxy_probe, [endpoint, "proxy-system-status", "1", output], environment)
                    if result["exit"]:
                        raise RuntimeError(f"{label} system authority protocol failed: {result}")
                    outputs.append(output.read_bytes())
                    for name, expected in originals.items():
                        if (authority / name).read_bytes() != expected:
                            raise RuntimeError(f"{label} modified valid system authority: {name}")
                finally:
                    if server.poll() is None:
                        server.terminate()
                    try:
                        server.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        server.kill()
                        server.wait()
        report["cases"].append({"name": "runtime-system-authority", "equal": outputs[0] == outputs[1],
                                "sha256": [hashlib.sha256(output).hexdigest() for output in outputs]})


def main():
    parser = argparse.ArgumentParser(description="Compare proxy trust records and runtime CA selection without altering OS trust")
    for name in ("zig", "cpp", "tls-probe", "proxy-probe", "output"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    arguments = parser.parse_args()
    for name in ("zig", "cpp", "tls_probe", "proxy_probe"):
        setattr(arguments, name, getattr(arguments, name).resolve())
    report = {"checked_at": datetime.now(timezone.utc).isoformat(),
              "binaries": {name: identify(getattr(arguments, name)) for name in ("zig", "cpp", "tls_probe", "proxy_probe")},
              "os_trust_modified": False, "cases": [], "passed": False}
    try:
        check(arguments, report)
        report["passed"] = all(case["equal"] for case in report["cases"])
    except Exception as error:
        report["failure"] = str(error)
        raise
    finally:
        arguments.output.write_text(json.dumps(report, indent=2) + "\n")
    differences = [case["name"] for case in report["cases"] if not case["equal"]]
    print(json.dumps({"cases": len(report["cases"]), "differences": differences}))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
