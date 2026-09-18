#!/usr/bin/env bash
# Shared helpers for pc2drc-ng. Source this; do not execute it.

if [[ -n "${PC2DRC_COMMON_LOADED:-}" ]]; then
  return 0
fi
PC2DRC_COMMON_LOADED=1

PC2DRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PC2DRC_ROOT

PC2DRC_VENDOR="${PC2DRC_ROOT}/vendor/upstream"
PC2DRC_PREFIX="${PC2DRC_ROOT}/prefix"
PC2DRC_STATE="${PC2DRC_ROOT}/state"
PC2DRC_LOGS="${PC2DRC_ROOT}/logs"
PC2DRC_PATCHES="${PC2DRC_ROOT}/patches"

mkdir -p "${PC2DRC_STATE}" "${PC2DRC_LOGS}" "${PC2DRC_PREFIX}" "${PC2DRC_ROOT}/vendor"

_pc2drc_timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

pc2drc_log() {
  local msg="[$(_pc2drc_timestamp)] $*"
  echo "${msg}"
  if [[ -n "${PC2DRC_LOG_FILE:-}" ]]; then
    echo "${msg}" >> "${PC2DRC_LOG_FILE}"
  fi
}

pc2drc_die() {
  pc2drc_log "ERROR: $*"
  exit 1
}

pc2drc_real_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "${SUDO_USER}"
  elif [[ -n "${PC2DRC_USER:-}" ]]; then
    echo "${PC2DRC_USER}"
  else
    id -un
  fi
}

pc2drc_real_home() {
  local user
  user="$(pc2drc_real_user)"
  getent passwd "${user}" | cut -d: -f6
}

pc2drc_need_linux() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    pc2drc_die "pc2drc-ng only runs on Linux (native Ubuntu/Debian). WSL and Windows cannot bind a USB Wi-Fi adapter as a 5 GHz AP."
  fi
}

pc2drc_need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    pc2drc_die "Run as: sudo ./$(basename "$0")"
  fi
}

pc2drc_need_cmd() {
  command -v "$1" >/dev/null 2>&1 || pc2drc_die "Missing command: $1"
}

pc2drc_have_internet() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 8 https://github.com >/dev/null 2>&1 && return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q --timeout=8 --spider https://github.com >/dev/null 2>&1 && return 0
  fi
  if command -v ping >/dev/null 2>&1; then
    ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 && return 0
  fi
  return 1
}

pc2drc_wifi_ifaces() {
  local d
  for d in /sys/class/net/*; do
    [[ -d "${d}/wireless" || -L "${d}/phy80211" ]] || continue
    basename "${d}"
  done
}

pc2drc_iface_driver() {
  local iface="$1"
  local driver_path="/sys/class/net/${iface}/device/driver"
  if [[ -L "${driver_path}" ]]; then
    basename "$(readlink -f "${driver_path}")"
  else
    echo "unknown"
  fi
}

pc2drc_phy_for_iface() {
  local iface="$1"
  local phy_link="/sys/class/net/${iface}/phy80211"
  if [[ -e "${phy_link}" ]]; then
    basename "$(readlink -f "${phy_link}")"
  fi
}

pc2drc_unmanage_iface() {
  local iface="$1"
  if command -v nmcli >/dev/null 2>&1; then
    nmcli device set "${iface}" managed no >/dev/null 2>&1 || true
  fi
  if [[ -d /etc/NetworkManager/conf.d ]]; then
    cat > "/etc/NetworkManager/conf.d/99-pc2drc-ng-${iface}.conf" <<EOF
[keyfile]
unmanaged-devices=interface-name:${iface}
EOF
    if command -v systemctl >/dev/null 2>&1; then
      systemctl reload NetworkManager >/dev/null 2>&1 || true
    fi
  fi
}

pc2drc_restore_iface() {
  local iface="$1"
  rm -f "/etc/NetworkManager/conf.d/99-pc2drc-ng-${iface}.conf"
  if command -v nmcli >/dev/null 2>&1; then
    nmcli device set "${iface}" managed yes >/dev/null 2>&1 || true
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload NetworkManager >/dev/null 2>&1 || true
  fi
}

pc2drc_export_build_env() {
  export PREFIX="${PC2DRC_PREFIX}"
  export PATH="${PC2DRC_PREFIX}/bin:${PATH}"
  export LD_LIBRARY_PATH="${PC2DRC_PREFIX}/lib:${LD_LIBRARY_PATH:-}"
  export PKG_CONFIG_PATH="${PC2DRC_PREFIX}/lib/pkgconfig:${PC2DRC_PREFIX}/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
  export CFLAGS="-I${PC2DRC_PREFIX}/include ${CFLAGS:-}"
  export CXXFLAGS="-I${PC2DRC_PREFIX}/include ${CXXFLAGS:-}"
  export LDFLAGS="-L${PC2DRC_PREFIX}/lib -L${PC2DRC_PREFIX}/lib64 ${LDFLAGS:-}"
}

pc2drc_sudo_env() {
  # Preserve prefix libraries when a child process is started with sudo.
  echo "LD_LIBRARY_PATH=${PC2DRC_PREFIX}/lib:${PC2DRC_PREFIX}/lib64:${LD_LIBRARY_PATH:-}"
}
