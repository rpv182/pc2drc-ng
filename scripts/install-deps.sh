#!/usr/bin/env bash
# Install build/runtime packages. Fresh Ubuntu ISOs often ship with the CDROM
# listed as an apt source and with universe disabled, so ffmpeg/openbox/TigerVNC
# are simply not in the package lists until we fix sources.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

pc2drc_need_linux
pc2drc_need_root

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE="${NEEDRESTART_MODE:-a}"
export APT_LISTCHANGES_FRONTEND="${APT_LISTCHANGES_FRONTEND:-none}"

if ! command -v apt-get >/dev/null 2>&1; then
  pc2drc_die "This installer expects apt (Ubuntu/Debian)."
fi

# shellcheck disable=SC1091
. /etc/os-release
OS_ID="${ID:-unknown}"
OS_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
OS_VERSION_ID="${VERSION_ID:-}"

APT_GET=(apt-get -o Acquire::Retries=5 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30)

pc2drc_apt_update() {
  local attempt
  for attempt in 1 2 3; do
    if "${APT_GET[@]}" update; then
      return 0
    fi
    pc2drc_log "apt-get update failed (attempt ${attempt}/3)"
    pc2drc_ensure_dns archive.ubuntu.com || pc2drc_ensure_dns security.ubuntu.com || true
    sleep $((attempt * 2))
  done
  return 1
}

pc2drc_pkg_available() {
  local cand
  cand="$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
  [[ -n "${cand}" && "${cand}" != "(none)" ]]
}

# Install every package that currently has a candidate. Prints skips.
# Returns 0 if at least one package was installed.
pc2drc_apt_install_available() {
  local -a have=() missing=()
  local pkg
  for pkg in "$@"; do
    if pc2drc_pkg_available "${pkg}"; then
      have+=("${pkg}")
    else
      missing+=("${pkg}")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    pc2drc_log "not in this distro's apt (skipped): ${missing[*]}"
  fi
  if [[ ${#have[@]} -eq 0 ]]; then
    return 1
  fi
  if "${APT_GET[@]}" install -y --no-install-recommends "${have[@]}"; then
    return 0
  fi
  pc2drc_log "batch install failed; retrying after DNS/apt recover"
  pc2drc_ensure_dns archive.ubuntu.com || true
  "${APT_GET[@]}" update >/dev/null 2>&1 || true
  if "${APT_GET[@]}" install -y --fix-missing --no-install-recommends "${have[@]}"; then
    return 0
  fi
  # A single broken/held package must not abort a fresh install of the rest.
  pc2drc_log "batch install failed; trying packages one at a time"
  local ok=0
  for pkg in "${have[@]}"; do
    if "${APT_GET[@]}" install -y --fix-missing --no-install-recommends "${pkg}"; then
      ok=1
    else
      pc2drc_log "WARNING: apt could not install ${pkg}"
    fi
  done
  [[ "${ok}" -eq 1 ]]
}

pc2drc_require_cmds() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    pc2drc_die "Required commands still missing after apt install: ${missing[*]}"
  fi
}

pc2drc_sources_have_http() {
  grep -RshE '^[[:space:]]*deb[[:space:]]+' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null \
    | grep -vE 'cdrom:' \
    | grep -qE 'https?://' && return 0
  shopt -s nullglob
  local f
  for f in /etc/apt/sources.list.d/*.sources; do
    if grep -qE '^URIs:.*https?://' "${f}"; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

pc2drc_universe_enabled() {
  grep -RshE '^[[:space:]]*deb[[:space:]]+' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null \
    | grep -vE 'cdrom:' \
    | grep -qw universe && return 0
  shopt -s nullglob
  local f
  for f in /etc/apt/sources.list.d/*.sources; do
    if grep -E '^Components:' "${f}" | grep -qw universe; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

pc2drc_disable_cdrom_sources() {
  local f
  shopt -s nullglob
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [[ -f "${f}" ]] || continue
    if grep -qE '^[[:space:]]*deb(-src)?[[:space:]]+cdrom:' "${f}"; then
      pc2drc_log "Disabling CDROM apt source in ${f} (ISO leftover; it only has the disc package set)"
      if [[ "${f}" == /etc/apt/sources.list && ! -f /etc/apt/sources.list.pc2drc-ng.bak ]]; then
        cp -a /etc/apt/sources.list /etc/apt/sources.list.pc2drc-ng.bak
      fi
      sed -i -E 's/^([[:space:]]*deb(-src)?[[:space:]]+cdrom:)/# \1/' "${f}"
    fi
  done
  shopt -u nullglob
}

pc2drc_ubuntu_mirror() {
  local arch
  arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
  case "${arch}" in
    amd64|i386) echo "http://archive.ubuntu.com/ubuntu" ;;
    *) echo "http://ports.ubuntu.com/ubuntu-ports" ;;
  esac
}

pc2drc_write_ubuntu_sources_dropin() {
  local mirror codename dest
  dest="/etc/apt/sources.list.d/pc2drc-ng-ubuntu.list"
  mirror="$(pc2drc_ubuntu_mirror)"
  codename="${OS_CODENAME}"
  if [[ -z "${codename}" ]]; then
    pc2drc_die "Could not detect Ubuntu codename; cannot enable archive.ubuntu.com."
  fi
  pc2drc_log "Writing ${dest} for ${codename} (main restricted universe multiverse)"
  cat > "${dest}" <<EOF
# Added by pc2drc-ng so a fresh ISO install can see universe packages
# (ffmpeg, openbox, TigerVNC, yasm, libsdl*, …). Safe to delete later.
deb ${mirror} ${codename} main restricted universe multiverse
deb ${mirror} ${codename}-updates main restricted universe multiverse
deb ${mirror} ${codename}-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu ${codename}-security main restricted universe multiverse
EOF
}

pc2drc_enable_ubuntu_universe() {
  local f
  shopt -s nullglob
  for f in /etc/apt/sources.list.d/*.sources; do
    if grep -qE '^Components:' "${f}" && ! grep -E '^Components:' "${f}" | grep -qw universe; then
      pc2drc_log "Adding universe/restricted/multiverse to ${f}"
      sed -i -E 's/^(Components:.*)$/\1 universe restricted multiverse/' "${f}"
    fi
  done
  shopt -u nullglob

  if [[ -f /etc/apt/sources.list ]]; then
    # Uncomment the stock "deb … universe" lines the installer leaves hashed out.
    sed -i -E 's/^[[:space:]]*#[[:space:]]*(deb(-src)?[[:space:]]+https?:[^#]*\buniverse\b.*)$/\1/' /etc/apt/sources.list
    sed -i -E 's/^[[:space:]]*#[[:space:]]*(deb(-src)?[[:space:]]+https?:[^#]*\bmultiverse\b.*)$/\1/' /etc/apt/sources.list
  fi

  if command -v add-apt-repository >/dev/null 2>&1; then
    pc2drc_log "Enabling Ubuntu universe / restricted / multiverse..."
    add-apt-repository -y universe || true
    add-apt-repository -y restricted || true
    add-apt-repository -y multiverse || true
  fi

  if ! pc2drc_universe_enabled; then
    pc2drc_write_ubuntu_sources_dropin
  fi
}

pc2drc_enable_debian_components() {
  # ffmpeg/openbox/TigerVNC live in Debian main; a DVD install may still
  # only have the cdrom source. Guarantee a network mirror.
  if pc2drc_sources_have_http; then
    return 0
  fi
  local dest="/etc/apt/sources.list.d/pc2drc-ng-debian.list"
  if [[ -z "${OS_CODENAME}" ]]; then
    pc2drc_die "Could not detect Debian codename; cannot enable deb.debian.org."
  fi
  pc2drc_log "Writing ${dest} for ${OS_CODENAME} (DVD/CDROM-only apt sources)"
  cat > "${dest}" <<EOF
# Added by pc2drc-ng so a fresh Debian ISO install can reach the network archives.
deb http://deb.debian.org/debian ${OS_CODENAME} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${OS_CODENAME}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${OS_CODENAME}-security main contrib non-free non-free-firmware
EOF
}

pc2drc_prepare_apt() {
  pc2drc_log "Preparing apt sources for a fresh install..."
  pc2drc_ensure_dns archive.ubuntu.com || pc2drc_ensure_dns security.ubuntu.com || true
  pc2drc_disable_cdrom_sources

  case "${OS_ID}" in
    ubuntu)
      if ! pc2drc_sources_have_http; then
        pc2drc_write_ubuntu_sources_dropin
      fi
      ;;
    debian)
      pc2drc_enable_debian_components
      ;;
  esac

  pc2drc_log "Updating apt..."
  if ! pc2drc_apt_update; then
    pc2drc_die "apt-get update failed. Check network and /etc/apt/sources.list."
  fi

  # software-properties-common is in Ubuntu main, so this works before universe.
  "${APT_GET[@]}" install -y --no-install-recommends ca-certificates gnupg curl wget || true
  if [[ "${OS_ID}" == "ubuntu" ]] && ! command -v add-apt-repository >/dev/null 2>&1; then
    "${APT_GET[@]}" install -y --no-install-recommends software-properties-common || true
  fi

  if [[ "${OS_ID}" == "ubuntu" ]]; then
    pc2drc_enable_ubuntu_universe
    pc2drc_log "Updating apt after enabling universe..."
    if ! pc2drc_apt_update; then
      pc2drc_die "apt-get update failed after enabling universe."
    fi
    if ! pc2drc_pkg_available ffmpeg; then
      pc2drc_log "ffmpeg still not visible; forcing a full Ubuntu archive drop-in"
      pc2drc_write_ubuntu_sources_dropin
      pc2drc_apt_update || pc2drc_die "apt-get update failed after writing Ubuntu archive drop-in."
    fi
    if ! pc2drc_pkg_available ffmpeg; then
      pc2drc_die "universe packages (ffmpeg, openbox, TigerVNC) are still invisible. On Ubuntu ${OS_VERSION_ID} enable universe by hand or use 22.04/24.04."
    fi
  fi
}

pc2drc_prepare_apt

# Repair half-configured packages from a previous failed run.
apt-get -y -f install >/dev/null 2>&1 || true

pc2drc_log "Installing packages..."

# Toolchain and libs that live in main on Ubuntu.
pc2drc_apt_install_available \
  build-essential g++ gcc make git wget curl ca-certificates pkg-config \
  python3 \
  cmake autoconf automake libtool gettext \
  bison flex \
  zlib1g-dev libssl-dev libncurses-dev \
  libnl-3-dev libnl-genl-3-dev \
  libgl1-mesa-dev libglu1-mesa-dev \
  libjpeg-dev libpng-dev libx11-dev libxext-dev libxrandr-dev libxrender-dev \
  libudev-dev \
  iw iproute2 iputils-ping rfkill wireless-regdb \
  net-tools procps psmisc \
  x11-xserver-utils xauth \
  || pc2drc_die "Failed to install base build packages (gcc/make/git)."

# These are universe on Ubuntu, main on Debian. Fresh 20.04 ISOs leave universe off.
pc2drc_apt_install_available \
  python3-pexpect \
  yasm nasm \
  libswscale-dev libavutil-dev libavcodec-dev ffmpeg \
  libglew-dev \
  libsdl2-dev \
  libvncserver-dev \
  tigervnc-standalone-server tigervnc-common \
  openbox xterm \
  || pc2drc_die "Failed to install ffmpeg/openbox/TigerVNC/yasm. Universe is probably still disabled."

# Name changes across Ubuntu/Debian releases — install whatever exists.
pc2drc_apt_install_available libsdl1.2-dev libsdl1.2-compat-dev || true
pc2drc_apt_install_available freeglut3-dev libglut-dev mesa-utils || true
pc2drc_apt_install_available tigervnc-viewer xtightvncviewer tigervnc-xorg-extension || true
pc2drc_apt_install_available twm fluxbox dbus-x11 || true
pc2drc_apt_install_available network-manager || true

# Do not install linux-headers-generic / dkms. This rewrite never patches the
# kernel, and on 20.04 HWE (5.15) linux-headers-generic pulls the unused 5.4
# tree from security.ubuntu.com.

# The GamePad-patched x264 in ./prefix must win over the distro libx264.
apt-get remove -y libx264-dev >/dev/null 2>&1 || true

pc2drc_require_cmds gcc make git python3 pkg-config cmake
if ! python3 -c 'import pexpect' >/dev/null 2>&1; then
  pc2drc_die "python3-pexpect is required for pairing. Enable universe and re-run."
fi
if ! command -v yasm >/dev/null 2>&1 && ! command -v nasm >/dev/null 2>&1; then
  pc2drc_die "Need yasm or nasm to build x264. Enable the universe repo and re-run."
fi
if ! command -v tigervncserver >/dev/null 2>&1 && ! command -v vncserver >/dev/null 2>&1; then
  pc2drc_die "TigerVNC is required (package tigervnc-standalone-server). Enable universe and re-run."
fi
if ! command -v openbox >/dev/null 2>&1 && ! command -v twm >/dev/null 2>&1; then
  pc2drc_die "Need a nested window manager (openbox). Enable universe and re-run."
fi
if ! command -v xterm >/dev/null 2>&1; then
  pc2drc_die "xterm is required for the GamePad desktop. Enable universe and re-run."
fi

pc2drc_log "apt packages installed."
