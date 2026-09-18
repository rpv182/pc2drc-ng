#!/usr/bin/env bash
# Probe every known TSF source. Used by install and start, and by humans.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

pc2drc_need_linux

read_tsf_file() {
  local path="$1"
  [[ -r "${path}" ]] || return 1
  python3 - "$path" <<'PY'
import os, sys, struct
path = sys.argv[1]
data = open(path, "rb").read()
if not data:
    print("empty")
    sys.exit(0)
text = data.decode("ascii", "replace").strip()
if text.startswith("0x") or (len(data) != 8 and all(c in "0123456789abcdefABCDEFx\n\r\t " for c in text)):
    try:
        val = int(text, 0)
        print(f"ascii {text} -> {val} (0x{val:016x})")
        sys.exit(0)
    except ValueError:
        pass
if len(data) >= 8:
    val = struct.unpack_from("<Q", data)[0]
    print(f"binary le {val} (0x{val:016x})")
    if val in (0, 0xFFFFFFFFFFFFFFFF):
        sys.exit(2)
    sys.exit(0)
print(f"unknown {data[:32]!r}")
sys.exit(1)
PY
}

status=1
ifaces=()
if [[ "${1:-}" != "" ]]; then
  ifaces=("$1")
else
  mapfile -t ifaces < <(pc2drc_wifi_ifaces)
fi

if [[ ${#ifaces[@]} -eq 0 ]]; then
  echo "No wireless interfaces found."
  exit 1
fi

mkdir -p /sys/kernel/debug 2>/dev/null || true
if ! mountpoint -q /sys/kernel/debug 2>/dev/null; then
  mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true
fi

for iface in "${ifaces[@]}"; do
  echo "== ${iface} =="
  echo "driver: $(pc2drc_iface_driver "${iface}")"
  phy="$(pc2drc_phy_for_iface "${iface}")"
  echo "phy: ${phy:-unknown}"
  case "$(pc2drc_iface_driver "${iface}")" in
    iwlwifi|iwldvm|iwlmvm)
      echo "WARNING: Intel iwlwifi does not expose get_tsf and usually cannot host a 5 GHz AP. Use an RT5572 / rt2800usb adapter."
      ;;
  esac

  candidates=(
    "/sys/class/net/${iface}/tsf"
    "/sys/class/net/${iface}/device/tsf"
  )
  if [[ -n "${phy}" ]]; then
    candidates+=(
      "/sys/kernel/debug/ieee80211/${phy}/tsf"
      "/sys/kernel/debug/ieee80211/${phy}/netdev:${iface}/tsf"
    )
  fi

  found=0
  for path in "${candidates[@]}"; do
    if [[ -e "${path}" ]]; then
      echo -n "  ${path}: "
      if read_tsf_file "${path}"; then
        found=1
        status=0
      else
        rc=$?
        if [[ $rc -eq 2 ]]; then
          echo "  (driver returned 0 or -1; this NIC likely has no get_tsf)"
        fi
      fi
    fi
  done
  if [[ ${found} -eq 0 ]]; then
    echo "  no TSF file found (debugfs export is enough; a mac80211 sysfs patch is optional)"
  fi
  echo
done

exit "${status}"
