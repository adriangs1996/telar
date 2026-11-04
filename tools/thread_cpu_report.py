"""Account for observed Darwin thread CPU without hiding retired-thread residuals."""

import argparse
import json
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def unsigned(value):
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def analyze(records):
    require(len(records) >= 4, "missing snapshot boundaries")
    header, footer = records[0], records[-1]
    require(header.get("type") == "header" and header.get("version") == 1, "unsupported header")
    require(header.get("cpu_unit") == "microseconds" and header.get("clock") == "CLOCK_UPTIME_RAW", "incompatible units")
    require(unsigned(header.get("pid")) and header["pid"] > 0, "invalid process identity")
    require(unsigned(header.get("controlling_id")) and header["controlling_id"] > 0, "invalid controlling thread")
    require(footer.get("type") == "footer", "missing completion footer")
    require(all(footer.get(key) == 0 for key in ("observer_error", "join_error", "end_error")), "observer failed")
    snapshots = records[1:-1]
    require(snapshots[0].get("kind") == "begin" and snapshots[-1].get("kind") == "end", "missing begin/end")
    threads = {}
    previous = None
    for index, snapshot in enumerate(snapshots):
        require(snapshot.get("type") == "snapshot" and snapshot.get("sequence") == index, "missing or reordered snapshot")
        require(snapshot.get("kind") == ("begin" if index == 0 else "end" if index == len(snapshots) - 1 else "periodic"), "invalid snapshot kind")
        require(all(unsigned(snapshot.get(key)) for key in ("before_ns", "after_ns", "sampler_id")), "invalid clock or sampler")
        require(snapshot["before_ns"] <= snapshot["after_ns"], "reversed snapshot clock")
        for key in ("process_before_us", "process_after_us"):
            require(isinstance(snapshot.get(key), list) and len(snapshot[key]) == 2 and all(unsigned(value) for value in snapshot[key]), "invalid process counters")
        require(all(left <= right for left, right in zip(snapshot["process_before_us"], snapshot["process_after_us"])), "reversed process counter")
        if previous is not None:
            require(previous["after_ns"] <= snapshot["before_ns"], "overlapping snapshot clocks")
            require(all(left <= right for left, right in zip(previous["process_after_us"], snapshot["process_before_us"])), "decreasing process counter")
        require(snapshot.get("enumeration_result") == 0 and snapshot.get("enumerated") == len(snapshot["threads"]), "incomplete thread enumeration")
        seen = set()
        for row in snapshot["threads"]:
            require(all(row.get(key) == 0 for key in ("identifier_result", "basic_result", "name_result")), "failed thread observation")
            require(all(unsigned(row.get(key)) for key in ("id", "user_us", "system_us")) and row["id"] > 0, "invalid thread counters")
            identity = row["id"]
            require(identity not in seen, "duplicate thread identity")
            seen.add(identity)
            name = bytes.fromhex(row["name_hex"]).decode("utf-8", errors="replace")
            current = [row["user_us"], row["system_us"]]
            if identity not in threads:
                threads[identity] = dict(id=identity, names=set(), first_snapshot=index, last_snapshot=index,
                                         baseline_us=current if index == 0 else [0, 0], last_us=current, observations=0)
            thread = threads[identity]
            require(all(left <= right for left, right in zip(thread["last_us"], current)), "decreasing thread counter")
            thread["last_us"] = current
            thread["last_snapshot"] = index
            thread["observations"] += 1
            thread["names"].add(name)
        require(snapshot["sampler_id"] in seen, "sampler absent from snapshot")
        if index == 0:
            require(header["controlling_id"] in seen, "controlling thread missing at start")
        if snapshot["kind"] != "periodic":
            require(snapshot["sampler_id"] == header["controlling_id"], "boundary thread mismatch")
        previous = snapshot

    begin, end = snapshots[0], snapshots[-1]
    rows = []
    for thread in threads.values():
        user, system = [last - first for first, last in zip(thread["baseline_us"], thread["last_us"])]
        rows.append(dict(id=thread["id"], names=sorted(thread["names"]), user_ms=user / 1000,
                         system_ms=system / 1000, cpu_ms=(user + system) / 1000,
                         present_at_begin=thread["first_snapshot"] == 0,
                         present_at_end=thread["last_snapshot"] == len(snapshots) - 1,
                         observations=thread["observations"], first_snapshot=thread["first_snapshot"],
                         last_snapshot=thread["last_snapshot"]))
    rows.sort(key=lambda row: row["cpu_ms"], reverse=True)
    process_minimum = sum(end["process_before_us"]) - sum(begin["process_after_us"])
    process_maximum = sum(end["process_after_us"]) - sum(begin["process_before_us"])
    observed = sum(row["cpu_ms"] for row in rows)
    require(process_minimum > 0 and process_minimum <= process_maximum, "empty process CPU interval")
    return dict(scope="Diagnostic observed thread CPU deltas, not acceptance timing. New threads contribute observed lifetime CPU; threads ending between snapshots have an unobserved tail. Completely unseen threads remain in signed process residual. Process/thread accounting is asynchronous; residuals are not exact dead-thread CPU.",
                pid=header["pid"], controlling_id=header["controlling_id"], snapshots=len(snapshots),
                wall_minimum_ms=(end["before_ns"] - begin["after_ns"]) / 1e6,
                wall_maximum_ms=(end["after_ns"] - begin["before_ns"]) / 1e6,
                maximum_snapshot_ms=max(row["after_ns"] - row["before_ns"] for row in snapshots) / 1e6,
                process_cpu_minimum_ms=process_minimum / 1000, process_cpu_maximum_ms=process_maximum / 1000,
                observed_thread_cpu_ms=observed,
                signed_residual_minimum_ms=process_minimum / 1000 - observed,
                signed_residual_maximum_ms=process_maximum / 1000 - observed,
                threads=rows)


def validate_control(report, control):
    require(control.get("observer_result") == 0, "control observer failed")
    rows = {row["id"]: row for row in report["threads"]}
    busy = rows[control["busy_id"]]["cpu_ms"]
    sleeping = rows[control["sleep_id"]]["cpu_ms"]
    main = rows[report["controlling_id"]]["cpu_ms"]
    expected_busy = control["busy_burn_ns"] / 1e6
    expected_main = control["main_burn_ns"] / 1e6
    require(abs(busy - expected_busy) <= expected_busy * 0.05, "busy CPU unit mismatch")
    require(abs(main - expected_main) <= expected_main * 0.05, "main CPU unit mismatch")
    require(sleeping < expected_busy * 0.10, "sleeping thread charged as busy")
    short_cpu = sum(row["burn_ns"] for row in control["short"]) / 1e6
    observed_short = sum(rows[row["id"]]["cpu_ms"] for row in control["short"] if row["id"] in rows)
    unseen = sum(row["id"] not in rows for row in control["short"])
    require(unseen > 0, "control did not exercise unseen threads")
    expected_residual = short_cpu - observed_short
    residual = (report["signed_residual_minimum_ms"] + report["signed_residual_maximum_ms"]) / 2
    require(abs(residual - expected_residual) < 10, "unseen CPU residual mismatch")
    return dict(passed=True, busy_cpu_ms=busy, expected_busy_ms=expected_busy,
                main_cpu_ms=main, expected_main_ms=expected_main, sleep_cpu_ms=sleeping,
                unseen_short_threads=unseen, expected_unobserved_short_ms=expected_residual,
                signed_residual_midpoint_ms=residual,
                tolerance="5% busy/main CPU; sleep below10% busy; residual within10ms of known short-thread work, allowing observer and thread-lifecycle overhead.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--control", type=Path, help="Validate the native busy/sleep/churn control receipt")
    args = parser.parse_args()
    result = analyze([json.loads(line) for line in args.capture.read_text().splitlines()])
    if args.control:
        result["control_validation"] = validate_control(result, json.loads(args.control.read_text()))
    rendered = json.dumps(result, indent=2) + "\n"
    if args.output:
        args.output.write_text(rendered)
    else:
        print(rendered, end="")


if __name__ == "__main__":
    main()
