#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

pc2drc_need_linux

echo "pc2drc-ng hardware / OS check"
echo "kernel: $(uname -r)"
echo "distro: $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}" || echo unknown)"
echo

if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${VERSION_ID:-}" in
    20.04)
      echo "NOTE: Ubuntu 20.04 is end of standard support. This installer still tries to work there,"
      echo "      but 22.04 or 24.04 is a much less painful host."
      echo
      ;;
    22.04|24.04|24.10|25.04|25.10|26.04) ;;
    *)
      echo "WARNING: ${PRETTY_NAME:-this distro} is untested. Debian 12/13 and Ubuntu 22.04+ are the intended targets."
      echo
      ;;
  esac
fi

mapfile -t ifaces < <(pc2drc_wifi_ifaces)
if [[ ${#ifaces[@]} -eq 0 ]]; then
  echo "No wireless interfaces found. Plug in an 802.11n 5 GHz USB adapter (RT5572 / rt2800usb)."
  exit 1
fi

echo "Wireless interfaces:"
ok_any=0
for iface in "${ifaces[@]}"; do
  driver="$(pc2drc_iface_driver "${iface}")"
  echo "  - ${iface}  driver=${driver}"
  case "${driver}" in
    rt2800usb|rt2800pci|rt2x00usb|mt76x2u|mt76x0u|mt76x2|rtl8821ae|rtl8812ae|ath9k|ath10k_pci)
      echo "    looks compatible (5 GHz AP + TSF possible)"
      ok_any=1
      ;;
    iwlwifi|iwldvm|iwlmvm)
      echo "    INCOMPATIBLE: Intel iwlwifi does not export TSF and is a poor 5 GHz AP."
      ;;
    *)
      echo "    unknown; we will still try. Known-good: RT5572 USB (rt2800usb)."
      ;;
  esac
  if command -v iw >/dev/null 2>&1; then
    if iw phy "$(pc2drc_phy_for_iface "${iface}")" info 2>/dev/null | grep -q 'AP'; then
      echo "    AP mode: yes"
    else
      echo "    AP mode: not advertised (iw phy info)"
    fi
    if iw phy "$(pc2drc_phy_for_iface "${iface}")" info 2>/dev/null | grep -q '5180'; then
      echo "    5 GHz: yes"
    else
      echo "    5 GHz: not obvious from iw; set regulatory domain with: sudo iw reg set US"
    fi
  fi
done
echo

if [[ ${ok_any} -eq 0 ]]; then
  echo "WARNING: no obviously compatible adapter. The GamePad needs a 5 GHz AP whose driver implements get_tsf()."
  echo "         Buy a cheap RT5572 USB stick. Intel onboard Wi-Fi will not work."
fi

if ip -o addr show | grep -q '192\.168\.1\.'; then
  echo "WARNING: something already uses 192.168.1.0/24. libdrc hardcodes 192.168.1.10/11."
  echo "         Disconnect that network before starting the stream."
fi

echo
echo "TSF probe (may be empty until the AP is up):"
if [[ "$(id -u)" -eq 0 ]]; then
  "${SCRIPT_DIR}/../lib/tsf.sh" || true
else
  echo "  re-run as root to read debugfs: sudo ./scripts/check-system.sh"
fi
