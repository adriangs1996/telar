#!/usr/bin/env python3
"""Prepare CA rotation/recovery acceptance; alter user trust only with --live and its fingerprint."""

import argparse
import contextlib
import io
import json
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import sys
import time

import check_browser_trust as browser


def remember(root):
    directory = root / "authorities"
    directory.mkdir(mode=0o700, exist_ok=True)
    for source in [root / "ca/ca-system-cert.pem", *(root / "ca").glob("ca-system-cert.pem.rotate-*")]:
        try:
            if source.is_symlink() or source.stat().st_size > 16384: raise ValueError("Invalid fixture authority")
            sha1, _ = browser.fingerprints(source)
            destination = directory / (sha1 + ".pem")
            if not destination.exists():
                with destination.open("x") as output:
                    os.chmod(destination, 0o600)
                    output.write(source.read_text())
        except FileNotFoundError:
            continue
        except ValueError:
            if source.name == "ca-system-cert.pem": raise
    if len(list(directory.iterdir())) > 4: raise RuntimeError("CA rotation exceeded its bounded fixture authorities")


def operation(root, state, action, expected):
    script = "local t=require('telar.traffic'); t.ca." + action + "(function(err,r) assert(not err,err); assert(r.result==" + browser.lua_bytes(expected["result"].encode()) + ",r.message); assert(r.proxy.tls_accepting==" + str(expected["accepting"]).lower() + "); assert(r.ca.trust_record==" + browser.lua_bytes(expected["trust"].encode()) + "); print('ca-fingerprint='..r.ca.fingerprint_sha256:lower()); test_done() end)"
    label = "rotation-" + action + "-" + expected["result"]
    with browser.lua_probe(root, state, label, script) as probe:
        deadline = time.monotonic() + 120
        while True:
            remember(root)
            remaining = deadline - time.monotonic()
            if remaining <= 0: raise RuntimeError("CA rotation control timed out")
            try:
                output, errors = probe.communicate(timeout=min(.02, remaining))
                break
            except subprocess.TimeoutExpired:
                continue
        remember(root)
        fingerprints = re.findall(r"^ca-fingerprint=([0-9a-f]{64})$", output, re.MULTILINE)
        if probe.returncode != 0 or "packet verified" not in output or len(fingerprints) != 1:
            raise RuntimeError(f"CA {action} did not satisfy its expected state: {output} {errors}")
        return fingerprints[0]


@contextlib.contextmanager
def blocked_publication(root):
    active, saved = root / "ca/ca-active-cert.pem", root / "ca/fixture-active-cert.previous"
    if not active.is_file() or active.is_symlink() or saved.exists(): raise ValueError("Invalid publication-failure fixture")
    active.rename(saved)
    try:
        active.mkdir(mode=0o700)
        (active / "fixture-blocker").write_text("publication must fail\n")
        yield
    finally:
        (active / "fixture-blocker").unlink(missing_ok=True)
        active.rmdir()
        saved.rename(active)


def snapshot(root, state):
    browser.run([state["tls_probe"], "--system-leaf", root / "ca"], root, "rotation-leaf")
    sha1, sha256 = browser.fingerprints(root / "ca/ca-system-cert.pem")
    proof = root / "proofs" / sha256
    (proof / "ca").mkdir(mode=0o700, parents=True, exist_ok=True)
    for name in ("ca-system-cert.pem", "fixture-system-leaf.pem"):
        shutil.copy2(root / "ca" / name, proof / "ca" / name)
    remember(root)
    return proof, {**state, "sha1": sha1, "sha256": sha256}


def retired(proof, state):
    if browser.verify(proof) or browser.certificate_present(state):
        raise RuntimeError("A retired fixture CA remains trusted or stored")


def refused(root, state, port):
    script = "local t=require('telar.traffic'); local stop; stop=t.subscribe({events={flow=true}},function(err,e) assert(not err,err); if e.kind=='ready' then test_ready() elseif e.kind=='flow.error' and e.host==" + browser.lua_bytes(state["host"].encode()) + " then assert(e.reason=='tls_context_failed',e.reason); stop(); test_done() end end)"
    with browser.lua_probe(root, state, "suspended-probe", script) as probe:
        browser.ready(probe)
        _, error = browser.browser(root, state, port, "suspended")
        if not error: raise RuntimeError("The suspended signer accepted new browser TLS")
        output, errors = probe.communicate(timeout=10)
        if probe.returncode != 0 or "packet verified" not in output: raise RuntimeError("Missing suspended-signer failure event: " + errors)


def private_recovery(root, state, port):
    original = browser.fingerprints(root / "ca/ca-cert.pem")[1]
    with blocked_publication(root):
        active = operation(root, state, "rotate", {"result": "failed", "accepting": False, "trust": "absent"})
        if active != original or browser.fingerprints(root / "ca/ca-cert.pem")[1] == original:
            raise RuntimeError("The private-CA failure did not reach publication with the old signer retained")
        refused(root, state, port)
    current = operation(root, state, "rotate", {"result": "ok", "accepting": True, "trust": "absent"})
    if current == original or current != browser.fingerprints(root / "ca/ca-active-cert.pem")[1]: raise RuntimeError("Private CA recovery did not publish its new signer")
    if (root / "ca/trust-install.json").exists() or browser.certificate_present(state): raise RuntimeError("Private preparation unexpectedly installed OS trust")
    browser.phase(root, state, port, False)


def keychain_fingerprints(state):
    result = subprocess.run([browser.SECURITY, "find-certificate", "-a", "-Z", state["keychain"]], capture_output=True, text=True, check=True, timeout=15)
    if len(result.stdout) > 8 * 1024 * 1024: raise RuntimeError("Keychain listing exceeds its fixture bound")
    hashes = set(value.lower() for value in re.findall(r"SHA-1 hash:\s*([0-9A-Fa-f]{40})", result.stdout, re.IGNORECASE))
    if result.stdout.strip() and not hashes: raise RuntimeError("Unsupported keychain fingerprint listing")
    return hashes


def cleanup(root, state, baseline):
    remember(root)
    for certificate in sorted((root / "authorities").glob("*.pem")):
        sha1, sha256 = browser.fingerprints(certificate)
        if certificate.stem != sha1: raise ValueError("Fixture authority archive fingerprint mismatch")
        browser.run([browser.SECURITY, "remove-trusted-cert", certificate], root, "rotation-cleanup-trust-" + sha1, required=False, timeout=60)
        browser.run([browser.SECURITY, "delete-certificate", "-t", "-Z", sha1, state["keychain"]], root, "rotation-cleanup-cert-" + sha1, required=False, timeout=60)
        if browser.certificate_present({**state, "sha1": sha1, "sha256": sha256}): raise RuntimeError("A fixture CA remains in the login keychain")
        trusted = browser.run([browser.SECURITY, "verify-cert", "-L", "-l", "-p", "basic", "-c", certificate], root, "rotation-cleanup-verify-" + sha1, required=False)
        if trusted.returncode == 0: raise RuntimeError("A fixture CA still has native trust settings")
    for proof in (root / "proofs").iterdir():
        if browser.verify(proof): raise RuntimeError("A fixture CA remains trusted after cleanup")
    extra = keychain_fingerprints(state) - baseline
    if extra:
        (root / "unattributed-keychain-hashes.json").write_text(json.dumps(sorted(extra)))
        raise RuntimeError("New unattributed keychain certificates remain; they were not deleted. Inspect the preserved fingerprint list")


def live(root, state):
    if (root / "baseline.json").exists(): raise RuntimeError("A native attempt already exists; use --cleanup before preparing another fixture")
    baseline = keychain_fingerprints(state)
    with (root / "baseline.json").open("x") as output:
        os.chmod(root / "baseline.json", 0o600)
        output.write(json.dumps(sorted(baseline)) + "\n")
    attempted = failed = False
    try:
        original, original_state = snapshot(root, state)
        if original_state["sha256"] != state["sha256"] or not browser.verify(original, anchored=True) or browser.verify(original) or browser.certificate_present(state):
            raise RuntimeError("Prepared rotation CA is invalid or already trusted")
        with browser.runtime(root, state) as (_, port):
            try:
                attempted = True
                installed = operation(root, state, "install", {"result": "ok", "accepting": True, "trust": "installed"})
                if installed != state["sha256"] or not browser.verify(original): raise RuntimeError("The reviewed initial CA was not installed")
                browser.phase(root, state, port, True)
                changed = operation(root, state, "rotate", {"result": "ok", "accepting": True, "trust": "installed"})
                second, second_state = snapshot(root, state)
                if changed == installed or changed != second_state["sha256"] or not browser.verify(second): raise RuntimeError("Installed CA rotation did not synchronize native trust and signer")
                retired(original, original_state)
                browser.phase(root, state, port, True)
                with blocked_publication(root):
                    held = operation(root, state, "rotate", {"result": "failed", "accepting": False, "trust": "stale"})
                    third, third_state = snapshot(root, state)
                    if held != changed or third_state["sha256"] == changed or not browser.verify(third): raise RuntimeError("The installed CA fault did not reach publication with the old signer retained")
                    retired(second, second_state)
                    refused(root, state, port)
                repaired = operation(root, state, "install", {"result": "ok", "accepting": True, "trust": "installed"})
                if repaired != third_state["sha256"]: raise RuntimeError("CA retry did not adopt the already-installed replacement")
                browser.phase(root, state, port, True)
                operation(root, state, "uninstall", {"result": "ok", "accepting": True, "trust": "absent"})
                for proof, identity in [(original, original_state), (second, second_state), (third, third_state)]: retired(proof, identity)
                browser.phase(root, state, port, False)
            finally:
                remember(root)
                if (root / "ca/trust-install.json").exists():
                    try: operation(root, state, "uninstall", {"result": "ok", "accepting": True, "trust": "absent"})
                    except Exception as error: print("CA uninstall retry failed: " + str(error), file=sys.stderr)
        print("Installed CA rotation, real Chrome HTTPS rewriting, retired-CA rejection, suspended-signer failure, retry recovery and uninstall verified", flush=True)
    except Exception:
        failed = True
        print("CA rotation diagnostics preserved at " + str(root), file=sys.stderr)
        raise
    finally:
        if attempted:
            try: cleanup(root, state, baseline)
            except Exception as error:
                if not failed: raise
                (root / "cleanup-errors.log").write_text(str(error) + "\n")
                print("CA rotation cleanup failed: " + str(error), file=sys.stderr)
        if not failed: shutil.rmtree(root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("runtime", "lua-probe", "tls-probe", "browser", "prepared"): parser.add_argument("--" + name, type=pathlib.Path)
    parser.add_argument("--url", default="https://example.com")
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument("--live", action="store_true")
    actions.add_argument("--cleanup", action="store_true")
    parser.add_argument("--fingerprint")
    options = parser.parse_args()
    if os.geteuid() == 0: parser.error("Run as your ordinary account")
    if options.live or options.cleanup:
        if not options.prepared or not options.fingerprint: parser.error("--live/--cleanup require --prepared and --fingerprint")
        root, state = browser.prepared(options.prepared, options.fingerprint, "reviewed-ca.pem" if options.cleanup else "ca/ca-system-cert.pem")
        if state.get("rotation_fixture") != 1: parser.error("Prepare this rotation verifier before installing trust")
        if options.cleanup:
            source = root / "baseline.json"
            if source.exists():
                if source.is_symlink() or source.stat().st_size > 65536 or source.stat().st_uid != os.geteuid() or source.stat().st_mode & 0o077: raise ValueError("Invalid keychain baseline")
                entries = json.loads(source.read_text())
                if not isinstance(entries, list) or len(entries) > 1024 or any(not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{40}", value) for value in entries): raise ValueError("Invalid keychain fingerprint baseline")
                baseline = set(entries)
            else: baseline = keychain_fingerprints(state)
            cleanup(root, state, baseline)
            shutil.rmtree(root)
            print("Rotation fixture CA removal, trust rejection and private-directory cleanup verified", flush=True)
        else: live(root, state)
    else:
        if options.prepared or options.fingerprint or not all((options.runtime, options.lua_probe, options.tls_probe)): parser.error("Preparation requires the three executable paths")
        with contextlib.redirect_stdout(io.StringIO()): root = browser.prepare(options)
        try:
            state = json.loads((root / "prepared.json").read_text())
            shutil.copy2(root / "ca/ca-system-cert.pem", root / "reviewed-ca.pem")
            snapshot(root, state)
            with browser.runtime(root, state) as (_, port): private_recovery(root, state, port)
            state["rotation_fixture"] = 1
            (root / "prepared.json").write_text(json.dumps(state, indent=2) + "\n")
            print("Private CA publication failure, real browser TLS refusal, retry recovery and resumed certificate validation verified; no OS trust installed", flush=True)
            print("Rotation fixture: " + str(root) + "\nInitial CA SHA-256: " + state["sha256"], flush=True)
            command = [sys.executable, str(pathlib.Path(__file__).resolve()), "--prepared", str(root), "--live", "--fingerprint", state["sha256"]]
            print("Explicit initial install, two runtime-generated rotations, failure/recovery and removal:\n" + shlex.join(command), flush=True)
        except Exception:
            print("CA rotation preparation preserved at " + str(root), file=sys.stderr)
            raise


if __name__ == "__main__": main()
