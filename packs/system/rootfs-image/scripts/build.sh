#!/usr/bin/env bash
# Build rootfs.ext4 using BusyBox + optional app artifact.
#
# Required env:
#   BUILD_ROOT (not strictly used, but kept for consistency)
#   BUSYBOX_SRC  (path to busybox source)
#
# Board env (provided by target -> prefixed + uppercased):
#   BOARD_CC                e.g. aarch64-linux-musl-gcc | arm-linux-musleabihf-gcc
#   BOARD_BUSYBOX_STATIC    "true"/"false"/"1"/"0" (defaults to true if unset)
#
# Pack vars env (from yaml vars):
#   BUSYBOX_REF, SIZE_MB, HOSTNAME, CONSOLE_LOGIN, APP_BIN, APP_DST (install path in rootfs), LABEL, IMG, ROOTDIR
#   ROOTFS_USER, ROOTFS_PASSWORD (non-root user; empty = no non-root user, only root)
#   ROOTFS_ROOT_PASSWORD (root password; empty = root account locked)
#
# Output artifact:
#   rootfs.ext4 (or $IMG)

set -euo pipefail

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing '$1'"; exit 1; }; }

safe_chown() {
  local owner="$1"
  shift

  if chown "$owner" "$@" 2>/dev/null; then
    return 0
  fi

  # Non-root builds (without fakeroot) cannot set ownership. Continue so image
  # creation still works in restricted environments.
  if [[ "$(id -u)" -ne 0 && -z "${FAKEROOTKEY:-}" ]]; then
    echo "WARNING: unable to chown ${owner} on: $* (non-root build; continuing)"
    return 0
  fi

  echo "ERROR: chown ${owner} failed for: $*"
  return 1
}

truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y|on|ON|enabled|ENABLED) return 0 ;;
    *) return 1 ;;
  esac
}

# ===== Config =====
: "${BUSYBOX_SRC:?BUSYBOX_SRC required}"

ROOTDIR="${ROOTDIR:-_rootfs}"
IMG="${IMG:-rootfs.ext4}"
SIZE_MB="${SIZE_MB:-256}"
LABEL="${LABEL:-rootfs}"

HOSTNAME="${HOSTNAME:-embedded-ci}"
CONSOLE_LOGIN="${CONSOLE_LOGIN:-disabled}"

APP_BIN="${APP_BIN:-}"
# APP_DST = where to install the app binary inside the rootfs (e.g. /usr/bin/selftest)
APP_DST="${APP_DST:-/usr/bin/selftest}"

BOARD_CC="${BOARD_CC:-}"
if [[ -z "${BOARD_CC}" ]]; then
  echo "BOARD_CC not set (expected e.g. aarch64-linux-musl-gcc or arm-linux-musleabihf-gcc)"
  exit 1
fi

# Default to static unless explicitly false
BOARD_BUSYBOX_STATIC_RAW="${BOARD_BUSYBOX_STATIC:-true}"
if truthy "${BOARD_BUSYBOX_STATIC_RAW}"; then
  BUSYBOX_STATIC=1
else
  BUSYBOX_STATIC=0
fi

echo "[*] Checking tools..."
need make
need mkfs.ext4
need sed
need truncate
need "${BOARD_CC}"

# Determine target triple + sysroot from compiler
TARGET_TRIPLE="$("${BOARD_CC}" -dumpmachine)"
SYSROOT="$("${BOARD_CC}" -print-sysroot 2>/dev/null || true)"

# Use target strip so host strip isn't used on the cross-built binary (avoids "Unable to recognise the format")
BOARD_STRIP="${BOARD_CC%gcc}strip"
if ! command -v "${BOARD_STRIP}" >/dev/null 2>&1; then
  BOARD_STRIP="${BOARD_CC%-gcc}-strip"
fi
need "${BOARD_STRIP}"

# Non-root builds (e.g. builduser) need fakeroot for rootfs ownership metadata.
if [[ "$(id -u)" -ne 0 && -z "${FAKEROOTKEY:-}" ]]; then
  need fakeroot
  echo "[*] Re-executing under fakeroot for rootfs ownership metadata..."
  exec fakeroot -- "$0" "$@"
fi

echo "[*] Board toolchain:"
echo "    BOARD_CC=${BOARD_CC}"
echo "    BOARD_STRIP=${BOARD_STRIP}"
echo "    TARGET_TRIPLE=${TARGET_TRIPLE}"
echo "    SYSROOT=${SYSROOT:-<none>}"
echo "    BusyBox static=${BUSYBOX_STATIC}"

echo "[*] Cleaning staging..."
rm -rf "${ROOTDIR}"
mkdir -p "${ROOTDIR}"

if [[ ! -d "${BUSYBOX_SRC}" ]]; then
  echo "BUSYBOX_SRC missing: ${BUSYBOX_SRC}"
  exit 1
fi

echo "[*] Building BusyBox (ref=${BUSYBOX_REF:-<unknown>})..."
pushd "${BUSYBOX_SRC}" >/dev/null
make distclean
make defconfig

# disable TC
sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config || true

if [[ "${BUSYBOX_STATIC}" == "1" ]]; then
  # ensure CONFIG_STATIC=y
  sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config || true
  sed -i 's/^CONFIG_STATIC=.*/CONFIG_STATIC=y/' .config || true
  grep -q '^CONFIG_STATIC=y' .config || echo 'CONFIG_STATIC=y' >> .config
else
  # ensure not forced static
  sed -i 's/^CONFIG_STATIC=y/# CONFIG_STATIC is not set/' .config || true
fi

make -j"$(nproc)" CC="${BOARD_CC}" STRIP="${BOARD_STRIP}"
make CC="${BOARD_CC}" STRIP="${BOARD_STRIP}" CONFIG_PREFIX="${ROOTDIR}" install
popd >/dev/null

echo "[*] Creating minimal filesystem layout..."
mkdir -p "${ROOTDIR}"/{proc,sys,dev,etc,root,tmp,var,run,mnt,usr/bin,usr/sbin,etc/init.d,lib}
chmod 1777 "${ROOTDIR}/tmp" || true

# /etc/inittab
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${CONSOLE_LOGIN}" == "enabled" ]]; then
  cp "${SCRIPT_DIR}/inittab.debug" "${ROOTDIR}/etc/inittab"
else
  cp "${SCRIPT_DIR}/inittab.login" "${ROOTDIR}/etc/inittab"
fi

# Basic boot script
cat > "${ROOTDIR}/etc/init.d/rcS" <<'EOF'
#!/bin/sh
set -eu

if [ -f /etc/hostname ]; then
    HOSTNAME="$(cat /etc/hostname)"
    hostname "$HOSTNAME"
else
    hostname firmware-ci
fi

mountpoint -q /proc || mount -t proc proc /proc
mountpoint -q /sys  || mount -t sysfs sysfs /sys
mountpoint -q /dev  || mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

echo "=== rcS: booting userspace ==="
uname -a || true

for script in /etc/init.d/S* ; do
    [ -x "$script" ] && "$script"
done

echo "=== rcS: done ==="
EOF
chmod +x "${ROOTDIR}/etc/init.d/rcS"

# Non-root user (configurable via ROOTFS_USER / ROOTFS_PASSWORD); empty = only root
ROOTFS_USER="${ROOTFS_USER:-}"
ROOTFS_PASSWORD="${ROOTFS_PASSWORD:-}"
if [[ -n "${ROOTFS_USER}" ]]; then
  ROOTFS_USER_HASH="$(openssl passwd -6 "${ROOTFS_PASSWORD:-}")"
fi

# Root password (ROOTFS_ROOT_PASSWORD from definitions.yaml); empty = root locked
ROOTFS_ROOT_PASSWORD="${ROOTFS_ROOT_PASSWORD:-}"
if [[ -n "${ROOTFS_ROOT_PASSWORD}" ]]; then
  ROOT_HASH="$(openssl passwd -6 "${ROOTFS_ROOT_PASSWORD}")"
else
  ROOT_HASH="*"
fi

mkdir -p "${ROOTDIR}/root"
if [[ -n "${ROOTFS_USER}" ]]; then
  mkdir -p "${ROOTDIR}/home/${ROOTFS_USER}"
fi

# Minimal passwd/group
if [[ -n "${ROOTFS_USER}" ]]; then
  cat > "${ROOTDIR}/etc/passwd" <<EOF
root:x:0:0:root:/root:/bin/sh
${ROOTFS_USER}:x:1000:1000:${ROOTFS_USER}:/home/${ROOTFS_USER}:/bin/sh
EOF
  cat > "${ROOTDIR}/etc/group" <<EOF
root:x:0:
${ROOTFS_USER}:x:1000:
EOF
  cat > "${ROOTDIR}/etc/shadow" <<EOF
root:${ROOT_HASH}:19000:0:99999:7:::
${ROOTFS_USER}:${ROOTFS_USER_HASH}:19000:0:99999:7:::
EOF
  cat > "${ROOTDIR}/etc/gshadow" <<EOF
root::::
${ROOTFS_USER}::::
EOF
else
  cat > "${ROOTDIR}/etc/passwd" <<EOF
root:x:0:0:root:/root:/bin/sh
EOF
  cat > "${ROOTDIR}/etc/group" <<EOF
root:x:0:
EOF
  cat > "${ROOTDIR}/etc/shadow" <<EOF
root:${ROOT_HASH}:19000:0:99999:7:::
EOF
  cat > "${ROOTDIR}/etc/gshadow" <<EOF
root::::
EOF
fi

# Ownership
safe_chown 0:0 "${ROOTDIR}/root"
if [[ -n "${ROOTFS_USER}" ]]; then
  safe_chown 1000:1000 "${ROOTDIR}/home/${ROOTFS_USER}"
fi
safe_chown 0:0 \
  "${ROOTDIR}/etc/passwd" \
  "${ROOTDIR}/etc/group" \
  "${ROOTDIR}/etc/shadow" \
  "${ROOTDIR}/etc/gshadow"

# Permissions
chmod 755 "${ROOTDIR}/root"
if [[ -n "${ROOTFS_USER}" ]]; then
  chmod 755 "${ROOTDIR}/home/${ROOTFS_USER}"
fi
chmod 644 "${ROOTDIR}/etc/passwd" "${ROOTDIR}/etc/group"
chmod 640 "${ROOTDIR}/etc/shadow" "${ROOTDIR}/etc/gshadow"

# If dynamic BusyBox is requested, stage musl runtime for the correct arch.
# NOTE: In musl toolchains, ld-musl-*.so.1 may be a dangling symlink on the build host (often -> /lib/libc.so).
# For the rootfs we stage libc.so and create the loader symlink ourselves (deterministic and correct).
if [[ "${BUSYBOX_STATIC}" == "0" ]]; then
  echo "[*] Staging musl runtime (dynamic BusyBox)..."

  TOOLCHAIN_LIBDIR="/opt/toolchains/${TARGET_TRIPLE}/${TARGET_TRIPLE}/lib"
  if [[ ! -d "${TOOLCHAIN_LIBDIR}" ]]; then
    echo "ERROR: Expected toolchain libdir not found: ${TOOLCHAIN_LIBDIR}"
    echo "       For dynamic linking, this script expects musl-cross-make layout under /opt/toolchains."
    exit 1
  fi

  if [[ ! -f "${TOOLCHAIN_LIBDIR}/libc.so" ]]; then
    echo "ERROR: libc.so not found in ${TOOLCHAIN_LIBDIR}"
    exit 1
  fi

  cp -a "${TOOLCHAIN_LIBDIR}/libc.so" "${ROOTDIR}/lib/"

  case "${TARGET_TRIPLE}" in
    aarch64-linux-musl*)
      LOADER_NAME="ld-musl-aarch64.so.1"
      ;;
    arm-linux-musleabihf*)
      LOADER_NAME="ld-musl-armhf.so.1"
      ;;
    *)
      echo "ERROR: Unknown musl loader mapping for target: ${TARGET_TRIPLE}"
      echo "       Add mapping here or set busybox_static=true."
      exit 1
      ;;
  esac

  # Create loader symlink in rootfs (relative symlink is ideal)
  ln -sf "libc.so" "${ROOTDIR}/lib/${LOADER_NAME}"

  # Optional sanity check: BusyBox should be dynamically linked if we asked for it
  if command -v readelf >/dev/null 2>&1; then
    if readelf -d "${ROOTDIR}/bin/busybox" 2>/dev/null | grep -q 'NEEDED'; then
      echo "[*] BusyBox dynamic deps detected (ok)"
    else
      echo "WARNING: BusyBox appears not dynamically linked (no NEEDED entries)."
      echo "         This may be fine if it ended up static anyway."
    fi
  fi
fi

# Add app binary
if [[ -n "${APP_BIN}" && -f "${APP_BIN}" ]]; then
  echo "[*] Adding app binary into rootfs: ${APP_BIN} -> ${APP_DST}"
  DST="${ROOTDIR}/${APP_DST#/}"
  mkdir -p "$(dirname "${DST}")"
  cp -v "${APP_BIN}" "${DST}"
  chmod 755 "${DST}"
fi

# Hostname
echo "${HOSTNAME}" > "${ROOTDIR}/etc/hostname"

echo "[*] Creating ext4 image (${SIZE_MB} MiB) and populating WITHOUT mount..."
rm -f "${IMG}"
truncate -s "${SIZE_MB}M" "${IMG}"
mkfs.ext4 -F -L "${LABEL}" -d "${ROOTDIR}" "${IMG}"

echo "[*] Done: ${IMG}"