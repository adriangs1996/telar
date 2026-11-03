#!/bin/bash
set -euo pipefail

export QT_QUICK_BACKEND=software
exec "${OMARCHY_PATH:-/usr/share/omarchy}/bin/omarchy-launch-shell" "$@"
