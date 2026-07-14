#!/usr/bin/env bash
set -euo pipefail

tools_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec python3 "$tools_dir/soa_report.py" "$@"
