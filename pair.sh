#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$(readlink -f "$0" 2>/dev/null || python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$0")")"
exec python3 ./scripts/pair.py "$@"
