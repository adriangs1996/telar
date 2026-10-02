#!/usr/bin/env python3
"""Paired, rotated comparison of record placements on the idle-delivery benchmarks.

One `telar-benchmarks` executable runs every variant. A variant is a set of
`--placement*` arguments, never an environment variable, and every run gets the
same explicit environment, so nothing a shell exported reaches a run.

    placement_bench.py run --output DIR [--binary PATH] [--rounds N] ...
    placement_bench.py replay DIR/results.json

`run` builds the executable into DIR/prefix unless --binary names one, rotates
the variants each round and reverses the order on odd rounds, keeps every run's
standard output and error under DIR/runs, and writes DIR/results.json with the
provenance, every run (failed ones included) and the paired statistics.
`replay` recomputes those statistics from the runs saved in a results file and
fails when they differ from the ones stored beside them.

A paired change compares a variant with the reference variant's run of the same
round. A run counts only if it exited zero, reported both cases, stayed idle
and returned every controlled allocation at teardown.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import platform
import statistics
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, NamedTuple

FORMAT = 1
FILTER = "backend.delivery.flush_idle"
MODES = ("baseline", "shift", "stagger", "pack")
BACKINGS = ("debug", "libc")
RECORD_KINDS = ("runtime", "session", "pane", "attachment")
DEFAULT_VARIANTS = ("baseline=baseline", "shift=shift", "stagger=stagger", "pack=pack")
# The benchmark's own bounds (benchmarks/Config.zig, benchmarks/InterveningWalk.zig).
MAX_SAMPLES = 200
MAX_SAMPLE_MS = 5000
MAX_WALK_BYTES = 1024 * 1024 * 1024
BENCHMARK_FIELDS = ("iterations", "samples", "median_ns_per_op", "min_ns_per_op", "p95_ns_per_op", "p99_ns_per_op")
METADATA_FIELDS = ("zig", "mode", "arch", "cpu", "os", "cols", "rows", "samples", "sample_target_ns")
SHAPE_FIELDS = ("clients", "panes", "cols", "rows")
UNITS = {
    "median_ns_per_op": "nanoseconds per flush: the benchmark's median over one run's samples",
    "walk_flush_ns_per_flush": "nanoseconds per flush: summed clock intervals around each flush, divided by flushes",
    "walk_empty_clock_ns_per_flush": "nanoseconds per flush: summed empty clock intervals, divided by flushes",
    "walk_flush_minus_clock_ns_per_flush": "nanoseconds per flush: derived, the flush interval minus the empty clock interval",
    "paired_change_pct": "percent change against the reference variant's run of the same round",
}


class Variant(NamedTuple):
    name: str
    mode: str
    threshold: int


class UsageError(Exception):
    """An argument the runner cannot act on."""


def power_of_two(value: int) -> bool:
    return value > 0 and value & (value - 1) == 0


def parse_variant(text: str, default_threshold: int) -> Variant:
    """Parses NAME=MODE or NAME=MODE:THRESHOLD_BYTES."""
    name, separator, rest = text.partition("=")
    if not separator or not name or not rest:
        raise UsageError(f"variant {text!r}: expected NAME=MODE or NAME=MODE:THRESHOLD_BYTES")
    if not name.replace("_", "").replace("-", "").isalnum():
        raise UsageError(f"variant {text!r}: a name holds letters, digits, '_' and '-' only")
    mode, separator, threshold_text = rest.partition(":")
    if mode not in MODES:
        raise UsageError(f"variant {text!r}: unknown mode {mode!r}; choose one of {', '.join(MODES)}")
    threshold = default_threshold
    if separator:
        try:
            threshold = int(threshold_text)
        except ValueError:
            raise UsageError(f"variant {text!r}: threshold {threshold_text!r} is not a whole number of bytes") from None
        if threshold < 1:
            raise UsageError(f"variant {text!r}: the threshold must be at least one byte")
    return Variant(name, mode, threshold)


def ordered(variants: list[Variant], round_index: int) -> list[Variant]:
    """Rotates the variants by one place each round and reverses odd rounds."""
    shift = round_index % len(variants)
    order = variants[shift:] + variants[:shift]
    return order[::-1] if round_index % 2 else order


def clean_environment(home: Path) -> dict[str, str]:
    """The whole environment of every run; nothing else is inherited."""
    return {"PATH": "/usr/bin:/bin", "HOME": str(home), "LANG": "C"}


def variant_argv(binary: Path, variant: Variant, settings: dict[str, Any]) -> list[str]:
    argv = [
        str(binary), "--filter", FILTER, "--json",
        "--samples", str(settings["samples"]), "--sample-ms", str(settings["sample_ms"]),
        "--placement", variant.mode, "--placement-backing", settings["backing"],
        "--placement-threshold", str(variant.threshold), "--placement-stride", str(settings["stride"]),
        "--placement-report",
    ]
    if settings["window"] is not None:
        argv += ["--placement-window", str(settings["window"])]
    if settings["intervening_walk"] is not None:
        argv += ["--intervening-walk", str(settings["intervening_walk"])]
    return argv


def digest(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def parse_run(stdout: str, variant: Variant, settings: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    """Reads one run's JSON Lines. Returns what it reported and why it does not count."""
    problems: list[str] = []
    rows: list[dict[str, Any]] = []
    for number, line in enumerate(stdout.splitlines(), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as error:
            problems.append(f"stdout line {number} is not JSON: {error}")
            continue
        if isinstance(row, dict):
            rows.append(row)
        else:
            problems.append(f"stdout line {number} is not a JSON object")

    def typed(kind: str) -> list[dict[str, Any]]:
        return [row for row in rows if row.get("type") == kind]

    parsed: dict[str, Any] = {"metadata": None, "policy": None, "layout_sha256": None, "cases": {}}
    metadata = typed("metadata")
    if len(metadata) == 1:
        parsed["metadata"] = {field: metadata[0].get(field) for field in METADATA_FIELDS}
    else:
        problems.append(f"expected one metadata line, found {len(metadata)}")

    policy = typed("placement_policy")
    if len(policy) == 1:
        parsed["policy"] = {key: value for key, value in policy[0].items() if key != "type"}
        expected = {"mode": variant.mode, "backing": settings["backing"], "threshold_bytes": variant.threshold,
                    "stride_bytes": settings["stride"]}
        if settings["window"] is not None:
            expected["window_bytes"] = settings["window"]
        for key, value in expected.items():
            if parsed["policy"].get(key) != value:
                problems.append(f"policy {key} is {parsed['policy'].get(key)!r}, asked for {value!r}")
    else:
        problems.append(f"expected one placement_policy line, found {len(policy)}")

    layout = typed("placement_layout")
    if layout:
        # Whether a policy selects a record's shape belongs to the variant; the layout itself must not change with it.
        parsed["layout"] = [{key: value for key, value in row.items() if key not in ("type", "shape_selected")} for row in layout]
        parsed["layout_sha256"] = digest(parsed["layout"])
        parsed["shape_selected"] = {row.get("record"): row.get("shape_selected") for row in layout}
    else:
        problems.append("no placement_layout lines")

    names = [row.get("name") for row in typed("benchmark")]
    for name in names:
        if names.count(name) != 1:
            problems.append(f"{name}: reported {names.count(name)} times")
    for name in dict.fromkeys(names):
        case, case_problems = parse_case(rows, name, settings)
        parsed["cases"][name] = case
        problems += [f"{name}: {problem}" for problem in case_problems]
    if not names:
        problems.append("no benchmark lines")
    return parsed, problems


def parse_case(rows: list[dict[str, Any]], name: str, settings: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    problems: list[str] = []

    def one(kind: str) -> dict[str, Any] | None:
        found = [row for row in rows if row.get("type") == kind and row.get("name") == name]
        if len(found) != 1:
            problems.append(f"expected one {kind} line, found {len(found)}")
            return None
        return found[0]

    case: dict[str, Any] = {}
    benchmark = one("benchmark")
    if benchmark is not None:
        for field in BENCHMARK_FIELDS:
            if not isinstance(benchmark.get(field), int):
                problems.append(f"benchmark field {field} is missing or not a whole number")
            case[field] = benchmark.get(field)
        case["work_unit"] = benchmark.get("work_unit")

    fixture = one("placement_fixture")
    idle = one("placement_idle")
    teardown = one("placement_teardown")
    placement: dict[str, Any] = {}
    if fixture is not None:
        case["shape"] = {field: fixture.get(field) for field in SHAPE_FIELDS}
        for field in ("placed", "placed_bytes", "refused", "pack_region_used_bytes"):
            placement[field] = fixture.get(field)
        if fixture.get("refused") != 0:
            problems.append(f"the placement refused {fixture.get('refused')} allocations during setup")
    if idle is not None:
        placement["quiet"] = idle.get("quiet")
        placement["sends_pending"] = idle.get("sends_pending")
        if idle.get("quiet") is not True or idle.get("sends_pending") != 0:
            problems.append(f"not idle after timing: quiet={idle.get('quiet')!r}, sends_pending={idle.get('sends_pending')!r}")
    if teardown is not None:
        placement["live_at_teardown"] = teardown.get("live")
        if teardown.get("live") != 0:
            problems.append(f"{teardown.get('live')!r} controlled allocations were never freed")
        if teardown.get("refused") != 0:
            problems.append(f"the placement refused {teardown.get('refused')!r} allocations")

    records: dict[str, Any] = {}
    for row in rows:
        if row.get("type") == "placement_records" and row.get("name") == name:
            controlled = row.get("controlled", [])
            records[row.get("record")] = {
                "count": row.get("count"),
                "controlled": sum(1 for value in controlled if value is True),
                "page_offset_bytes": row.get("page_offset_bytes"),
                "window_offset_bytes": row.get("window_offset_bytes"),
            }
    placement["records"] = records
    if fixture is not None:
        expected = {"runtime": 1, "session": fixture.get("clients"), "pane": fixture.get("panes"),
                    "attachment": (fixture.get("clients") or 0) * (fixture.get("panes") or 0)}
        for kind in RECORD_KINDS:
            count = records.get(kind, {}).get("count")
            if count != expected[kind]:
                problems.append(f"{count!r} {kind} records, the shape needs {expected[kind]!r}")

    allocations = [row for row in rows if row.get("type") == "placement_allocations" and row.get("name") == name]
    if len(allocations) == 1:
        placement["allocations"] = {"count": allocations[0].get("count"), "bytes": sum(allocations[0].get("len_bytes", []))}
    else:
        problems.append(f"expected one placement_allocations line, found {len(allocations)}")
    case["placement"] = placement

    if settings["intervening_walk"] is not None:
        walk = one("intervening_walk")
        if walk is not None:
            flushes = walk.get("flushes")
            case["walk"] = {key: walk.get(key) for key in ("walk_bytes", "walk_stride_bytes", "flushes", "flush_ns", "empty_clock_ns")}
            if not isinstance(flushes, int) or flushes <= 0:
                problems.append("the walk timed no flush")
            elif walk.get("walk_bytes") != settings["intervening_walk"]:
                problems.append(f"walked {walk.get('walk_bytes')!r} bytes, asked for {settings['intervening_walk']}")
            else:
                case["walk_flush_ns_per_flush"] = walk["flush_ns"] / flushes
                case["walk_empty_clock_ns_per_flush"] = walk["empty_clock_ns"] / flushes
                case["walk_flush_minus_clock_ns_per_flush"] = (walk["flush_ns"] - walk["empty_clock_ns"]) / flushes
    return case, problems


def execute(argv: list[str], environment: dict[str, str], timeout: float, paths: tuple[Path, Path]) -> dict[str, Any]:
    """Runs one variant with exactly `environment`, keeping its output on disk."""
    started = time.monotonic()
    outcome: dict[str, Any] = {"returncode": None, "timed_out": False, "launch_error": None}
    with paths[0].open("wb") as stdout, paths[1].open("wb") as stderr:
        try:
            completed = subprocess.run(argv, env=environment, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
                                       timeout=timeout, check=False)
            outcome["returncode"] = completed.returncode
        except subprocess.TimeoutExpired:
            outcome["timed_out"] = True
        except OSError as error:
            outcome["launch_error"] = str(error)
    outcome["duration_s"] = round(time.monotonic() - started, 3)
    return outcome


def paired(series: dict[str, list[float | None]], reference: str) -> dict[str, dict[str, Any]]:
    """Statistics per variant. Each list holds one value per round; None is a run that does not count."""
    base = series[reference]
    summary: dict[str, dict[str, Any]] = {}
    for name, values in series.items():
        present = [value for value in values if value is not None]
        pairs = [(value, against) for value, against in zip(values, base) if value is not None and against]
        changes = [(value / against - 1) * 100 for value, against in pairs]
        summary[name] = {
            "runs": len(present),
            "runs_not_counted": len(values) - len(present),
            "median": statistics.median(present) if present else None,
            "minimum": min(present) if present else None,
            "maximum": max(present) if present else None,
            "pairs": len(pairs),
            "median_paired_change_pct": statistics.median(changes) if changes else None,
            "min_paired_change_pct": min(changes) if changes else None,
            "max_paired_change_pct": max(changes) if changes else None,
            "wins": sum(1 for value, against in pairs if value < against),
            "losses": sum(1 for value, against in pairs if value > against),
            "ties": sum(1 for value, against in pairs if value == against),
        }
    return summary


def derive(results: dict[str, Any]) -> dict[str, Any]:
    """Recomputes every paired statistic from the saved runs alone."""
    variants = [variant["name"] for variant in results["variants"]]
    rounds = results["settings"]["rounds"]
    metrics = ["median_ns_per_op"]
    if results["settings"]["intervening_walk"] is not None:
        metrics += ["walk_flush_ns_per_flush", "walk_empty_clock_ns_per_flush", "walk_flush_minus_clock_ns_per_flush"]
    cases: list[str] = []
    for run in results["runs"]:
        for name in run["cases"]:
            if name not in cases:
                cases.append(name)

    derived: dict[str, Any] = {}
    for case in cases:
        derived[case] = {}
        for metric in metrics:
            series: dict[str, list[float | None]] = {name: [None] * rounds for name in variants}
            for run in results["runs"]:
                if run["status"] == "ok":
                    series[run["variant"]][run["round"]] = run["cases"].get(case, {}).get(metric)
            derived[case][metric] = paired(series, results["reference"])
    return derived


def consistency(runs: list[dict[str, Any]]) -> list[str]:
    """Names what differs between counted runs that must share one logical setup."""
    problems: list[str] = []
    counted = [run for run in runs if run["status"] == "ok"]
    compared = (
        ("benchmark metadata", lambda run: run["metadata"]),
        ("record layout", lambda run: run["layout_sha256"]),
        ("set of cases", lambda run: sorted(run["cases"])),
    )
    for label, read in compared:
        if len({digest(read(run)) for run in counted}) > 1:
            problems.append(f"{label} differs between runs")
    shapes: dict[str, set[str]] = {}
    for run in counted:
        for name, case in run["cases"].items():
            shapes.setdefault(name, set()).add(digest([case.get("shape"), {kind: record["count"] for kind, record in case["placement"]["records"].items()}]))
    problems += [f"{name}: fixture shape or record counts differ between runs" for name, seen in shapes.items() if len(seen) > 1]
    return problems


def command_output(argv: list[str], cwd: Path | None = None) -> str | None:
    try:
        # Only the end is trimmed: `git status --porcelain` lines start with a significant space.
        return subprocess.run(argv, cwd=cwd, capture_output=True, text=True, check=True).stdout.rstrip()
    except (OSError, subprocess.CalledProcessError):
        return None


def cpu_brand() -> str | None:
    if sys.platform == "darwin":
        return command_output(["sysctl", "-n", "machdep.cpu.brand_string"])
    try:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.lower().startswith(("model name", "hardware")):
                return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return None


def source_state(root: Path) -> dict[str, Any]:
    status = command_output(["git", "status", "--porcelain"], root)
    lines = status.splitlines() if status else []
    return {
        "root": str(root),
        "revision": command_output(["git", "rev-parse", "HEAD"], root),
        "modified_paths": [line[3:] for line in lines if not line.startswith("??")],
        "untracked_paths": [line[3:] for line in lines if line.startswith("??")],
        "status_known": status is not None,
    }


def host_state() -> dict[str, Any]:
    return {
        "platform": platform.platform(),
        "system": platform.system(),
        "release": platform.release(),
        "machine": platform.machine(),
        "cpu_brand": cpu_brand(),
        "logical_cpus": os.cpu_count(),
        "page_bytes": os.sysconf("SC_PAGE_SIZE"),
        "python": platform.python_version(),
    }


def load_average() -> list[float] | None:
    try:
        return [round(value, 2) for value in os.getloadavg()]
    except OSError:
        return None


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build(args: argparse.Namespace, output: Path, root: Path) -> tuple[Path, dict[str, Any]]:
    """Builds the benchmark into `output`/prefix with the caller's toolchain environment."""
    prefix = output / "prefix"
    command = ["zig", "build", "build-bench", "-Doptimize=ReleaseFast", "--prefix", str(prefix)]
    if args.jobs is not None:
        command.append(f"-j{args.jobs}")
    command += args.zig_build_arg
    started = time.monotonic()
    with (output / "build.log").open("wb") as log:
        try:
            returncode = subprocess.run(command, cwd=root, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, check=False).returncode
        except OSError as error:
            raise UsageError(f"cannot run zig: {error}") from None
    record = {
        "command": command,
        "cwd": str(root),
        "returncode": returncode,
        "duration_s": round(time.monotonic() - started, 1),
        "log": "build.log",
        "zig_version": command_output(["zig", "version"]),
        # What selects the SDK on macOS; recorded because it changes the headers the build reads.
        "environment": {name: os.environ.get(name) for name in ("DEVELOPER_DIR", "SDKROOT")},
    }
    binary = prefix / "bin" / "telar-benchmarks"
    if returncode != 0 or not binary.is_file():
        raise UsageError(f"the build failed with status {returncode}; see {output / 'build.log'}")
    return binary, record


def write_results(path: Path, results: dict[str, Any]) -> None:
    """Writes one top-level key per block and one run per line, so a diff stays readable."""
    blocks = []
    for key, value in results.items():
        if key == "runs":
            body = "[\n" + ",\n".join("  " + json.dumps(run, separators=(",", ":")) for run in value) + "\n ]" if value else "[]"
        elif key == "layout":
            body = "[\n" + ",\n".join("  " + json.dumps(row, separators=(",", ":")) for row in value) + "\n ]" if value else "[]"
        else:
            body = json.dumps(value, indent=1).replace("\n", "\n ")
        blocks.append(f" {json.dumps(key)}: {body}")
    path.write_text("{\n" + ",\n".join(blocks) + "\n}\n")


def format_number(value: float | None, pattern: str) -> str:
    return "-" if value is None else format(value, pattern)


def print_summary(results: dict[str, Any]) -> None:
    stream = sys.stdout
    metric = "median_ns_per_op" if results["settings"]["intervening_walk"] is None else "walk_flush_minus_clock_ns_per_flush"
    print(f"metric {metric}: {UNITS[metric]}", file=stream)
    print(f"reference variant: {results['reference']}; rounds: {results['settings']['rounds']}", file=stream)
    for case, metrics in results["derived"].items():
        print(case, file=stream)
        print(f"  {'variant':16}{'runs':>7}{'median':>10}{'min':>10}{'paired':>10}{'range':>20}{'wins':>8}", file=stream)
        for name, row in metrics[metric].items():
            runs = f"{row['runs']}/{row['runs'] + row['runs_not_counted']}"
            spread = "-" if row["pairs"] == 0 else f"{row['min_paired_change_pct']:+.1f}..{row['max_paired_change_pct']:+.1f}%"
            print(f"  {name:16}{runs:>7}{format_number(row['median'], '10.0f')}{format_number(row['minimum'], '10.0f')}"
                  f"{format_number(row['median_paired_change_pct'], '+9.2f')}%{spread:>20}{row['wins']:>5}/{row['pairs']}", file=stream)
    not_counted = [run for run in results["runs"] if run["status"] != "ok"]
    for run in not_counted:
        print(f"not counted: round {run['round']} {run['variant']}: {'; '.join(run['problems'])}", file=stream)
    for problem in results["consistency_problems"]:
        print(f"inconsistent: {problem}", file=stream)


def validate(args: argparse.Namespace) -> tuple[list[Variant], str, dict[str, Any]]:
    if args.rounds < 1:
        raise UsageError("--rounds must be at least 1")
    if not 1 <= args.samples <= MAX_SAMPLES:
        raise UsageError(f"--samples must be between 1 and {MAX_SAMPLES}")
    if not 1 <= args.sample_ms <= MAX_SAMPLE_MS:
        raise UsageError(f"--sample-ms must be between 1 and {MAX_SAMPLE_MS}")
    if args.threshold < 1:
        raise UsageError("--threshold must be at least one byte")
    if not power_of_two(args.stride):
        raise UsageError("--stride must be a power of two")
    if args.window is not None and (not power_of_two(args.window) or args.window < 4 * args.stride):
        raise UsageError("--window must be a power of two of at least four strides")
    if args.intervening_walk is not None and not 1 <= args.intervening_walk <= MAX_WALK_BYTES:
        raise UsageError(f"--intervening-walk must be between 1 and {MAX_WALK_BYTES} bytes")
    if args.timeout <= 0:
        raise UsageError("--timeout must be positive")
    if args.jobs is not None and args.jobs < 1:
        raise UsageError("--jobs must be at least 1")
    if args.binary is not None and (args.jobs is not None or args.zig_build_arg):
        raise UsageError("--jobs and --zig-build-arg configure the build; they cannot be combined with --binary")

    variants = [parse_variant(text, args.threshold) for text in (args.variant or DEFAULT_VARIANTS)]
    names = [variant.name for variant in variants]
    for name in names:
        if names.count(name) > 1:
            raise UsageError(f"variant name {name!r} is used more than once")
    if len(variants) < 2:
        raise UsageError("a paired comparison needs at least two variants")
    reference = args.reference or names[0]
    if reference not in names:
        raise UsageError(f"--reference {reference!r} is not one of the variants: {', '.join(names)}")

    settings = {
        "rounds": args.rounds, "samples": args.samples, "sample_ms": args.sample_ms, "backing": args.backing,
        "threshold": args.threshold, "stride": args.stride, "window": args.window,
        "intervening_walk": args.intervening_walk, "timeout_s": args.timeout, "filter": FILTER,
    }
    return variants, reference, settings


def command_run(args: argparse.Namespace) -> int:
    variants, reference, settings = validate(args)
    root = Path(__file__).resolve().parent.parent
    output = args.output
    if output.exists():
        raise UsageError(f"{output} already exists; a measured run is never overwritten")
    if args.binary is not None and not (args.binary.is_file() and os.access(args.binary, os.X_OK)):
        raise UsageError(f"{args.binary} is not an executable file")
    output.mkdir(parents=True)
    output = output.resolve()
    (output / "runs").mkdir()
    (output / "home").mkdir()

    source = source_state(root)
    build_record = None
    binary = args.binary
    if binary is None:
        print("building the benchmark executable", flush=True)
        binary, build_record = build(args, output, root)
    binary = binary.resolve()
    environment = clean_environment(output / "home")

    results: dict[str, Any] = {
        "format": FORMAT,
        "complete": False,
        "provenance": {
            "runner": "tools/placement_bench.py",
            "started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
            "finished_utc": None,
            "source": source,
            "binary": {
                "path": str(binary),
                "sha256": sha256(binary),
                "size_bytes": binary.stat().st_size,
                "built_by_runner": build_record is not None,
            },
            "build": build_record,
            "host": host_state(),
            "load_average_start": load_average(),
            "load_average_end": None,
            "run_environment": environment,
        },
        "settings": settings,
        "variants": [variant._asdict() for variant in variants],
        "reference": reference,
        "units": UNITS,
        "benchmark_metadata": None,
        "layout": [],
        "runs": [],
        "consistency_problems": [],
        "derived": {},
    }

    try:
        for round_index in range(args.rounds):
            for position, variant in enumerate(ordered(variants, round_index)):
                stem = f"r{round_index:02d}-p{position}-{variant.name}"
                paths = (output / "runs" / f"{stem}.stdout", output / "runs" / f"{stem}.stderr")
                argv = variant_argv(binary, variant, settings)
                load = load_average()
                outcome = execute(argv, environment, args.timeout, paths)
                parsed, problems = parse_run(paths[0].read_text(errors="replace"), variant, settings)
                if outcome["launch_error"] is not None:
                    problems.insert(0, f"could not start: {outcome['launch_error']}")
                elif outcome["timed_out"]:
                    problems.insert(0, f"timed out after {args.timeout} s")
                elif outcome["returncode"] != 0:
                    tail = paths[1].read_text(errors="replace").strip().splitlines()[-1:]
                    problems.insert(0, f"exited with status {outcome['returncode']}" + (f": {tail[0]}" if tail else ""))
                layout = parsed.pop("layout", [])
                if not results["layout"] and not problems:
                    results["layout"] = layout
                    results["benchmark_metadata"] = parsed["metadata"]
                results["runs"].append({
                    "round": round_index, "position": position, "variant": variant.name,
                    "status": "failed" if problems else "ok", "problems": problems, "argv": argv,
                    "stdout": f"runs/{stem}.stdout", "stderr": f"runs/{stem}.stderr",
                    "load_average_1m": load[0] if load else None, **outcome, **parsed,
                })
                print(f"round {round_index + 1}/{args.rounds} {variant.name}: {'ok' if not problems else 'FAILED: ' + problems[0]}", flush=True)
        results["complete"] = True
    finally:
        results["provenance"]["finished_utc"] = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
        results["provenance"]["load_average_end"] = load_average()
        results["consistency_problems"] = consistency(results["runs"])
        results["derived"] = derive(results)
        write_results(output / "results.json", results)

    print_summary(results)
    print(f"results: {output / 'results.json'}")
    failed = any(run["status"] != "ok" for run in results["runs"])
    return 1 if failed or results["consistency_problems"] else 0


def command_replay(args: argparse.Namespace) -> int:
    try:
        results = json.loads(args.results.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise UsageError(f"cannot read {args.results}: {error}") from None
    if not isinstance(results, dict) or results.get("format") != FORMAT:
        raise UsageError(f"{args.results} is not a format {FORMAT} placement result")
    try:
        recomputed = derive(results)
        problems = consistency(results["runs"])
    except (KeyError, TypeError, IndexError) as error:
        raise UsageError(f"{args.results} is missing what a replay needs: {error!r}") from None
    matches = recomputed == results["derived"] and problems == results["consistency_problems"]
    results["derived"] = recomputed
    results["consistency_problems"] = problems
    print_summary(results)
    if not results.get("complete", False):
        print("the saved run did not finish every round")
    print("replay matches the stored statistics" if matches else "REPLAY DIFFERS from the stored statistics")
    return 0 if matches else 1


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = root.add_subparsers(dest="command", required=True)
    run = commands.add_parser("run", help="run a paired comparison and save it")
    run.add_argument("--output", type=Path, required=True, help="new directory for the results; it must not exist")
    run.add_argument("--binary", type=Path, help="an already built telar-benchmarks; without it the runner builds one")
    run.add_argument("--rounds", type=int, default=9, help="rounds; every variant runs once per round (default 9)")
    run.add_argument("--samples", type=int, default=12, help="samples per case and run (default 12)")
    run.add_argument("--sample-ms", type=int, default=40, help="target milliseconds per sample (default 40)")
    run.add_argument("--backing", choices=BACKINGS, default="libc", help="allocator under every variant (default libc)")
    run.add_argument("--threshold", type=int, default=32768, help="smallest allocation placed, in bytes (default 32768)")
    run.add_argument("--stride", type=int, default=512, help="stagger step and largest alignment placed (default 512)")
    run.add_argument("--window", type=int, help="span the offsets spread over (default: the host page size)")
    run.add_argument("--variant", action="append", metavar="NAME=MODE[:THRESHOLD]",
                     help=f"a variant to run; repeat it. Modes: {', '.join(MODES)}. Default: {' '.join(DEFAULT_VARIANTS)}")
    run.add_argument("--reference", metavar="NAME", help="variant the others are paired against (default: the first)")
    run.add_argument("--intervening-walk", type=int, metavar="BYTES", help="read this much unrelated memory before each flush")
    run.add_argument("--timeout", type=float, default=300.0, help="seconds before one run is abandoned (default 300)")
    run.add_argument("--jobs", type=int, help="pass -jN to the build")
    run.add_argument("--zig-build-arg", action="append", default=[], metavar="ARG",
                     help="extra argument for the build, such as --zig-build-arg=--libc --zig-build-arg=FILE; repeat it")
    run.set_defaults(handler=command_run)
    replay = commands.add_parser("replay", help="recompute the statistics of a saved results.json")
    replay.add_argument("results", type=Path)
    replay.set_defaults(handler=command_replay)
    return root


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        return args.handler(args)
    except UsageError as error:
        print(f"placement_bench.py: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
