#!/usr/bin/env python3
"""Run the native capture, redirect, crash-recovery and Lua hook checks together."""

import argparse
import pathlib
import re
import subprocess
import sys
import importlib.util


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=pathlib.Path, required=True)
    parser.add_argument("--lua-probe", type=pathlib.Path, required=True)
    parser.add_argument("--ssh-origin", help="Controlled LAN/Internet SSH host for a temporary echo origin")
    parser.add_argument("--ssh-address", help="Numeric IPv4 destination of that echo server")
    parser.add_argument("--bound-interface", help="Explicitly bind LAN capture/redirect test sockets to this macOS interface")
    parser.add_argument("--vpn-ssh-origin", help="Controlled VPN SSH host")
    parser.add_argument("--vpn-address", help="Numeric IPv4 destination reachable through the VPN")
    parser.add_argument("--vpn-interface", help="Expected routing interface for the VPN destination")
    parser.add_argument("--http2", action="store_true", help="Include independent HTTP/2 edit/stream checks; requires tools/requirements-network.txt")
    parser.add_argument("--selection", action="store_true", help="Also verify native process selection and Lua DNS destination activation")
    parser.add_argument("--incoming", action="store_true", help="Also verify incoming-only and combined TCP redirection; requires --ssh-origin")
    parser.add_argument("--interface-probe", type=pathlib.Path, help="Also verify virtual-interface creation/removal with the C++ traffic-interface-probe executable")
    options = parser.parse_args()
    if options.http2 and importlib.util.find_spec("h2") is None:
        parser.error("--http2 requires tools/requirements-network.txt in the test Python environment")
    vpn_options = (options.vpn_ssh_origin, options.vpn_address, options.vpn_interface)
    if any(vpn_options) and not all(vpn_options):
        parser.error("Supply --vpn-ssh-origin, --vpn-address and --vpn-interface together")
    if options.ssh_address and not options.ssh_origin:
        parser.error("--ssh-address requires --ssh-origin")
    if options.bound_interface and not options.ssh_origin:
        parser.error("--bound-interface requires --ssh-origin")
    if options.incoming and not options.ssh_origin:
        parser.error("--incoming requires a controlled --ssh-origin client")
    scripts = pathlib.Path(__file__).resolve().parent
    runtime = ["--runtime", str(options.runtime.resolve())]
    probe = ["--lua-probe", str(options.lua_probe.resolve())]
    subprocess.run(["sudo", "-v"], check=True)

    def run(name, *arguments):
        subprocess.run([sys.executable, str(scripts / name), *runtime, *arguments], check=True)

    remote = []
    if options.ssh_origin:
        remote = ["--ssh-origin", options.ssh_origin]
        if options.ssh_address:
            remote.extend(["--ssh-address", options.ssh_address])
        if options.bound_interface:
            remote.extend(["--bound-interface", options.bound_interface])

    run("check_traffic.py", *probe)
    run("check_traffic.py", *probe, "--fragments")
    run("check_traffic.py", *probe, "--datagrams")
    run("check_traffic.py", *probe, "--control")
    run("check_traffic.py", *probe, "--control-live", *(["--domain-selection"] if options.selection else []))
    run("check_traffic_workers.py", *probe)
    run("check_traffic_app_control.py", *probe)
    run("check_traffic_recordings.py", *probe)
    run("check_traffic_hooks.py", *probe)
    run("check_traffic_hooks.py", *probe, "--http")
    run("check_traffic_hooks.py", *probe, "--http-edit")
    if options.http2:
        run("check_traffic_hooks.py", *probe, "--http2-edit")
    interfaces = ["--interface-probe", str(options.interface_probe.resolve())] if options.interface_probe else []
    run("check_traffic_live.py", *probe, *remote, *interfaces)
    run("check_redirect.py", "--live", *remote)
    if options.selection:
        run("check_redirect.py", "--live", "--process-selection", *remote)
    if options.incoming:
        incoming = ["--ssh-client", options.ssh_origin]
        if options.ssh_address: incoming.extend(["--ssh-address", options.ssh_address])
        run("check_incoming.py", "--live", *incoming, "--direction", "inbound")
        run("check_incoming.py", "--live", *incoming)
    run("check_redirect_lifecycle.py")
    if options.vpn_ssh_origin:
        route = subprocess.run(["/sbin/route", "-n", "get", options.vpn_address], capture_output=True, text=True, check=True).stdout
        interface = re.search(r"^\s*interface:\s*(\S+)\s*$", route, re.MULTILINE)
        if not interface or interface[1] != options.vpn_interface:
            raise RuntimeError(f"VPN destination does not route through {options.vpn_interface}: {route}")
        print(f"VPN destination route verified: {options.vpn_interface}", flush=True)
        run("check_traffic_live.py", *probe, "--ssh-origin", options.vpn_ssh_origin, "--ssh-address", options.vpn_address, "--expected-interface", options.vpn_interface)
        run("check_redirect.py", "--live", "--ssh-origin", options.vpn_ssh_origin, "--ssh-address", options.vpn_address)
    else:
        print("VPN coverage not verified: no controlled VPN destination supplied", flush=True)
    print("All requested native checks passed", flush=True)


if __name__ == "__main__":
    main()
