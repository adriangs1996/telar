#!/usr/bin/env python3
"""Prepare a reviewable browser/CA fixture; install OS trust only with --live and its fingerprint."""

import argparse
import contextlib
import hashlib
import json
import os
import pathlib
import selectors
import shlex
import shutil
import ssl
import stat
import subprocess
import sys
import tempfile
import time
import urllib.parse

from check_traffic import lua_bytes


API = pathlib.Path(__file__).resolve().parents[2] / "desktop-mode/ui/api.lua"
SECURITY = "/usr/bin/security"


def run(arguments, root, label, required=True, timeout=30):
    result = subprocess.run(list(map(str, arguments)), capture_output=True, text=True, timeout=timeout)
    (root / (label + ".stdout")).write_text(result.stdout)
    (root / (label + ".stderr")).write_text(result.stderr)
    if required and result.returncode != 0:
        raise RuntimeError(f"{label} failed: {result.stderr}")
    return result


def fingerprints(certificate):
    encoded = ssl.PEM_cert_to_DER_cert(certificate.read_text())
    return hashlib.sha1(encoded).hexdigest(), hashlib.sha256(encoded).hexdigest()


def verify(root, anchored=False):
    arguments = [SECURITY, "verify-cert", "-L", "-p", "ssl", "-n", "validation.invalid", "-c", root / "ca/fixture-system-leaf.pem", "-c", root / "ca/ca-system-cert.pem"]
    if anchored: arguments.extend(["-r", root / "ca/ca-system-cert.pem"])
    return run(arguments, root, "verify-anchored" if anchored else "verify-system", required=False).returncode == 0


def certificate_present(state):
    result = subprocess.run([SECURITY, "find-certificate", "-a", "-Z", state["keychain"]], capture_output=True, text=True, timeout=15)
    if result.returncode != 0: raise RuntimeError("Cannot inspect the selected keychain: " + result.stderr)
    # Do not persist unrelated certificates' subjects or other keychain metadata.
    listing = result.stdout.lower()
    return state["sha1"] in listing or state["sha256"] in listing


@contextlib.contextmanager
def runtime(root, state):
    endpoint = root / "runtime.sock"
    configuration = root / "config.lua"
    configuration.write_text("return {api_version=2,runtime={proxy={enabled=true,network_capture=true,network_control=true,stream_interception=true,anonymous_tunnels=true,intercept_hosts={" + lua_bytes(state["host"].encode()) + "},capture={enabled=true},ca_dir='ca'}}}\n")
    with (root / "runtime.log").open("w") as log:
        server = subprocess.Popen([state["runtime"], "--socket", str(endpoint), "--config", str(configuration), "--history", ":memory:", "--no-session"], stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        try:
            record = root / "ca" / ("proxy-port-" + hashlib.sha256(str(endpoint).encode()).hexdigest()[:16])
            deadline = time.monotonic() + 15
            while not record.exists() or not pathlib.Path(str(endpoint) + ".network").exists():
                if server.poll() is not None or time.monotonic() >= deadline: raise RuntimeError("Browser test runtime did not start; see runtime.log")
                time.sleep(.01)
            port, recorded_endpoint = record.read_text().splitlines()
            if recorded_endpoint != str(endpoint) or not 0 < int(port) <= 65535: raise RuntimeError("Invalid private proxy port record")
            yield endpoint, int(port)
        finally:
            if server.poll() is None: server.terminate()
            try: server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait(timeout=5)


@contextlib.contextmanager
def lua_probe(root, state, label, script):
    source = root / (label + ".lua")
    source.write_text(script)
    process = subprocess.Popen([state["lua_probe"], str(root / "runtime.sock"), str(API), str(source)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env={**os.environ, "TELAR_TRAFFIC_PROBE_TIMEOUT_MS": "120000"})
    try:
        yield process
    finally:
        failed = sys.exc_info()[0] is not None
        try:
            if process.poll() is None: process.terminate()
            try: output, errors = process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                output, errors = process.communicate(timeout=5)
            (root / (label + ".stdout")).write_text(output)
            (root / (label + ".stderr")).write_text(errors)
        except (OSError, subprocess.TimeoutExpired) as error:
            if not failed: raise
            print(f"Browser Lua probe cleanup failed: {error}", file=sys.stderr)


def ready(process):
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        if not selector.select(10) or process.stdout.readline().strip() != "ready": raise RuntimeError("Browser Lua probe did not register")


def control(root, state, action):
    expected = state["sha256"] if action == "install" else fingerprints(root / "ca/ca-cert.pem")[1]
    script = "local t=require('telar.traffic'); t.ca." + action + "(function(err,r) assert(not err,err); assert(r.result=='ok',r.message); assert(r.proxy.tls_accepting); assert(r.ca.fingerprint_sha256:lower()==" + lua_bytes(expected.encode()) + "); assert(r.ca.trust_record=='" + ("installed" if action == "install" else "absent") + "'); test_done() end)"
    with lua_probe(root, state, "ca-" + action, script) as process:
        output, errors = process.communicate(timeout=120)
        if process.returncode != 0 or "packet verified" not in output: raise RuntimeError(f"Lua CA {action} failed: {output} {errors}")


def browser(root, state, port, label):
    from playwright.sync_api import Error, sync_playwright

    secret = (root / "ca/proxy-secret").read_text().strip()
    if len(secret) != 64 or any(character not in "0123456789abcdef" for character in secret): raise RuntimeError("Invalid private proxy credential")
    with sync_playwright() as playwright:
        instance = playwright.chromium.launch(executable_path=state["browser"], headless=True, chromium_sandbox=True, timeout=30000,
            ignore_default_args=["--use-mock-keychain"], proxy={"server": "http://127.0.0.1:" + str(port), "username": "telar", "password": secret})
        try:
            page = instance.new_page(ignore_https_errors=False)
            error = ""
            try: page.goto(state["url"], wait_until="domcontentloaded", timeout=30000)
            except Error as failure: error = str(failure)
            output = "" if error else page.content()
            (root / (label + ".html")).write_text(output)
            (root / (label + ".stderr")).write_text(error)
            return output, error
        finally:
            instance.close()


def phase(root, state, port, trusted):
    label = "trusted" if trusted else "untrusted"
    marker = "telar-browser-" + os.urandom(16).hex()
    script = "local t=require('telar.traffic'); local host=" + lua_bytes(state["host"].encode()) + "; local stop; "
    if trusted:
        body = ("<!doctype html><html><body>" + marker + "</body></html>").encode()
        script += "stop=t.intercept({stage='http',host=host,direction='inbound',failure='reject',timeout_ms=5000},function(err,e) assert(not err,err); if e.kind=='ready' then test_ready() end; if e.kind=='http.intercept.request' then assert(e.visibility=='plaintext'); return {action='replace',status=200,reason='OK',headers={{name='Content-Type',value='text/html; charset=utf-8'},{name='Cache-Control',value='no-store'}},body=" + lua_bytes(body) + "} end end)"
    else:
        script += "stop=t.subscribe({events={flow=true}},function(err,e) assert(not err,err); if e.kind=='ready' then test_ready() end; if e.kind=='flow.error' and e.host==host then assert(e.reason=='tls_client_handshake_failed',e.reason); stop(); test_done() end end)"
    with lua_probe(root, state, label + "-probe", script) as process:
        ready(process)
        output, browser_error = browser(root, state, port, label)
        if trusted:
            if browser_error or marker not in output or process.poll() is not None: raise RuntimeError("Browser did not receive the Lua-rewritten HTTPS response: " + browser_error)
        else:
            if "ERR_CERT_AUTHORITY_INVALID" not in browser_error: raise RuntimeError("Browser did not reach the expected certificate rejection: " + browser_error)
            stdout, errors = process.communicate(timeout=10)
            if process.returncode != 0 or "packet verified" not in stdout: raise RuntimeError("The runtime did not report the expected TLS client rejection: " + errors)


def cleanup(root, state):
    if not verify(root) and not certificate_present(state): return
    run([SECURITY, "remove-trusted-cert", root / "ca/ca-system-cert.pem"], root, "cleanup-user-trust", required=False, timeout=60)
    run([SECURITY, "delete-certificate", "-t", "-Z", state["sha1"], state["keychain"]], root, "cleanup-certificate", required=False, timeout=60)
    if verify(root) or certificate_present(state): raise RuntimeError("Temporary CA cleanup is incomplete; preserve this directory and its public certificate")


def prepare(options):
    root = pathlib.Path(tempfile.mkdtemp(prefix="tlr-browser-", dir="/tmp")).resolve()
    try:
        parsed = urllib.parse.urlsplit(options.url)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or len(options.url) > 2048: raise ValueError("Supply a bounded HTTPS URL without credentials")
        host = parsed.hostname.encode("idna").decode("ascii")
        browser_path = options.browser or next((path for name in ("Google Chrome", "Chromium", "Brave Browser", "Microsoft Edge") if (path := pathlib.Path("/Applications") / (name + ".app") / "Contents/MacOS" / name).is_file()), None)
        if browser_path is None: raise ValueError("Supply --browser with a Chromium browser executable")
        state = {name: str(getattr(options, name).resolve()) for name in ("runtime", "lua_probe", "tls_probe")}
        state.update(browser=str(browser_path.resolve()), url=options.url, host=host)
        for name in ("runtime", "lua_probe", "tls_probe", "browser"):
            if not os.access(state[name], os.X_OK): raise ValueError("Executable unavailable: " + state[name])
        authority = root / "ca"
        run([state["tls_probe"], "--system-authority", authority], root, "system-authority")
        record = json.loads((authority / "trust-install.json").read_text())
        sha1, sha256 = fingerprints(authority / "ca-system-cert.pem")
        if record["fingerprint"].lower() != sha1: raise RuntimeError("Generated authority fingerprint does not match its local fixture record")
        state.update(sha1=sha1, sha256=sha256, keychain=record["store_path"])
        # The generator uses an injected executor. Remove its simulated record
        # before any real runtime starts; no installation has happened.
        (authority / "trust-install.json").unlink()
        run([state["tls_probe"], "--system-leaf", authority], root, "system-leaf")
        if not verify(root, anchored=True) or verify(root) or certificate_present(state): raise RuntimeError("Prepared fixture does not have an isolated, valid and untrusted CA chain")
        state_path = root / "prepared.json"
        with state_path.open("x") as output:
            os.chmod(state_path, 0o600)
            json.dump(state, output, indent=2)
            output.write("\n")
        with runtime(root, state) as (_, port):
            phase(root, state, port, False)
        print("Browser rejection of the private interception CA and native untrusted-chain validation verified", flush=True)
        print("No OS trust was installed. Prepared fixture: " + str(root), flush=True)
        print("Temporary CA SHA-256: " + sha256, flush=True)
        command = [sys.executable, str(pathlib.Path(__file__).resolve()), "--prepared", str(root), "--live", "--fingerprint", sha256]
        print("Explicit install/browser/remove check:\n" + shlex.join(command), flush=True)
        return root
    except Exception:
        print("Browser preparation diagnostics preserved at " + str(root), file=sys.stderr)
        raise


def prepared(path, fingerprint, certificate_name="ca/ca-system-cert.pem"):
    if certificate_name not in ("ca/ca-system-cert.pem", "reviewed-ca.pem"): raise ValueError("Invalid prepared certificate selector")
    root = path.resolve()
    for item in (root, root / "prepared.json"):
        status = item.lstat()
        if status.st_uid != os.geteuid() or status.st_mode & 0o077 or item.is_symlink(): raise ValueError("Unsafe prepared browser fixture")
    source = root / "prepared.json"
    if not stat.S_ISDIR(root.stat().st_mode) or not stat.S_ISREG(source.stat().st_mode) or source.stat().st_size > 8192: raise ValueError("Invalid prepared browser fixture")
    state = json.loads(source.read_text())
    actual = fingerprints(root / certificate_name)
    expected = fingerprint.replace(":", "").lower()
    if expected != state["sha256"] or actual != (state["sha1"], state["sha256"]): raise ValueError("The explicit fingerprint does not match the prepared CA")
    keychain = str(pathlib.Path.home() / "Library/Keychains/login.keychain-db")
    if state["keychain"] != keychain: raise ValueError("Prepared CA targets a different keychain")
    return root, state


def live(root, state):
    attempted = failed = False
    try:
        run([state["tls_probe"], "--system-leaf", root / "ca"], root, "system-leaf")
        if not verify(root, anchored=True) or verify(root) or certificate_present(state): raise RuntimeError("Prepared CA is invalid or already installed; live check withheld")
        with runtime(root, state) as (_, port):
            try:
                attempted = True
                control(root, state, "install")
                if not verify(root) or not certificate_present(state): raise RuntimeError("CA installation did not establish native trust in the selected keychain")
                phase(root, state, port, True)
                control(root, state, "uninstall")
                if verify(root) or certificate_present(state): raise RuntimeError("The retired CA remains trusted or stored after uninstall")
                phase(root, state, port, False)
            finally:
                if attempted and (root / "ca/trust-install.json").exists():
                    try: control(root, state, "uninstall")
                    except Exception as error: print("Native CA uninstall retry failed: " + str(error), file=sys.stderr)
        print("Desktop Lua CA install/uninstall, real browser HTTPS rewriting, post-removal browser rejection and retired-CA trust removal verified", flush=True)
    except Exception:
        failed = True
        print("Browser trust diagnostics preserved at " + str(root), file=sys.stderr)
        raise
    finally:
        if attempted:
            try: cleanup(root, state)
            except Exception as error:
                if not failed: raise
                (root / "cleanup-errors.log").write_text(str(error) + "\n")
                print("Temporary CA cleanup failed: " + str(error), file=sys.stderr)
        if not failed: shutil.rmtree(root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=pathlib.Path)
    parser.add_argument("--lua-probe", type=pathlib.Path)
    parser.add_argument("--tls-probe", type=pathlib.Path)
    parser.add_argument("--browser", type=pathlib.Path)
    parser.add_argument("--url", default="https://example.com", help="Reachable HTTPS origin with a certificate the runtime already trusts")
    parser.add_argument("--prepared", type=pathlib.Path, help="Private fixture directory printed by preparation")
    actions = parser.add_mutually_exclusive_group()
    actions.add_argument("--live", action="store_true", help="Explicitly install and remove this temporary CA through Desktop Lua")
    actions.add_argument("--cleanup", action="store_true", help="Remove only this prepared CA's user trust/certificate and fixture directory")
    parser.add_argument("--fingerprint", help="Explicit SHA-256 of the prepared CA; required for live/cleanup")
    options = parser.parse_args()
    if os.geteuid() == 0: parser.error("Run as your ordinary account so the intended user's trust store is tested")
    if options.live or options.cleanup:
        if not options.prepared or not options.fingerprint: parser.error("--live/--cleanup require --prepared and --fingerprint")
        root, state = prepared(options.prepared, options.fingerprint)
        if options.cleanup:
            cleanup(root, state)
            shutil.rmtree(root)
            print("Prepared CA trust/certificate absence and fixture cleanup verified", flush=True)
        else: live(root, state)
    else:
        if options.prepared or options.fingerprint: parser.error("Prepared fixtures require an explicit --live or --cleanup action")
        if not all((options.runtime, options.lua_probe, options.tls_probe)): parser.error("Preparation requires --runtime, --lua-probe and --tls-probe")
        prepare(options)


if __name__ == "__main__":
    main()
