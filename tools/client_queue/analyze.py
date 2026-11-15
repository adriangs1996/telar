#!/usr/bin/env python3
"""Compare the client queue traces that measure.py kept for two sides.

For every run it reads the queue-<pid>.bin files (one per runtime that ran) and reports, per side:

- at stop(): the bytes and frames queued to each client before RuntimeStopping, the age of the oldest
  queued frame, whether a frame was half written, and whether RuntimeStopping was still queued after the
  one write() (the "Runtime closed the connection" loss);
- per queued frame: the time from being queued to its last byte leaving in a write();
- per busy period of a queue: the time from non-empty to empty;
- write() results: partial writes and EAGAIN;
- publish(): the time each call takes before its loop over the clients, by phase;
- for the client of runtime #0 (in server-cli, checkpoint-probe seed, which waits for four replies): the
  frames written before its first pane frame, and how many pane frames went out between the replies rather
  than after the last one, right before stop().

Distributions get median, p95, p99 and maximum. Differences are tested with a two-sided Mann-Whitney U
(normal approximation with tie correction) on independent units: one value per stop, or one statistic per
run for the frame latencies, whose frames within a run are not independent; pooled tests are shown as well.
Counts use Fisher's exact test.
"""
import argparse
from collections import defaultdict
import json
import math
from pathlib import Path
import random
import re
import struct

RECORD = struct.Struct("<QQIIIIBBHI")
KINDS = ("message", "dropped", "drain", "snapshot", "write", "stop_request", "mismatch", "publish")
LANES = ("stopping", "management", "resync", "clipboard", "layout", "proxy", "shell", "scrollback", "cells",
         "agents", "metrics", "workspaces", "panes", "cwd", "foreground", "title", "progress", "git", "blocks",
         "exit", "graphics", "document", "observation", "count")


def lane_names(path):
    """The DeliveryLane enumerators, in order, from the source file that declares the enum."""
    match = re.search(r"enum class DeliveryLane[^{]*\{([^}]*)\}", Path(path).read_text())
    if match is None:
        raise SystemExit(f"{path}: no DeliveryLane enum")
    body = re.sub(r"//[^\n]*", "", match.group(1))
    return tuple(name.strip() for name in body.split(",") if name.strip())


PUBLISH_PHASES = (("admissions, clipboard and media", "bytes"), ("panes", "extra"), ("executions", "mask"),
                  ("observations, deferred reports, agents and detection", "queue"),
                  ("worktrees, workspaces, session, metrics, git and queued notices", "frames"))
EAGAIN = 35 if __import__("sys").platform == "darwin" else 11
STOPPING_FRAME = 5


def records(path):
    data = path.read_bytes()
    for offset in range(0, len(data) - len(data) % RECORD.size, RECORD.size):
        first, second, size, extra, mask, queue, kind, lane, phase, frames = RECORD.unpack_from(data, offset)
        yield {"first": first, "second": second, "bytes": size, "extra": extra, "mask": mask, "queue": queue,
               "kind": KINDS[kind] if kind < len(KINDS) else f"kind{kind}", "lane": lane, "phase": phase, "frames": frames}


def runtimes(run):
    """The runtimes of one run in the order they started."""
    loaded = []
    for path in run.glob("queue-*.bin"):
        items = list(records(path))
        if items:
            loaded.append(items)

    loaded.sort(key=lambda items: min(item["first"] or item["second"] for item in items))
    return loaded


def quantile(values, fraction):
    if not values:
        return float("nan")
    ordered = sorted(values)
    position = fraction * (len(ordered) - 1)
    lower = math.floor(position)
    upper = min(lower + 1, len(ordered) - 1)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


def describe(values):
    return {"n": len(values), "median": quantile(values, 0.5), "p95": quantile(values, 0.95),
            "p99": quantile(values, 0.99), "max": max(values) if values else float("nan"),
            "mean": sum(values) / len(values) if values else float("nan")}


def mann_whitney(first, second):
    """Two-sided Mann-Whitney U; returns U of the first sample, P(first > second) + P(tie) / 2 and p."""
    n1, n2 = len(first), len(second)
    if n1 == 0 or n2 == 0:
        return {"u": float("nan"), "superiority": float("nan"), "p": float("nan")}
    combined = sorted([(value, 0) for value in first] + [(value, 1) for value in second])
    ranks = [0.0] * len(combined)
    ties = 0.0
    index = 0
    while index < len(combined):
        end = index
        while end + 1 < len(combined) and combined[end + 1][0] == combined[index][0]:
            end += 1
        rank = (index + end) / 2 + 1
        for position in range(index, end + 1):
            ranks[position] = rank
        count = end - index + 1
        ties += count ** 3 - count
        index = end + 1

    rank_sum = sum(rank for rank, (_, group) in zip(ranks, combined) if group == 0)
    u = rank_sum - n1 * (n1 + 1) / 2
    total = n1 + n2
    variance = n1 * n2 / 12 * ((total + 1) - ties / (total * (total - 1)))
    if variance <= 0:
        return {"u": u, "superiority": u / (n1 * n2), "p": 1.0}
    z = (u - n1 * n2 / 2) / math.sqrt(variance)
    return {"u": u, "superiority": u / (n1 * n2), "z": z, "p": math.erfc(abs(z) / math.sqrt(2))}


def fisher(a, b, c, d):
    """Two-sided Fisher exact test for [[a, b], [c, d]]."""
    def logp(x):
        return (math.lgamma(a + b + 1) + math.lgamma(c + d + 1) + math.lgamma(a + c + 1) + math.lgamma(b + d + 1)
                - math.lgamma(x + 1) - math.lgamma(a + b - x + 1) - math.lgamma(a + c - x + 1)
                - math.lgamma(d - a + x + 1) - math.lgamma(a + b + c + d + 1))
    low = max(0, a + c - (c + d))
    high = min(a + b, a + c)
    observed = logp(a)
    total = sum(math.exp(logp(x)) for x in range(low, high + 1) if logp(x) <= observed + 1e-9)
    return min(1.0, total)


def bootstrap_difference(first, second, statistic, rounds=2000, seed=11):
    """Percentile 95% interval of statistic(first) - statistic(second), resampling units."""
    generator = random.Random(seed)
    differences = []
    for _ in range(rounds):
        left = [generator.choice(first) for _ in first]
        right = [generator.choice(second) for _ in second]
        differences.append(statistic(left) - statistic(right))
    return [quantile(differences, 0.025), quantile(differences, 0.975)]


def ordering(items, queue, lanes_of, replies=4):
    """Pane frames of runtime #0's stopping client against its request replies, or None."""
    snapshot = next((item for item in items if item["kind"] == "snapshot" and item["phase"] == 0 and item["queue"] == queue), None)
    messages = sorted((item for item in items if item["queue"] == queue and item["kind"] == "message"), key=lambda item: item["second"])
    names = [lanes_of[item["lane"]] if item["lane"] < len(lanes_of) else str(item["lane"]) for item in messages]
    answered = [index for index, name in enumerate(names) if name == "management"]
    if snapshot is None or len(answered) < replies:
        return None

    last = messages[answered[replies - 1]]["second"]
    first_cells = names.index("cells") if "cells" in names else len(names)
    cells = [item for item, name in zip(messages, names) if name == "cells" and item["second"] < snapshot["second"]]
    return {
        "before_first_cells": [name for name in names[:first_cells] if name != "management"],
        "between_replies": sum(name != "management" for name in names[answered[0]:answered[replies - 1]]),
        "cells_between_replies": sum(item["second"] < last for item in cells),
        "bytes_after_last_reply": sum(item["bytes"] for item in messages if last < item["second"] < snapshot["second"]),
        "lost": snapshot["bytes"] > 0,
    }


def collect(directory, side, lanes_of=LANES):
    stops = defaultdict(list)
    runs = []
    for run in sorted((directory / side).glob("b*-*")):
        outcome = json.loads((run / "outcome.json").read_text())
        frames = []
        drains = []
        lanes = defaultdict(list)
        writes = {"total": 0, "partial": 0, "eagain": 0}
        publishes = defaultdict(list)
        mismatches = 0
        order_of_seed = None
        for order, items in enumerate(runtimes(run)):
            requested = [item["first"] for item in items if item["kind"] == "stop_request"]
            snapshots = defaultdict(dict)
            for item in items:
                kind = item["kind"]
                if kind == "message":
                    latency = item["second"] - item["first"]
                    frames.append(latency)
                    lanes[lanes_of[item["lane"]] if item["lane"] < len(lanes_of) else str(item["lane"])].append(latency)
                elif kind == "drain":
                    drains.append(item["second"] - item["first"])
                elif kind == "write":
                    writes["total"] += 1
                    writes["partial"] += 0 < item["extra"] < item["bytes"]
                    writes["eagain"] += item["mask"] == EAGAIN
                elif kind == "snapshot":
                    snapshots[item["queue"]][item["phase"]] = item
                elif kind == "mismatch":
                    mismatches += 1
                elif kind == "publish":
                    publishes["before clients"].append(item["second"] - item["first"])
                    for phase, field in PUBLISH_PHASES:
                        publishes[phase].append(item[field])

            if order == 0 and len(snapshots) == 1:
                order_of_seed = ordering(items, next(iter(snapshots)), lanes_of)

            for queue, phases in snapshots.items():
                before = phases.get(0)
                after = phases.get(2)
                if before is None or after is None:
                    continue
                stops[order].append({
                    "run": run.name,
                    "outcome": outcome["outcome"],
                    "queued_bytes": before["bytes"],
                    "queued_frames": before["frames"] & 0xFFFF,
                    "deferred": before["frames"] >> 16,
                    "half_written": before["extra"],
                    "oldest_age": before["second"] - before["first"] if before["first"] else 0,
                    "left_after_write": after["bytes"],
                    "lost_stopping": after["bytes"] >= STOPPING_FRAME,
                    "stop_delay": before["second"] - requested[0] if requested else None,
                    "lanes": [lanes_of[index] for index in range(len(lanes_of)) if before["mask"] >> index & 1],
                    "active_lane": lanes_of[before["lane"]] if before["lane"] < len(lanes_of) else str(before["lane"]),
                })

        runs.append({"run": run.name, "outcome": outcome["outcome"], "frames": frames, "drains": drains,
                     "lanes": lanes, "writes": writes, "mismatches": mismatches, "ordering": order_of_seed,
                     "publishes": publishes})
    return stops, runs


def compare(label, first, second, names):
    left = describe(first)
    right = describe(second)
    test = mann_whitney(first, second)
    print(f"  {label}")
    for name, values in ((names[0], left), (names[1], right)):
        print(f"    {name:>5}: n={values['n']:<7} median={values['median']:<12.6g} p95={values['p95']:<12.6g} p99={values['p99']:<12.6g} max={values['max']:<12.6g} mean={values['mean']:.6g}")
    print(f"    Mann-Whitney: P({names[0]} > {names[1]}) = {test['superiority']:.3f}, p = {test['p']:.3g}")
    return {"label": label, names[0]: left, names[1]: right, "mann_whitney": test}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("directory", type=Path, help="a measure.py --out directory")
    parser.add_argument("--sides", nargs=2, default=["head", "main"])
    parser.add_argument("--lanes", nargs=2, type=Path, metavar=("FIRST", "SECOND"),
                        help="the source files declaring DeliveryLane for each side; lanes differ between trees")
    parser.add_argument("--json", type=Path)
    arguments = parser.parse_args()
    names = arguments.sides
    lanes_of = [lane_names(path) for path in arguments.lanes] if arguments.lanes else [LANES, LANES]
    collected = {name: collect(arguments.directory, name, lanes) for name, lanes in zip(names, lanes_of)}
    report = {"directory": str(arguments.directory), "stops": [], "frames": [], "drains": [], "writes": {}}
    microseconds = 1e-3

    print(f"{arguments.directory}")
    for name in names:
        outcomes = defaultdict(int)
        for run in collected[name][1]:
            outcomes[run["outcome"].split(":")[0]] += 1
        print(f"  {name}: runs {dict(outcomes)}; trace mismatches {sum(run['mismatches'] for run in collected[name][1])}")

    orders = sorted(set(collected[names[0]][0]) | set(collected[names[1]][0]))
    for order in orders:
        first = collected[names[0]][0].get(order, [])
        second = collected[names[1]][0].get(order, [])
        print(f"\n stop() of runtime #{order} in each run, one value per client")
        for field, scale, unit in (("queued_bytes", 1, "B"), ("queued_frames", 1, ""), ("oldest_age", microseconds, "us"), ("stop_delay", microseconds, "us")):
            values = [[stop[field] * scale for stop in side if stop[field] is not None] for side in (first, second)]
            report["stops"].append({"runtime": order, "field": field, **compare(f"{field} ({unit})" if unit else field, *values, names)})

        counts = []
        for side in (first, second):
            queued = sum(stop["queued_bytes"] > 0 for stop in side)
            half = sum(stop["half_written"] > 0 for stop in side)
            lost = sum(stop["lost_stopping"] for stop in side)
            counts.append((queued, half, lost, len(side)))
        for index, title in ((0, "output queued at stop"), (1, "a frame half written at stop"), (2, "RuntimeStopping left queued")):
            a, n1 = counts[0][index], counts[0][3]
            c, n2 = counts[1][index], counts[1][3]
            p = fisher(a, n1 - a, c, n2 - c)
            print(f"  {title}: {names[0]} {a}/{n1}, {names[1]} {c}/{n2}, Fisher p = {p:.3g}")
            report["stops"].append({"runtime": order, "count": title, names[0]: [a, n1], names[1]: [c, n2], "fisher_p": p})

        for name, side in zip(names, (first, second)):
            nonzero = [stop for stop in side if stop["queued_bytes"]]
            if nonzero:
                lanes = defaultdict(int)
                for stop in nonzero:
                    lanes[stop["active_lane"]] += 1
                print(f"  {name}: lane of the half-written frame when output was queued {dict(lanes)}; sizes {sorted(set(stop['queued_bytes'] for stop in nonzero))[:12]}")

    orderings = [[run["ordering"] for run in collected[name][1] if run["ordering"]] for name in names]
    if min(len(side) for side in orderings) >= 2:
        print("\n runtime #0: the stopping client's pane frames against its four replies")
        for name, side in zip(names, orderings):
            lanes = defaultdict(int)
            for row in side:
                for lane in row["before_first_cells"]:
                    lanes[lane] += 1
            counted = defaultdict(int)
            for row in side:
                counted[row["cells_between_replies"]] += 1
            lost = defaultdict(int)
            for row in side:
                lost[row["cells_between_replies"]] += row["lost"]
            print(f"  {name}: frames before the first cells frame, by lane {dict(lanes)}")
            print(f"  {name}: runs by cells frames written between the replies {dict(sorted(counted.items()))}; RuntimeStopping left queued {dict(sorted(lost.items()))}")
        for field, title in (("before_first_cells", "frames written before the first cells frame"), ("between_replies", "delivery frames written between the first and the last reply"),
                             ("cells_between_replies", "cells frames written between the replies"), ("bytes_after_last_reply", "bytes written after the last reply, before stop() (B)")):
            values = [[len(row[field]) if isinstance(row[field], list) else row[field] for row in side] for side in orderings]
            report.setdefault("ordering", []).append({"field": field, **compare(title, *values, names)})
        none = [(sum(row["cells_between_replies"] == 0 for row in side), len(side)) for side in orderings]
        p = fisher(none[0][0], none[0][1] - none[0][0], none[1][0], none[1][1] - none[1][0])
        print(f"  no cells frame between the replies: {names[0]} {none[0][0]}/{none[0][1]}, {names[1]} {none[1][0]}/{none[1][1]}, Fisher p = {p:.3g}")

    print("\n frame latency, queued to written (us)")
    pooled = [[latency * microseconds for run in collected[name][1] for latency in run["frames"]] for name in names]
    report["frames"].append(compare("pooled over every frame", *pooled, names))
    for title, statistic in (("per-run median", 0.5), ("per-run p95", 0.95), ("per-run p99", 0.99), ("per-run max", 1.0)):
        values = [[quantile(run["frames"], statistic) * microseconds for run in collected[name][1] if run["frames"]] for name in names]
        result = compare(title, *values, names)
        result["bootstrap_median_difference"] = bootstrap_difference(values[0], values[1], lambda sample: quantile(sample, 0.5))
        print(f"    95% bootstrap interval of the difference of medians ({names[0]} - {names[1]}): {result['bootstrap_median_difference'][0]:.4g} .. {result['bootstrap_median_difference'][1]:.4g}")
        report["frames"].append(result)

    lanes = sorted(set(lane for name in names for run in collected[name][1] for lane in run["lanes"]))
    for lane in lanes:
        values = [[latency * microseconds for run in collected[name][1] for latency in run["lanes"].get(lane, [])] for name in names]
        if min(len(values[0]), len(values[1])) >= 20:
            report["frames"].append({"lane": lane, **compare(f"lane {lane}, pooled", *values, names)})

    print("\n busy period of a queue, non-empty to empty (us)")
    pooled = [[drain * microseconds for run in collected[name][1] for drain in run["drains"]] for name in names]
    report["drains"].append(compare("pooled over every busy period", *pooled, names))
    for title, statistic in (("per-run median", 0.5), ("per-run p99", 0.99), ("per-run max", 1.0)):
        values = [[quantile(run["drains"], statistic) * microseconds for run in collected[name][1] if run["drains"]] for name in names]
        report["drains"].append(compare(title, *values, names))

    if any(run["publishes"] for name in names for run in collected[name][1]):
        print("\n publish() before its loop over the clients, per call (us)")
        for phase in ("before clients", *(phase for phase, _ in PUBLISH_PHASES)):
            values = [[value * microseconds for run in collected[name][1] for value in run["publishes"].get(phase, [])] for name in names]
            report.setdefault("publish", []).append({"phase": phase, **compare(phase, *values, names)})

    print("\n write() results")
    for name in names:
        total = defaultdict(int)
        for run in collected[name][1]:
            for key, value in run["writes"].items():
                total[key] += value
        frames = sum(len(run["frames"]) for run in collected[name][1])
        report["writes"][name] = dict(total, frames=frames)
        print(f"  {name}: {dict(total)}; frames written {frames}")

    if arguments.json:
        arguments.json.write_text(json.dumps(report, indent=1, default=float) + "\n")


if __name__ == "__main__":
    main()
