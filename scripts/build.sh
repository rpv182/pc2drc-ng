#!/usr/bin/env bash
# Fetch archived pc2drc (hostapd/x264/libdrc forks) and build into ./prefix.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

pc2drc_need_linux
pc2drc_need_root
pc2drc_export_build_env

NPROC="$(nproc 2>/dev/null || echo 2)"
JOBS="${PC2DRC_JOBS:-${NPROC}}"

fetch_upstream() {
  if [[ -d "${PC2DRC_VENDOR}/.git" || -d "${PC2DRC_VENDOR}/drc-hostap" ]]; then
    pc2drc_log "upstream already present at ${PC2DRC_VENDOR}"
    return 0
  fi
  pc2drc_need_cmd git
  pc2drc_log "Cloning archived thefloppydriver/pc2drc (hostapd + libdrc + x264 forks)..."
  git clone --depth 1 https://github.com/thefloppydriver/pc2drc.git "${PC2DRC_VENDOR}"
}

download_to() {
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --retry-delay 2 -o "${dest}" "${url}"
  else
    wget -O "${dest}" "${url}"
  fi
}

build_libnl() {
  if [[ -f "${PC2DRC_PREFIX}/lib/libnl.so" || -f "${PC2DRC_PREFIX}/lib/libnl.a" ]]; then
    pc2drc_log "libnl already built"
    return 0
  fi
  local src="${PC2DRC_ROOT}/vendor/libnl-1.1.4"
  mkdir -p "${PC2DRC_ROOT}/vendor"
  if [[ ! -d "${src}" ]]; then
    pc2drc_log "Downloading libnl-1.1.4..."
    download_to "https://www.infradead.org/~tgr/libnl/files/libnl-1.1.4.tar.gz" "${PC2DRC_ROOT}/vendor/libnl-1.1.4.tar.gz" \
      || download_to "https://github.com/thom311/libnl/releases/download/libnl1_1_4/libnl-1.1.4.tar.gz" "${PC2DRC_ROOT}/vendor/libnl-1.1.4.tar.gz"
    tar -C "${PC2DRC_ROOT}/vendor" -xf "${PC2DRC_ROOT}/vendor/libnl-1.1.4.tar.gz"
  fi
  pc2drc_log "Building libnl-1.1.4 into prefix..."
  pushd "${src}" >/dev/null
  CFLAGS="-O2 -fPIC -Wno-error -Wno-implicit-function-declaration" ./configure --prefix="${PC2DRC_PREFIX}"
  make -j"${JOBS}"
  make install
  popd >/dev/null
}

build_openssl() {
  if [[ -f "${PC2DRC_PREFIX}/lib/libssl.a" || -f "${PC2DRC_PREFIX}/lib/libssl.so" ]]; then
    pc2drc_log "OpenSSL already built in prefix"
    return 0
  fi
  local src="${PC2DRC_ROOT}/vendor/openssl-1.0.2u"
  mkdir -p "${PC2DRC_ROOT}/vendor"
  if [[ ! -d "${src}" ]]; then
    pc2drc_log "Downloading OpenSSL 1.0.2u (needed by the Wii U hostapd fork; kept inside ./prefix)..."
    download_to "https://www.openssl.org/source/old/1.0.2/openssl-1.0.2u.tar.gz" "${PC2DRC_ROOT}/vendor/openssl-1.0.2u.tar.gz" \
      || download_to "https://github.com/openssl/openssl/releases/download/OpenSSL_1_0_2u/openssl-1.0.2u.tar.gz" "${PC2DRC_ROOT}/vendor/openssl-1.0.2u.tar.gz"
    tar -C "${PC2DRC_ROOT}/vendor" -xf "${PC2DRC_ROOT}/vendor/openssl-1.0.2u.tar.gz"
  fi
  pc2drc_log "Building OpenSSL 1.0.2u into prefix..."
  pushd "${src}" >/dev/null
  # GCC 9–13: this old tree is not -Werror clean. Isolate it in prefix so the system OpenSSL 3 stays untouched.
  ./config --prefix="${PC2DRC_PREFIX}" --openssldir="${PC2DRC_PREFIX}/ssl" \
    threads zlib no-shared no-ssl3 no-ssl2 linux-x86_64 \
    -Wno-error -Wno-implicit-function-declaration -Wno-implicit-int
  make -j"${JOBS}" depend || true
  make -j"${JOBS}"
  make install_sw
  popd >/dev/null
}

patch_hostapd_config() {
  local config="$1"
  if [[ ! -f "${config}" ]]; then
    return 1
  fi
  if ! grep -q 'pc2drc-ng prefix' "${config}"; then
    {
      echo ""
      echo "# pc2drc-ng prefix"
      echo "CFLAGS += -I${PC2DRC_PREFIX}/include"
      echo "LIBS += -L${PC2DRC_PREFIX}/lib -L${PC2DRC_PREFIX}/lib64 -ldl -lpthread -lz"
      echo "LIBS_p += -L${PC2DRC_PREFIX}/lib -ldl -lpthread"
    } >> "${config}"
  fi
  # Original pc2drc used a sed token that breaks if the folder is not named pc2drc.
  sed -i "s#/_123sedreplaceme#${PC2DRC_PREFIX}#g" "${config}" || true
  sed -i "s#CONFIG_LIBNL20=y#CONFIG_LIBNL20=y\\n#g" "${config}" || true
}

build_hostap() {
  local hostap="${PC2DRC_VENDOR}/drc-hostap"
  [[ -d "${hostap}" ]] || pc2drc_die "drc-hostap missing from upstream clone"
  pc2drc_log "Building netboot..."
  gcc -O2 -o "${hostap}/netboot/netboot" "${hostap}/netboot/netboot.c"

  pc2drc_log "Building hostapd..."
  pushd "${hostap}/hostapd" >/dev/null
  if [[ -f defconfig ]]; then
    cp -f defconfig .config
  elif [[ -f ../conf/hostapd.config ]]; then
    cp -f ../conf/hostapd.config .config
  else
    pc2drc_die "No hostapd .config template found"
  fi
  patch_hostapd_config .config
  make -j"${JOBS}"
  popd >/dev/null

  pc2drc_log "Building wpa_supplicant..."
  pushd "${hostap}/wpa_supplicant" >/dev/null
  if [[ -f defconfig ]]; then
    cp -f defconfig .config
  elif [[ -f ../conf/wpa_supplicant.config ]]; then
    cp -f ../conf/wpa_supplicant.config .config
  else
    pc2drc_die "No wpa_supplicant .config template found"
  fi
  patch_hostapd_config .config
  make -j"${JOBS}" wpa_supplicant wpa_cli
  popd >/dev/null
}

build_x264() {
  local src="${PC2DRC_VENDOR}/drc-x264"
  [[ -d "${src}" ]] || pc2drc_die "drc-x264 missing from upstream clone"
  pc2drc_log "Building drc-x264 into prefix (not /usr/local)..."
  pushd "${src}" >/dev/null
  ./configure --prefix="${PC2DRC_PREFIX}" --enable-static --enable-pic --disable-shared --disable-cli || \
    ./configure --prefix="${PC2DRC_PREFIX}" --enable-static --enable-pic --disable-shared
  make -j"${JOBS}"
  make install
  popd >/dev/null
}

build_libdrc() {
  local src=""
  if [[ -d "${PC2DRC_VENDOR}/libdrc-vnc/libdrc-thefloppydriver" ]]; then
    src="${PC2DRC_VENDOR}/libdrc-vnc/libdrc-thefloppydriver"
  elif [[ -d "${PC2DRC_VENDOR}/libdrc" ]]; then
    src="${PC2DRC_VENDOR}/libdrc"
  else
    pc2drc_die "libdrc sources missing from upstream clone"
  fi
  local tsf
  tsf="$(find "${src}" -name 'tsf-linux.cpp' | head -n1 || true)"
  [[ -n "${tsf}" ]] || pc2drc_die "tsf-linux.cpp not found"
  python3 "${PC2DRC_PATCHES}/patch-libdrc-tsf.py" "${tsf}"

  pc2drc_log "Building libdrc..."
  pushd "${src}" >/dev/null
  if [[ -x ./configure ]]; then
    PKG_CONFIG_PATH="${PC2DRC_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}" \
      ./configure --prefix="${PC2DRC_PREFIX}" --disable-demos --disable-debug || true
  elif [[ -x ./autogen.sh ]]; then
    ./autogen.sh
    PKG_CONFIG_PATH="${PC2DRC_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}" \
      ./configure --prefix="${PC2DRC_PREFIX}" --disable-demos --disable-debug
  fi
  make -j"${JOBS}"
  make install
  popd >/dev/null
}

build_drcvncclient() {
  local src="${PC2DRC_VENDOR}/libdrc-vnc/drcvncclient"
  [[ -d "${src}" ]] || pc2drc_die "drcvncclient missing from upstream clone"
  pc2drc_log "Building drcvncclient..."
  pushd "${src}" >/dev/null
  if [[ -f configure.ac && ! -x configure ]]; then
    autoreconf -f -i
  fi
  export x264_LIBS="-L${PC2DRC_PREFIX}/lib -lx264"
  export LIBS="${LIBS:-} -lpthread -ldl"
  PKG_CONFIG_PATH="${PC2DRC_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}" \
    ./configure --prefix="${PC2DRC_PREFIX}" || ./configure --prefix="${PC2DRC_PREFIX}"
  # Upstream Makefile often forgets -lpthread -ldl (GitHub issue #12 / gudenau).
  if [[ -f src/Makefile ]]; then
    sed -i 's/-lvncclient/-lvncclient -lpthread -ldl/g' src/Makefile || true
  fi
  if [[ -f Makefile ]]; then
    sed -i 's/-lvncclient/-lvncclient -lpthread -ldl/g' Makefile || true
  fi
  make -j"${JOBS}"
  popd >/dev/null
}

mkdir -p "${PC2DRC_PREFIX}"/{bin,lib,include,ssl}
fetch_upstream
build_libnl
build_openssl
build_hostap
build_x264
build_libdrc
build_drcvncclient

pc2drc_log "Build finished. Binaries live under ${PC2DRC_PREFIX} and ${PC2DRC_VENDOR}."
