#!/bin/sh
# Frame equivalence oracle: SHA-256 of every quad byte and the full glyph
# atlas after each frame, for every terminal mode of telar-dod-probe.
# usage: probe_verify.sh BASELINE_PREFIX CANDIDATE_PREFIX
# Prints one OK/MISMATCH line per mode and exits non-zero on any mismatch.
set -eu
out=$(mktemp -d)
status=0
for mode in retained sparse full theme resize selection font two_one_active two_all_active cursor focus reattach; do
  for side in a b; do
    prefix=$1; [ "$side" = b ] && prefix=$2
    DOD_TERMINAL_ONLY=1 DOD_VERIFY=1 DOD_MODE=$mode DOD_SAMPLES=40 DOD_WARMUP=4 \
      "$prefix/bin/telar-dod-probe" | grep '"frame"' > "$out/$side-$mode" || true
  done
  if [ -s "$out/a-$mode" ] && cmp -s "$out/a-$mode" "$out/b-$mode"; then
    echo "$mode OK $(wc -l < "$out/a-$mode" | tr -d ' ') frames"
  else
    echo "$mode MISMATCH"; status=1
  fi
done
rm -rf "$out"
exit $status
