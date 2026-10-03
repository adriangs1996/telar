#!/bin/sh
set -eu
BIN=$1; OUT=$2
TOOLS=${TELAR_TOOLS:-$(cd "$(dirname "$0")/../../../../tools" && pwd)}
mkdir -p "$OUT"
unset SSH_CONNECTION SSH_CLIENT SSH_TTY
for variant in idle dense text120; do
  case $variant in idle) extra="";; dense) extra="--dense";; text120) extra="--stream 120 --stream-text";; esac
  echo "== small-$variant $(date +%T)"
  python3 "$TOOLS/gui_latency.py" "$BIN" "$OUT/$variant" --samples 100 --config "$(dirname "$0")/gate_small_font.lua" --raw-echo --settle 3 $extra > "$OUT/$variant.log" 2>&1 || { echo "FAILED $variant"; tail -3 "$OUT/$variant.log"; }
  python3 -c "import json,sys; s=json.load(open(sys.argv[1])); print({k: s.get(k) for k in ('p50_ms','p95_ms','p99_ms','max_ms','prepare_ms','viewport','baseline_glyphs')})" "$OUT/$variant/summary.json" || true
done
echo "small done"
