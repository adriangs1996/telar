import json, os, subprocess, sys, statistics
binary = sys.argv[1]
child = sys.argv[2]
rounds = int(sys.argv[3])
variants = [
    ("none", {"TELAR_BENCH_PLACEMENT": "none"}),
    ("shift", {"TELAR_BENCH_PLACEMENT": "shift"}),
    ("color_panes", {"TELAR_BENCH_PLACEMENT": "color", "TELAR_BENCH_THRESHOLD": "65536"}),
    ("color_all", {"TELAR_BENCH_PLACEMENT": "color"}),
    ("pack", {"TELAR_BENCH_PLACEMENT": "pack"}),
]
cases = ["backend.delivery.flush_idle_2x8", "backend.delivery.flush_idle_1x32"]
results = {case: {name: [] for name, _ in variants} for case in cases}
for round_index in range(rounds):
    order = variants[round_index % len(variants):] + variants[:round_index % len(variants)]
    if round_index % 2:
        order = order[::-1]
    for name, env in order:
        full = dict(os.environ, TELAR_BENCH_CHILD=child, **env)
        out = subprocess.run(["taskpolicy", "-b", binary, "--filter", "backend.delivery.flush_idle", "--json"], env=full, capture_output=True, text=True, check=True).stdout
        for line in out.splitlines():
            row = json.loads(line)
            if row.get("type") == "benchmark":
                results[row["name"]][name].append(row["median_ns_per_op"])
    print("round", round_index, flush=True)
json.dump(results, open(sys.argv[4], "w"))
for case in cases:
    base = results[case]["none"]
    print(case)
    for name, _ in variants:
        values = results[case][name]
        ratios = [(v / b - 1) * 100 for v, b in zip(values, base)]
        wins = sum(1 for v, b in zip(values, base) if v < b)
        print(f"  {name:12s} median {statistics.median(values):7.0f} ns  paired {statistics.median(ratios):+6.1f}%  range {min(ratios):+6.1f}..{max(ratios):+6.1f}  wins {wins}/{len(values)}")
