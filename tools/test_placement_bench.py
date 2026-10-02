#!/usr/bin/env python3
"""Tests for the placement benchmark runner, against a stand-in executable."""

import contextlib
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import placement_bench

ARCHIVE = Path(__file__).resolve().parent.parent / "docs" / "performance" / "record-placement"
CASES = ("backend.delivery.flush_idle_2x8", "backend.delivery.flush_idle_1x32")

# Speaks the benchmark's JSON Lines. `behaviour.json` beside it says how each
# placement mode behaves; every call's argv and environment go to calls.jsonl.
STAND_IN = r'''#!%(python)s
import json, os, sys, time
here = os.path.dirname(os.path.abspath(__file__))
behaviour = json.load(open(os.path.join(here, "behaviour.json")))
argv = sys.argv[1:]
value = lambda flag, default=None: argv[argv.index(flag) + 1] if flag in argv else default
mode = value("--placement", "baseline")
with open(os.path.join(here, "calls.jsonl"), "a") as calls:
    calls.write(json.dumps({"argv": argv, "environ": dict(os.environ)}) + "\n")
calls_so_far = sum(1 for line in open(os.path.join(here, "calls.jsonl")) if json.loads(line)["argv"][argv.index("--placement") + 1] == mode)
quirk = behaviour.get("quirks", {}).get(mode, {})
if "sleep" in quirk:
    time.sleep(quirk["sleep"])
emit = lambda **row: print(json.dumps(row), flush=True)
emit(type="metadata", zig="0.16.0", mode="ReleaseFast", arch="aarch64", cpu="stand_in", os="macos", cols=154, rows=37,
     samples=int(value("--samples")), sample_target_ns=int(value("--sample-ms")) * 1000000)
emit(type="placement_policy", mode=mode, backing=value("--placement-backing"), threshold_bytes=int(value("--placement-threshold")),
     stride_bytes=int(value("--placement-stride")), window_bytes=int(value("--placement-window", 16384)), shift_bytes=4096,
     page_bytes=16384, table_rows=2048, pack_region_bytes=1 << 30)
emit(type="placement_layout", record="pane", type_name="pane.Pane", size_bytes=quirk.get("pane_bytes", 836696), alignment_bytes=8,
     shape_selected=mode != "baseline", fields=[{"name": "id", "offset_bytes": 0, "size_bytes": 8}])
for index, (name, clients, panes) in enumerate([("backend.delivery.flush_idle_2x8", 2, 8), ("backend.delivery.flush_idle_1x32", 1, 32)]):
    placed = 0 if mode == "baseline" else panes + clients * panes
    emit(type="placement_fixture", name=name, clients=clients, panes=panes, cols=154, rows=37, placed=placed,
         placed_bytes=placed * 1000, live=placed, refused=0, pack_region_used_bytes=0)
    for record, count in (("runtime", 1), ("session", clients), ("pane", panes - quirk.get("missing_panes", 0)), ("attachment", clients * panes)):
        emit(type="placement_records", name=name, record=record, count=count, index=list(range(count)), address=[16384 * (n + 1) for n in range(count)],
             page_offset_bytes=[0] * count, window_offset_bytes=[0] * count, controlled=[mode != "baseline"] * count)
    emit(type="placement_allocations", name=name, count=placed, address=[1] * placed, len_bytes=[1000] * placed, offset_bytes=[0] * placed)
    if quirk.get("fail_after_calls") is not None and calls_so_far > quirk["fail_after_calls"]:
        sys.stderr.write("error: IdleDeliveryStartedWrite\n")
        sys.exit(1)
    medians = behaviour["medians"][mode][index]
    median = medians[(calls_so_far - 1) %% len(medians)]
    emit(type="benchmark", name=name, iterations=1000, samples=int(value("--samples")), median_ns_per_op=median, min_ns_per_op=median - 5,
         p95_ns_per_op=median + 5, p99_ns_per_op=median + 9, work_per_op=1, work_unit="flushes", work_per_second=1, payload_bytes_per_op=0,
         p99_budget_ns=1000000)
    if value("--intervening-walk"):
        emit(type="intervening_walk", name=name, walk_bytes=int(value("--intervening-walk")), walk_stride_bytes=64, flushes=1000,
             flush_ns=median * 1000, empty_clock_ns=40 * 1000)
    emit(type="placement_idle", name=name, quiet=not quirk.get("busy", False), sends_pending=1 if quirk.get("busy") else 0)
    emit(type="placement_teardown", name=name, placed=placed, live=quirk.get("leaked", 0), refused=0)
'''

MEDIANS = {
    "baseline": [[1000, 1000, 1000], [2000, 2000, 2000]],
    "shift": [[1000, 1010, 990], [2000, 2100, 1900]],
    "stagger": [[800, 750, 900], [1000, 1000, 1000]],
    "pack": [[700, 700, 700], [900, 900, 900]],
}


class PlacementBenchTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.binary = self.root / "stand-in" / "telar-benchmarks"
        self.binary.parent.mkdir()
        self.binary.write_text(STAND_IN % {"python": sys.executable})
        self.binary.chmod(self.binary.stat().st_mode | stat.S_IXUSR)
        self.behave()

    def behave(self, **quirks):
        (self.binary.parent / "behaviour.json").write_text(json.dumps({"medians": MEDIANS, "quirks": quirks}))

    def run_cli(self, *arguments):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = placement_bench.main(list(arguments))
        return status, stdout.getvalue(), stderr.getvalue()

    def run_pairs(self, *extra, name="out"):
        output = self.root / name
        status, stdout, stderr = self.run_cli("run", "--output", str(output), "--binary", str(self.binary), "--rounds", "3", *extra)
        results = json.loads((output / "results.json").read_text()) if (output / "results.json").exists() else None
        return status, stdout + stderr, results

    def calls(self):
        return [json.loads(line) for line in (self.binary.parent / "calls.jsonl").read_text().splitlines()]

    def test_archived_medians_reproduce_the_recorded_summary(self):
        medians = json.loads((ARCHIVE / "pair_libc.json").read_text())
        recorded = json.loads((ARCHIVE / "manifest.json").read_text())["warm_summary_recomputed"]
        for case, series in medians.items():
            summary = placement_bench.paired(series, "none")
            for variant, expected in recorded[case].items():
                self.assertEqual(summary[variant]["median"], expected["median_ns"])
                self.assertAlmostEqual(summary[variant]["median_paired_change_pct"], expected["median_paired_change_pct"], places=9)
                self.assertEqual((summary[variant]["wins"], summary[variant]["pairs"]), (expected["wins"], expected["pairs"]))

    def test_pairs_count_wins_losses_and_ties_and_skip_rounds_without_both_runs(self):
        summary = placement_bench.paired({"a": [100, 200, None, 100, 400], "b": [90, 220, 50, None, 400]}, "a")
        self.assertEqual({key: summary["b"][key] for key in ("runs", "runs_not_counted", "pairs", "wins", "losses", "ties")},
                         {"runs": 4, "runs_not_counted": 1, "pairs": 3, "wins": 1, "losses": 1, "ties": 1})
        self.assertAlmostEqual(summary["b"]["median_paired_change_pct"], 0.0)
        self.assertAlmostEqual(summary["b"]["min_paired_change_pct"], -10.0)
        self.assertAlmostEqual(summary["b"]["max_paired_change_pct"], 10.0)
        self.assertEqual(summary["b"]["median"], 155)
        self.assertEqual((summary["a"]["wins"], summary["a"]["ties"], summary["a"]["pairs"]), (0, 4, 4))
        empty = placement_bench.paired({"a": [None], "b": [None]}, "a")["b"]
        self.assertEqual((empty["pairs"], empty["median"], empty["median_paired_change_pct"]), (0, None, None))

    def test_order_rotates_each_round_and_reverses_odd_rounds(self):
        variants = [placement_bench.Variant(name, "baseline", 1) for name in "abcde"]
        orders = ["".join(variant.name for variant in placement_bench.ordered(variants, index)) for index in range(6)]
        self.assertEqual(orders, ["abcde", "aedcb", "cdeab", "cbaed", "eabcd", "edcba"])
        for order in orders:
            self.assertEqual(sorted(order), list("abcde"))

    def test_variants_parse_and_reject_what_they_cannot_run(self):
        self.assertEqual(placement_bench.parse_variant("stagger_panes=stagger:65536", 32768), ("stagger_panes", "stagger", 65536))
        self.assertEqual(placement_bench.parse_variant("pack=pack", 32768), ("pack", "pack", 32768))
        for text in ("pack", "=pack", "pack=", "a=color", "a=stagger:big", "a=stagger:0", "a b=pack"):
            with self.assertRaises(placement_bench.UsageError, msg=text):
                placement_bench.parse_variant(text, 32768)

    def test_invalid_arguments_fail_before_anything_runs(self):
        base = ["run", "--binary", str(self.binary)]
        rejected = [
            (["--rounds", "0"], "--rounds"),
            (["--samples", "201"], "--samples"),
            (["--sample-ms", "0"], "--sample-ms"),
            (["--threshold", "0"], "--threshold"),
            (["--stride", "48"], "--stride"),
            (["--window", "1024"], "--window"),
            (["--window", "3000"], "--window"),
            (["--intervening-walk", "0"], "--intervening-walk"),
            (["--timeout", "0"], "--timeout"),
            (["--variant", "a=stagger"], "at least two variants"),
            (["--variant", "a=stagger", "--variant", "a=pack"], "more than once"),
            (["--variant", "a=baseline", "--variant", "b=color"], "unknown mode"),
            (["--reference", "missing"], "--reference"),
            (["--jobs", "2"], "--binary"),
            (["--zig-build-arg=--libc"], "--binary"),
        ]
        for index, (arguments, message) in enumerate(rejected):
            output = self.root / f"rejected-{index}"
            status, _, stderr = self.run_cli(*base, "--output", str(output), *arguments)
            self.assertEqual(status, 2, arguments)
            self.assertIn(message, stderr, arguments)
            self.assertFalse(output.exists(), arguments)
        self.assertFalse((self.binary.parent / "calls.jsonl").exists())

        status, _, stderr = self.run_cli("run", "--output", str(self.root / "missing"), "--binary", str(self.root / "nothing"))
        self.assertEqual((status, "not an executable file" in stderr), (2, True))
        existing = self.root / "existing"
        existing.mkdir()
        status, _, stderr = self.run_cli(*base, "--output", str(existing))
        self.assertEqual((status, "never overwritten" in stderr), (2, True))
        for arguments in (["run"], ["run", "--output", "x", "--backing", "smp"], ["run", "--output", "x", "--rounds", "many"], ["replay"]):
            with self.assertRaises(SystemExit) as raised, contextlib.redirect_stderr(io.StringIO()):
                placement_bench.main(arguments)
            self.assertEqual(raised.exception.code, 2, arguments)

    def test_every_run_gets_the_same_explicit_environment_and_explicit_arguments(self):
        with patch.dict(os.environ, {"TELAR_BENCH_PLACEMENT": "pack", "TELAR_PANE_ID": "7", "MALLOC_NANO_ZONE": "0"}):
            status, text, results = self.run_pairs("--threshold", "40000", "--variant", "baseline=baseline",
                                                   "--variant", "stagger_panes=stagger:65536", "--variant", "pack=pack")
        self.assertEqual(status, 0, text)
        calls = self.calls()
        self.assertEqual(len(calls), 9)
        output = (self.root / "out").resolve()
        expected = {"PATH": "/usr/bin:/bin", "HOME": str(output / "home"), "LANG": "C"}
        # The stand-in's own interpreter and macOS add these two to any process; the runner passes neither.
        added_by_the_stand_in = ("__CF_USER_TEXT_ENCODING", "LC_CTYPE")
        for call in calls:
            self.assertEqual({key: value for key, value in call["environ"].items() if key not in added_by_the_stand_in}, expected)
            self.assertEqual(call["argv"].count("--placement-report"), 1)
            self.assertNotIn("--placement-window", call["argv"])
        self.assertEqual(results["provenance"]["run_environment"], expected)
        thresholds = {call["argv"][call["argv"].index("--placement") + 1]: call["argv"][call["argv"].index("--placement-threshold") + 1] for call in calls}
        self.assertEqual(thresholds, {"baseline": "40000", "stagger": "65536", "pack": "40000"})
        order = [[call["argv"][call["argv"].index("--placement") + 1] for call in calls[start:start + 3]] for start in (0, 3, 6)]
        self.assertEqual(order, [["baseline", "stagger", "pack"], ["baseline", "pack", "stagger"], ["pack", "baseline", "stagger"]])

    def test_results_carry_provenance_raw_output_and_paired_statistics(self):
        status, text, results = self.run_pairs()
        self.assertEqual(status, 0, text)
        self.assertTrue(results["complete"])
        self.assertEqual(len(results["runs"]), 12)
        provenance = results["provenance"]
        self.assertEqual(provenance["binary"]["sha256"], placement_bench.sha256(self.binary))
        self.assertFalse(provenance["binary"]["built_by_runner"])
        self.assertIsNone(provenance["build"])
        self.assertEqual(provenance["host"]["page_bytes"], os.sysconf("SC_PAGE_SIZE"))
        for key in ("revision", "modified_paths", "untracked_paths"):
            self.assertIn(key, provenance["source"])
        self.assertEqual(results["settings"]["backing"], "libc")
        self.assertEqual(results["benchmark_metadata"]["mode"], "ReleaseFast")
        self.assertEqual(results["layout"][0]["record"], "pane")
        for run in results["runs"]:
            raw = (self.root / "out" / run["stdout"]).read_text()
            self.assertIn('"type": "benchmark"', raw)
            self.assertEqual((run["status"], run["returncode"], run["problems"]), ("ok", 0, []))
            self.assertEqual(run["cases"][CASES[0]]["shape"], {"clients": 2, "panes": 8, "cols": 154, "rows": 37})
            self.assertEqual(run["cases"][CASES[1]]["placement"]["records"]["attachment"]["count"], 32)

        stagger = results["derived"][CASES[0]]["median_ns_per_op"]["stagger"]
        self.assertEqual((stagger["median"], stagger["wins"], stagger["pairs"], stagger["runs"]), (800, 3, 3, 3))
        self.assertAlmostEqual(stagger["median_paired_change_pct"], -20.0)
        self.assertAlmostEqual(stagger["min_paired_change_pct"], -25.0)
        shift = results["derived"][CASES[1]]["median_ns_per_op"]["shift"]
        self.assertEqual((shift["wins"], shift["losses"], shift["ties"]), (1, 1, 1))
        self.assertIn("stagger", text)
        self.assertIn("3/3", text)

        status, text, _ = self.run_cli("replay", str(self.root / "out" / "results.json"))
        self.assertEqual(status, 0, text)
        self.assertIn("replay matches", text)

    def test_source_state_names_modified_and_untracked_paths_whole(self):
        repository = self.root / "repository"
        repository.mkdir()
        git = ["git", "-c", "user.name=test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false"]
        subprocess.run([*git, "init", "--quiet"], cwd=repository, check=True)
        (repository / "tracked.zig").write_text("one\n")
        subprocess.run([*git, "add", "tracked.zig"], cwd=repository, check=True)
        subprocess.run([*git, "commit", "--quiet", "-m", "first"], cwd=repository, check=True)
        clean = placement_bench.source_state(repository)
        self.assertEqual((clean["modified_paths"], clean["untracked_paths"], len(clean["revision"])), ([], [], 40))

        (repository / "tracked.zig").write_text("two\n")
        (repository / "new.zig").write_text("new\n")
        dirty = placement_bench.source_state(repository)
        self.assertEqual((dirty["modified_paths"], dirty["untracked_paths"]), (["tracked.zig"], ["new.zig"]))
        self.assertEqual(dirty["revision"], clean["revision"])

    def test_replay_notices_statistics_that_no_longer_follow_from_the_runs(self):
        self.run_pairs()
        path = self.root / "out" / "results.json"
        results = json.loads(path.read_text())
        results["derived"][CASES[0]]["median_ns_per_op"]["pack"]["wins"] = 0
        path.write_text(json.dumps(results))
        status, text, _ = self.run_cli("replay", str(path))
        self.assertEqual(status, 1)
        self.assertIn("REPLAY DIFFERS", text)
        self.assertIn("3/3", text)

        path.write_text("{}")
        self.assertEqual(self.run_cli("replay", str(path))[0], 2)
        self.assertEqual(self.run_cli("replay", str(self.root / "absent.json"))[0], 2)

    def test_a_failing_run_is_kept_as_a_failure_and_leaves_its_round_unpaired(self):
        self.behave(pack={"fail_after_calls": 1})
        status, text, results = self.run_pairs()
        self.assertEqual(status, 1)
        failed = [run for run in results["runs"] if run["status"] == "failed"]
        self.assertEqual([(run["variant"], run["round"], run["returncode"]) for run in failed], [("pack", 1, 1), ("pack", 2, 1)])
        self.assertIn("exited with status 1: error: IdleDeliveryStartedWrite", failed[0]["problems"][0])
        self.assertIn("IdleDeliveryStartedWrite", (self.root / "out" / failed[0]["stderr"]).read_text())
        pack = results["derived"][CASES[0]]["median_ns_per_op"]["pack"]
        self.assertEqual((pack["runs"], pack["runs_not_counted"], pack["pairs"], pack["wins"]), (1, 2, 1, 1))
        self.assertEqual(results["derived"][CASES[0]]["median_ns_per_op"]["stagger"]["pairs"], 3)
        self.assertIn("not counted: round 1 pack", text)

    def test_a_run_that_is_not_idle_leaks_or_misses_records_does_not_count(self):
        for quirk, message in (({"busy": True}, "not idle after timing"), ({"leaked": 2}, "never freed"), ({"missing_panes": 1}, "pane records")):
            with self.subTest(quirk=quirk):
                self.behave(stagger=quirk)
                status, _, results = self.run_pairs(name="out-" + "-".join(quirk))
                self.assertEqual(status, 1)
                stagger = [run for run in results["runs"] if run["variant"] == "stagger"]
                self.assertTrue(all(run["status"] == "failed" and run["returncode"] == 0 for run in stagger))
                self.assertTrue(any(message in problem for problem in stagger[0]["problems"]), stagger[0]["problems"])
                self.assertEqual(results["derived"][CASES[0]]["median_ns_per_op"]["stagger"]["pairs"], 0)
                self.assertEqual(results["derived"][CASES[0]]["median_ns_per_op"]["pack"]["pairs"], 3)

    def test_a_different_layout_between_variants_is_reported(self):
        self.behave(pack={"pane_bytes": 900000})
        status, text, results = self.run_pairs()
        self.assertEqual(status, 1)
        self.assertEqual(results["consistency_problems"], ["record layout differs between runs"])
        self.assertIn("inconsistent: record layout differs", text)

    def test_a_run_past_its_timeout_is_recorded_and_the_rounds_continue(self):
        self.behave(shift={"sleep": 5})
        status, _, results = self.run_pairs("--timeout", "0.5", "--variant", "baseline=baseline", "--variant", "shift=shift")
        self.assertEqual(status, 1)
        self.assertEqual(len(results["runs"]), 6)
        shift = [run for run in results["runs"] if run["variant"] == "shift"]
        self.assertTrue(all(run["timed_out"] and run["status"] == "failed" for run in shift))
        self.assertIn("timed out", shift[0]["problems"][0])

    def test_the_walk_keeps_flush_and_clock_sums_apart(self):
        status, text, results = self.run_pairs("--intervening-walk", "524288")
        self.assertEqual(status, 0, text)
        self.assertTrue(all("--intervening-walk" in call["argv"] for call in self.calls()))
        case = results["runs"][0]["cases"][CASES[0]]
        self.assertEqual(case["walk"], {"walk_bytes": 524288, "walk_stride_bytes": 64, "flushes": 1000, "flush_ns": 1000000, "empty_clock_ns": 40000})
        self.assertEqual((case["walk_flush_ns_per_flush"], case["walk_empty_clock_ns_per_flush"], case["walk_flush_minus_clock_ns_per_flush"]), (1000, 40, 960))
        derived = results["derived"][CASES[0]]
        self.assertEqual(set(derived), {"median_ns_per_op", "walk_flush_ns_per_flush", "walk_empty_clock_ns_per_flush", "walk_flush_minus_clock_ns_per_flush"})
        self.assertEqual(derived["walk_flush_minus_clock_ns_per_flush"]["pack"]["median"], 660)
        self.assertIn("walk_flush_minus_clock_ns_per_flush", text)


if __name__ == "__main__":
    unittest.main()
