#!/bin/sh
# Profile one build: key -> GPU completion with prepare traces in four
# scenes, then the four-pane flood with the probe's draw diagnostics.
set -eu
BIN=$1
OUT=$2
TOOLS=${TELAR_TOOLS:-$(cd "$(dirname "$0")/../../../../tools" && pwd)}
mkdir -p "$OUT"
unset SSH_CONNECTION SSH_CLIENT SSH_TTY
for variant in idle dense text120 image120; do
  case $variant in
    idle) extra="";;
    dense) extra="--dense";;
    text120) extra="--stream 120 --stream-text";;
    image120) extra="--stream 120";;
  esac
  echo "== $variant $(date +%T)"
  python3 "$TOOLS/gui_latency.py" "$BIN" "$OUT/$variant" --samples 100 --config "$TOOLS/gui_graphics_gate.lua" --raw-echo --settle 3 $extra > "$OUT/$variant.log" 2>&1 || { echo "FAILED $variant"; tail -5 "$OUT/$variant.log"; }
  python3 - "$OUT/$variant/summary.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
print({k: s.get(k) for k in ('p50_ms', 'p95_ms', 'p99_ms', 'max_ms', 'prepare_ms', 'viewport', 'baseline_glyphs')})
PY
done
echo "== splits-load diagnostics $(date +%T)"
TGB_DRAW_DIAGNOSTICS=1 python3 "$TOOLS/gui_tui_latency.py" "$BIN" "$OUT/load" --mode gui --cases single splits-load --panes 4 --rounds 1 --samples 100 --viewport 1900 1100 --float-windows > "$OUT/load.log" 2>&1 || { echo "FAILED load"; tail -5 "$OUT/load.log"; }
tail -12 "$OUT/load.log"
