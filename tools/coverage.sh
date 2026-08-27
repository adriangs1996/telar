#!/bin/sh
set -eu

project_root=$(
    unset CDPATH
    cd -- "$(dirname -- "$0")/.."
    pwd
)
zig_cov=${ZIG_COV_BIN:-zig-cov}
coverage_file=${TELAR_COVERAGE_FILE:-$project_root/coverage.lcov}

if ! command -v "$zig_cov" >/dev/null 2>&1; then
    printf 'telar: %s was not found; set ZIG_COV_BIN to the zig-cov executable\n' "$zig_cov" >&2
    exit 127
fi

cd "$project_root"
exec "$zig_cov" test \
    --project="$project_root" \
    --format=lcov \
    --output="$coverage_file" \
    --exclude=zig-pkg/ \
    --exclude=.zig-cache/ \
    --exclude=vendor/ \
    "$@"
