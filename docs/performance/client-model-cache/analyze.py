#!/usr/bin/env python3
"""Summarize touchrange windows: distinct cache lines and pages per window,
bytes used against bytes loaded, and the fields behind each line.

usage: analyze.py STEM [--against STEM_B] [--fields WINDOW] [--range ID] [--json OUT]
STEM.err holds the probe's TRL/TRB/TRD lines and STEM.vg the tool's TR lines,
both written by trace.sh. With --against, prints A and B side by side per
window and checks that both sessions sent the same bytes.
"""
import argparse
import json
import re
from collections import defaultdict

RANGES = {0: "Client", 1: "TerminalAdapter", 2: "Pane"}
PAGE_NORMAL = 16384


def load(stem):
    layout = defaultdict(list)
    bases = {}
    digest = None
    with open(stem + ".err") as f:
        for line in f:
            if line.startswith("TRL "):
                _, path, off, size = line.split()
                root = path.split(".")[0]
                layout[root].append((path, int(off), int(size)))
            elif line.startswith("TRB "):
                _, rid, base, size = line.split()
                bases[int(rid)] = (int(base), int(size))
            elif line.startswith("TRD "):
                digest = line.split()[1:]
    windows = {}
    current = None
    with open(stem + ".vg") as f:
        for line in f:
            m = re.search(r"TR (window|run|end) (.*)$", line)
            if not m:
                continue
            kind, rest = m.groups()
            if kind == "window":
                current = rest.strip()
                windows[current] = defaultdict(list)
            elif kind == "run":
                rid, off, n, rw = rest.split()
                windows[current][int(rid)].append((int(off), int(n), rw))
    return layout, bases, windows, digest


def shift_for(rid, bases):
    # Ranges 0 and 1 live in one heap block (the adapter embeds the client);
    # normalize so the adapter starts a 16 KiB page, as a macOS mmap would.
    if rid in (0, 1) and 1 in bases:
        return bases[1][0] % PAGE_NORMAL
    return 0


def summarize(runs, base, shift):
    used = read = written = 0
    lines = {64: set(), 128: set()}
    pages = {4096: set(), 16384: set()}
    for off, n, rw in runs:
        used += n
        if "r" in rw:
            read += n
        if "w" in rw:
            written += n
        start = base - shift + off
        for size, bucket in list(lines.items()) + list(pages.items()):
            for unit in range(start // size, (start + n - 1) // size + 1):
                bucket.add(unit)
    return {
        "used": used,
        "read": read,
        "written": written,
        "lines64": len(lines[64]),
        "lines128": len(lines[128]),
        "pages4k": len(pages[4096]),
        "pages16k": len(pages[16384]),
        "loaded128": len(lines[128]) * 128,
        "loaded64": len(lines[64]) * 64,
    }


def leaf(entries, off):
    best = None
    for path, start, size in entries:
        if start <= off < start + size:
            if best is None or path.count(".") > best[0].count(".") or (
                path.count(".") == best[0].count(".") and size < best[2]
            ):
                best = (path, start, size)
    return best


def fields(runs, entries, base, shift):
    per = defaultdict(lambda: {"bytes": 0, "lines": set(), "rw": set()})
    for off, n, rw in runs:
        for o in range(off, off + n):
            f = leaf(entries, o)
            name = f[0] if f else "?"
            per[name]["bytes"] += 1
            per[name]["lines"].add((base - shift + o) // 128)
            per[name]["rw"].add(rw)
    return per


def table(bases, windows):
    out = {}
    for name, per_range in windows.items():
        out[name] = {}
        for rid in sorted(RANGES):
            if rid in bases:
                out[name][RANGES[rid]] = summarize(per_range.get(rid, []), bases[rid][0], shift_for(rid, bases))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stem")
    ap.add_argument("--against")
    ap.add_argument("--fields")
    ap.add_argument("--range", type=int, default=0)
    ap.add_argument("--json")
    args = ap.parse_args()
    layout, bases, windows, digest = load(args.stem)
    out = table(bases, windows)
    if args.against:
        _, bases_b, windows_b, digest_b = load(args.against)
        out_b = table(bases_b, windows_b)
        print(f"output A {digest}\noutput B {digest_b}\n{'identical' if digest == digest_b else 'DIFFERENT'}")
        print(f"{'window':24} {'range':15} {'L128 A':>7} {'L128 B':>7} {'P16K A':>7} {'P16K B':>7} {'used A':>7} {'used B':>7}")
        for name in out:
            for rng, a in out[name].items():
                b = out_b.get(name, {}).get(rng)
                if b is None:
                    continue
                print(f"{name:24} {rng:15} {a['lines128']:7} {b['lines128']:7} {a['pages16k']:7} {b['pages16k']:7} {a['used']:7} {b['used']:7}")
    else:
        print(f"output {digest}")
        print(f"{'window':24} {'range':15} {'L128':>5} {'L64':>5} {'P16K':>5} {'P4K':>5} {'used':>6} {'loaded':>7} {'eff':>5}")
        for name in out:
            for rng, s in out[name].items():
                eff = s["used"] / s["loaded128"] if s["loaded128"] else 0
                print(f"{name:24} {rng:15} {s['lines128']:5} {s['lines64']:5} {s['pages16k']:5} {s['pages4k']:5} {s['used']:6} {s['loaded128']:7} {eff:5.2f}")
    if args.json:
        with open(args.json, "w") as f:
            json.dump(out, f, indent=1)
    if args.fields:
        rid = args.range
        entries = layout[RANGES[rid]]
        per = fields(windows[args.fields].get(rid, []), entries, bases[rid][0], shift_for(rid, bases))
        print(f"\nfields of {RANGES[rid]} touched by {args.fields}")
        for name, v in sorted(per.items(), key=lambda kv: min(kv[1]["lines"])):
            off = min(v["lines"]) * 128 - bases[rid][0] + shift_for(rid, bases)
            print(f"  {name:70} {v['bytes']:6}B {len(v['lines']):3} lines  {''.join(sorted(v['rw']))}  ~line at {off}")


if __name__ == "__main__":
    main()
