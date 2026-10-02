#!/usr/bin/env python3
"""Arithmetic audit of ledger.json. Reads no Telar binary and runs no probe.

Usage: python3 docs/performance/resource-inventory/verify.py
"""
import json
import pathlib
import sys

ledger = json.loads((pathlib.Path(__file__).parent / "ledger.json").read_text())
records = {record["id"]: record["inline"] for record in ledger["records"]}
failures = []


def check(name, actual, expected):
    status = "ok" if actual == expected else "FAIL"
    if actual != expected:
        failures.append(name)
    print(f"{status:4} {name}: {actual:,} (expected {expected:,})")


def text_metadata(rows):
    return 11 + rows + 256 * 6 + 2048 * 10 + 64 * 1024


def client_pane(cols, rows):
    return records["model.Pane"] + 32 * cols * rows + 4 * rows + 24 + text_metadata(rows)


def scene_quads(cells):
    return 24 * (cells + min(cells, 4200) + min(cells, 384) + min(cells, 1544)) + cells


# Constants restated by the README.
check("text metadata fixed capacity", text_metadata(0), ledger["constants"]["text_metadata_capacity_fixed"]["value"])
check("retained cell bytes", 52 + 2 * 80 + 22 * 80, 1972)

# P2: ClientModel live storage and allocation counts.
archived = {0: (2087088, 1), 1: (2175200, 6), 8: (2791984, 41), 64: (7726256, 321)}
for panes, (bytes_, allocations) in archived.items():
    check(f"P2 ClientModel + {panes} 1x1 panes", records["model.ClientModel"] + panes * client_pane(1, 1), bytes_)
    check(f"P2 allocations for {panes} panes", 1 + 5 * panes, allocations)

check("client pane 1x1", client_pane(1, 1), 88112)
check("GUI 17 client slots", ledger["constants"]["machine_slots"]["value"] * records["client.Client"], records["gui.clients_array"])
check("Client exclusive inline", records["client.Client"] - records["model.ClientModel"], 822448)

# P3: geometry delta between the 73x40 and 153x40 renderer fixtures.
small, large = 73 * 40, 153 * 40
delta = 80 * (scene_quads(large) - scene_quads(small)) + 1972 * (large - small) + 2 * 32 * (large - small)
check("P3 renderer delta", delta, 40595286 - 25222486)

# Inline residuals must stay non-negative.
for owner in ("runtime.Pane", "runtime.Attachment", "runtime.Session"):
    items = ledger["inline_breakdown"][owner]
    exact = sum(item["bytes"] for item in items if item["status"] == "exact")
    estimated = sum(item["bytes"] for item in items if item["status"] == "estimate")
    residual = records[owner] - exact - estimated
    print(f"info {owner}: exact {exact:,}, estimated {estimated:,}, residual {residual:,} of {records[owner]:,}")
    if residual < 0:
        failures.append(f"{owner} residual")

# Admission formulas restated by the README.
check("pane fixed requested part", records["runtime.Pane"] + 2 * text_metadata(0), 1011822)
check("attachment fixed requested part", records["runtime.Attachment"] + 2 * text_metadata(0), 217662)
check("session requested", records["runtime.Session"] + 2 * 4194304 + 65536, 9550400)
check("machine client external", 2 * 4194304 + 65536 + 80 * 8192 + 786432 + 2 * 65536, 10027008)

for cols, rows in ((80, 24), (153, 40)):
    pane = 1011822 + 32 * cols * rows + 3 * rows
    attachment = 217662 + 64 * cols * rows + 3 * rows
    replica = client_pane(cols, rows)
    copies = 5 * text_metadata(rows)
    print(
        f"info {cols}x{rows}: pane {pane:,} + attachment {attachment:,} + client replica {replica:,}"
        f" = {pane + attachment + replica:,}; text metadata copies {copies:,}"
        f" ({100 * copies / (pane + attachment + replica):.1f}%)"
    )

if failures:
    print("failed:", ", ".join(failures))
    sys.exit(1)

print("all checks passed")
