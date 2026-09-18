#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

pc2drc_need_linux
pc2drc_need_root

if [[ -f "${PC2DRC_STATE}/config.json" ]]; then
  iface="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("iface",""))' "${PC2DRC_STATE}/config.json" || true)"
  if [[ -n "${iface}" ]]; then
    pc2drc_restore_iface "${iface}"
  fi
fi

killall -q drcvncclient hostapd netboot Xtigervnc 2>/dev/null || true
if command -v tigervncserver >/dev/null 2>&1; then
  tigervncserver -kill :1 >/dev/null 2>&1 || true
elif command -v vncserver >/dev/null 2>&1; then
  vncserver -kill :1 >/dev/null 2>&1 || true
fi

echo "Stopped. Normal Wi-Fi on the USB adapter should come back via NetworkManager."
