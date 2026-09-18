#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

pc2drc_need_linux
pc2drc_need_root

export DEBIAN_FRONTEND=noninteractive

if ! command -v apt-get >/dev/null 2>&1; then
  pc2drc_die "This installer expects apt (Ubuntu/Debian)."
fi

pc2drc_log "Updating apt..."
apt-get update -y

pc2drc_log "Installing packages..."
apt-get install -y --no-install-recommends \
  build-essential git wget curl ca-certificates pkg-config \
  python3 python3-pexpect python3-minimal \
  cmake autoconf automake libtool \
  yasm nasm \
  zlib1g-dev libssl-dev \
  libnl-3-dev libnl-genl-3-dev \
  libswscale-dev libavutil-dev ffmpeg \
  libgl1-mesa-dev libglu1-mesa-dev libglew-dev \
  libsdl1.2-dev libsdl2-dev \
  tigervnc-standalone-server tigervnc-common \
  openbox xterm x11-xserver-utils \
  iw iproute2 iputils-ping \
  dkms linux-headers-generic \
  net-tools procps psmisc \
  pkg-config

# Viewer is optional; Ubuntu package names differ.
apt-get install -y tigervnc-viewer 2>/dev/null || apt-get install -y xtightvncviewer 2>/dev/null || true

# Ubuntu 20.04 sometimes needs this extra VNC helper.
apt-get install -y tigervnc-xorg-extension 2>/dev/null || true

pc2drc_log "apt packages installed."
