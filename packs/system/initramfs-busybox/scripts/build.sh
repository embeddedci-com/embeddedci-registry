#!/usr/bin/env bash
# Build busybox for initramfs.
# Env: BUSYBOX_SRC, BUILD_ROOT, ARCH, CROSS_COMPILE, [CONFIG_FILE]
# BOARD_BOOT_MODE: if set and not "initramfs", skip (e.g. board boots from disk).
# BUSYBOX_SRC: path to busybox source (e.g. /cache/busybox-1_37_0)
# BUILD_ROOT: output root (e.g. /build)
# ARCH: target arch (e.g. arm64)
# CROSS_COMPILE: toolchain prefix (e.g. aarch64-linux-gnu-)
# CONFIG_FILE: optional path to defconfig; if unset, use make defconfig + CONFIG_STATIC=y
# Artifact: ${BUILD_ROOT}/initramfs.cpio.gz

set -e

if [[ "${BOARD_BOOT_MODE:-}" != "initramfs" ]]; then
  echo "Skipping initramfs (BOARD_BOOT_MODE=${BOARD_BOOT_MODE:-<unset>} is not initramfs)"
  exit 0
fi

: "${BUSYBOX_SRC:?BUSYBOX_SRC required}"
: "${BUILD_ROOT:?BUILD_ROOT required}"
: "${ARCH:?ARCH required}"
: "${CROSS_COMPILE:?CROSS_COMPILE required}"

CONFIG_PREFIX="${BUILD_ROOT}/rootfs"
LOCK_FILE="${BUSYBOX_SRC}.build.lock"

# Acquire lock before build
exec 9>"${LOCK_FILE}"
flock 9 || { echo "Failed to acquire lock on ${LOCK_FILE}"; exit 1; }

cd "${BUSYBOX_SRC}"
make distclean

if [[ -n "${CONFIG_FILE}" && -f "${CONFIG_FILE}" ]]; then
  cp "${CONFIG_FILE}" .config
else
  make defconfig
  # disable TC
  sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config || true
  # Enable CONFIG_STATIC for static binary
  sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config || \
    sed -i 's/^CONFIG_STATIC=.*/CONFIG_STATIC=y/' .config || true
  grep -q 'CONFIG_STATIC=y' .config || echo 'CONFIG_STATIC=y' >> .config
fi

export ARCH
export CROSS_COMPILE
make -j"$(nproc)"
make CONFIG_PREFIX="${CONFIG_PREFIX}" install

# Create init script for initramfs
# When HAVE_ROOTFS_EXT4=1 (board has app/rootfs-image), init mounts /dev/vdb and switch_roots to /sbin/init.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${HAVE_ROOTFS_EXT4:-}" ]]; then
  cp "${SCRIPT_DIR}/init-rootfs-ext4.sh" "${CONFIG_PREFIX}/init"
else
  cp "${SCRIPT_DIR}/init-standalone.sh" "${CONFIG_PREFIX}/init"
fi

chmod +x "${CONFIG_PREFIX}/init"

# Build initramfs.cpio.gz (artifact)
cd "${CONFIG_PREFIX}"
find . -print0 | cpio --null -ov --format=newc | gzip -9 > "${BUILD_ROOT}/initramfs.cpio.gz"

exec 9>&-
