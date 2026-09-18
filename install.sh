#!/usr/bin/env bash
# One-shot installer for pc2drc-ng.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0" 2>/dev/null || python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$0")")"
# shellcheck source=lib/common.sh
source ./lib/common.sh

pc2drc_need_linux
pc2drc_need_root

PC2DRC_LOG_FILE="${PC2DRC_LOGS}/install-$(date +%Y%m%d-%H%M%S).log"
export PC2DRC_LOG_FILE
touch "${PC2DRC_LOG_FILE}"
exec > >(tee -a "${PC2DRC_LOG_FILE}") 2>&1

chmod +x install.sh pair.sh start.sh stop.sh ui.sh \
  lib/tsf.sh \
  scripts/*.sh \
  conf/vnc-xstartup 2>/dev/null || true

pc2drc_log "pc2drc-ng installer"
pc2drc_log "root=${PC2DRC_ROOT}"
pc2drc_log "user=$(pc2drc_real_user) home=$(pc2drc_real_home)"
pc2drc_log "log=${PC2DRC_LOG_FILE}"

if ! pc2drc_have_internet; then
  pc2drc_ensure_dns archive.ubuntu.com || pc2drc_ensure_dns github.com || true
fi
if ! pc2drc_have_internet; then
  pc2drc_die "Internet is required for the first install (apt + git clone + OpenSSL/libnl sources). Plug Ethernet / Wi-Fi back in and retry."
fi

./scripts/check-system.sh || true
./scripts/install-deps.sh
./scripts/build.sh

if ! mountpoint -q /sys/kernel/debug 2>/dev/null; then
  mkdir -p /sys/kernel/debug
  mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true
fi

pc2drc_log "TSF probe after build:"
./lib/tsf.sh || true

# install.sh runs as root and writes vendor/prefix/logs; give them back to the user
# so a later `rm -rf ~/pc2drc-ng` does not hit permission denied.
if [[ "$(pc2drc_real_user)" != "root" ]]; then
  chown -R "$(pc2drc_real_user):" "${PC2DRC_ROOT}/vendor" "${PC2DRC_PREFIX}" "${PC2DRC_LOGS}" 2>/dev/null || true
fi

echo
echo "============================================================"
echo " Install finished."
echo
echo " Next (pair + VNC host in one UI):"
echo "   sudo bash ./ui.sh"
echo "   then open http://127.0.0.1:8540"
echo
echo " Or the old two-script path:"
echo "   sudo bash ./pair.sh"
echo "   sudo bash ./start.sh"
echo
echo " Logs: ${PC2DRC_LOGS}"
echo " Full install log: ${PC2DRC_LOG_FILE}"
echo "============================================================"
