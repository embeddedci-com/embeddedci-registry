#!/usr/bin/env bash
# Build Linux kernel with Buildroot without producing rootfs artifacts.
#
# Required env:
#   BUILD_ROOT, PROJECT_ROOT
#   SOURCE, BUILDROOT_DEFCONFIG   (Buildroot make defconfig target from BR2_EXTERNAL, e.g. arm_defconfig)
#   ARCH, REF
#
# Optional env:
#   BOARD_DEFCONFIG            (Linux kernel defconfig basename for BR2_LINUX_KERNEL_DEFCONFIG; boards/*/definitions.yaml key defconfig)
#   KERNEL_DEFCONFIG           (overrides BOARD_DEFCONFIG)
#   BUILDROOT_CONFIG_DIR
#   BUILDROOT_TREE
#   BUILD_TMPDIR

set -euo pipefail

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing '$1'"; exit 1; }; }

set_kv() {
  local file="$1"
  local key="$2"
  local value="$3"
  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

set_yes() { set_kv "$1" "$2" "y"; }
set_no()  { set_kv "$1" "$2" "n"; }
set_str() { set_kv "$1" "$2" "\"$3\""; }

copy_if_exists() {
  local src="$1"
  local dst="$2"
  if [[ -f "$src" ]]; then
    cp "$src" "$dst"
  fi
}

split_csv() {
  tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d'
}

# Resolve a DTB basename under Buildroot output ($BR_OUT). Prefer $BR_OUT/images (installed
# blobs), then search $BR_OUT/build (linux tree) when linux-dtbs did not copy to images yet.
resolve_dtb_source() {
  local name="$1"
  local found=""
  if [[ -d "$BR_OUT/images" ]]; then
    found="$(find "$BR_OUT/images" -type f -name "$name" 2>/dev/null | head -n 1 || true)"
  fi
  if [[ -z "$found" && -d "$BR_OUT/build" ]]; then
    found="$(find "$BR_OUT/build" -type f -name "$name" 2>/dev/null | head -n 1 || true)"
  fi
  if [[ -n "$found" ]]; then
    printf '%s\n' "$found"
    return 0
  fi
  return 1
}

: "${BUILD_ROOT:?BUILD_ROOT required}"
: "${PROJECT_ROOT:?PROJECT_ROOT required}"
: "${SOURCE:?SOURCE required (path or git URL for BR2_EXTERNAL)}"
: "${BUILDROOT_DEFCONFIG:?BUILDROOT_DEFCONFIG required (Buildroot defconfig target)}"
: "${ARCH:?ARCH required}"
: "${REF:?REF required}"

EFFECTIVE_ARCH="${BOARD_ARCH:-$ARCH}"
KERNEL_DEFCONFIG="${KERNEL_DEFCONFIG:-${BOARD_DEFCONFIG:-defconfig}}"

BUILD_TMPDIR="${BUILD_TMPDIR:-${BUILD_ROOT}/tmp}"
mkdir -p "$BUILD_TMPDIR"
export TMPDIR="$BUILD_TMPDIR"
export TMP="$BUILD_TMPDIR"
export TEMP="$BUILD_TMPDIR"

case "${BUILDROOT_CONFIG_DIR:-}" in
  ""|*"{{"*)
    if [[ -d "$BUILD_ROOT/buildroot_external" ]]; then
      BUILDROOT_CONFIG_DIR="$BUILD_ROOT/buildroot_external"
    else
      BUILDROOT_CONFIG_DIR="$PROJECT_ROOT/$SOURCE"
    fi
    ;;
esac
if [[ ! -d "$BUILDROOT_CONFIG_DIR" ]] && [[ -d "$BUILD_ROOT/buildroot_external" ]]; then
  BUILDROOT_CONFIG_DIR="$BUILD_ROOT/buildroot_external"
fi

case "${BUILDROOT_TREE:-}" in
  ""|*"{{"*) BUILDROOT_TREE="$BUILD_ROOT/buildroot_src" ;;
esac

if [[ ! -d "$BUILDROOT_CONFIG_DIR" ]]; then
  echo "ERROR: BUILDROOT_CONFIG_DIR not a directory: $BUILDROOT_CONFIG_DIR"
  exit 1
fi
if [[ ! -f "$BUILDROOT_TREE/Makefile" ]]; then
  echo "ERROR: Buildroot tree not found at $BUILDROOT_TREE (no Makefile)."
  exit 1
fi

need make

BR_OUT_STAGING="$BUILD_ROOT/buildroot_out"
mkdir -p "$BR_OUT_STAGING"

BR_OUT_USE_TMP="${BR_OUT_USE_TMP:-}"
BR_OUT_USE_MOUNT="${BR_OUT_USE_MOUNT:-}"
if [[ "$BR_OUT_USE_MOUNT" == "1" ]]; then
  BR_OUT="$BR_OUT_STAGING"
elif [[ "$BR_OUT_USE_TMP" == "1" ]] || [[ -f /.dockerenv ]]; then
  BR_OUT="$(mktemp -d /tmp/embeddedci-br-kernel-out.XXXXXX)"
else
  BR_OUT="$BR_OUT_STAGING"
fi

echo "[*] Buildroot kernel-only build"
echo "    BUILDROOT_TREE=$BUILDROOT_TREE"
echo "    BUILDROOT_CONFIG_DIR=$BUILDROOT_CONFIG_DIR"
echo "    BUILDROOT_DEFCONFIG=$BUILDROOT_DEFCONFIG"
echo "    ARCH=$ARCH"
echo "    EFFECTIVE_ARCH=$EFFECTIVE_ARCH"
echo "    KERNEL_DEFCONFIG=$KERNEL_DEFCONFIG"
echo "    REF=$REF"
echo "    O=$BR_OUT"

MAKE_ARGS=(BR2_EXTERNAL="$BUILDROOT_CONFIG_DIR" O="$BR_OUT")
pushd "$BUILDROOT_TREE" >/dev/null
make "${MAKE_ARGS[@]}" "$BUILDROOT_DEFCONFIG"

CONFIG_FILE="$BR_OUT/.config"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Buildroot .config was not generated"
  exit 1
fi

# Kernel-only: disable target rootfs generation and userspace packages.
set_no "$CONFIG_FILE" BR2_INIT_NONE
set_yes "$CONFIG_FILE" BR2_INIT_BUSYBOX
set_no "$CONFIG_FILE" BR2_TARGET_ROOTFS_CPIO
set_no "$CONFIG_FILE" BR2_TARGET_ROOTFS_EXT2
set_no "$CONFIG_FILE" BR2_TARGET_ROOTFS_SQUASHFS
set_no "$CONFIG_FILE" BR2_TARGET_ROOTFS_TAR
set_no "$CONFIG_FILE" BR2_TARGET_ROOTFS_UBIFS
set_no "$CONFIG_FILE" BR2_TARGET_ROOTFS_JFFS2

set_yes "$CONFIG_FILE" BR2_LINUX_KERNEL
set_yes "$CONFIG_FILE" BR2_LINUX_KERNEL_USE_DEFCONFIG
set_str "$CONFIG_FILE" BR2_LINUX_KERNEL_DEFCONFIG "$KERNEL_DEFCONFIG"
set_yes "$CONFIG_FILE" BR2_LINUX_KERNEL_LATEST_VERSION
set_no "$CONFIG_FILE" BR2_LINUX_KERNEL_LATEST_CIP_VERSION
set_no "$CONFIG_FILE" BR2_LINUX_KERNEL_CUSTOM_VERSION
set_str "$CONFIG_FILE" BR2_LINUX_KERNEL_CUSTOM_REPO_URL "https://github.com/torvalds/linux.git"
set_str "$CONFIG_FILE" BR2_LINUX_KERNEL_CUSTOM_REPO_VERSION "$REF"

if [[ "$EFFECTIVE_ARCH" == "arm" ]]; then
  set_yes "$CONFIG_FILE" BR2_arm
  set_no "$CONFIG_FILE" BR2_aarch64
elif [[ "$EFFECTIVE_ARCH" == "arm64" || "$EFFECTIVE_ARCH" == "aarch64" ]]; then
  set_no "$CONFIG_FILE" BR2_arm
  set_yes "$CONFIG_FILE" BR2_aarch64
else
  echo "ERROR: Unsupported arch=$EFFECTIVE_ARCH (expected arm or arm64)"
  exit 1
fi

make "${MAKE_ARGS[@]}" olddefconfig
make "${MAKE_ARGS[@]}" linux-reconfigure
make "${MAKE_ARGS[@]}" linux
# When the board lists DTBs, device-tree blobs must be built; otherwise tolerate missing target.
if [[ -n "${BOARD_DTBS:-}" ]]; then
  make "${MAKE_ARGS[@]}" linux-dtbs
else
  make "${MAKE_ARGS[@]}" linux-dtbs || true
fi
popd >/dev/null

if [[ "$BR_OUT" != "$BR_OUT_STAGING" ]]; then
  mkdir -p "$BR_OUT_STAGING"
  cp -a "$BR_OUT/." "$BR_OUT_STAGING/" 2>/dev/null || true
  rm -rf "$BR_OUT"
  BR_OUT="$BR_OUT_STAGING"
fi

KERNEL_OUT="$BUILD_ROOT/kernel"
mkdir -p "$KERNEL_OUT/dtbs"

if [[ "$EFFECTIVE_ARCH" == "arm" ]]; then
  copy_if_exists "$BR_OUT/images/zImage" "$KERNEL_OUT/zImage"
else
  copy_if_exists "$BR_OUT/images/Image" "$KERNEL_OUT/Image"
fi

if [[ -n "${BOARD_DTBS:-}" ]]; then
  # Board YAML dtbs: → BOARD_DTBS in env (comma-separated basenames). Stage under kernel/dtbs/
  # for the pack artifact path "kernel" so uploads include them. When unset, no DTBs are staged
  # (avoids shipping hundreds of unrelated multi_v7 blobs).
  while IFS= read -r requested_dtb; do
    [[ -z "$requested_dtb" ]] && continue
    if ! src="$(resolve_dtb_source "$requested_dtb")"; then
      echo "ERROR: Requested DTB not found under ${BR_OUT}/images or ${BR_OUT}/build: ${requested_dtb}" >&2
      exit 1
    fi
    cp "$src" "$KERNEL_OUT/dtbs/${requested_dtb}"
  done < <(echo "${BOARD_DTBS}" | split_csv)
  staged_count="$(find "$KERNEL_OUT/dtbs" -mindepth 1 -maxdepth 1 -type f -name '*.dtb' 2>/dev/null | wc -l | tr -d '[:space:]')"
  if [[ -z "${staged_count}" || "${staged_count}" -eq 0 ]]; then
    echo "ERROR: BOARD_DTBS is set (${BOARD_DTBS}) but ${KERNEL_OUT}/dtbs/ contains no .dtb files after staging." >&2
    echo "       Debug: BR_OUT=${BR_OUT}; list images: $(ls -1 "${BR_OUT}/images" 2>/dev/null | head -c 500 || echo '<no images dir>')" >&2
    echo "       Expect each comma-separated basename to be resolved from ${BR_OUT}/images or ${BR_OUT}/build (see resolve_dtb_source in this script)." >&2
    exit 1
  fi
fi

if [[ ! -f "$KERNEL_OUT/Image" && ! -f "$KERNEL_OUT/zImage" ]]; then
  echo "ERROR: No kernel image produced in $KERNEL_OUT"
  exit 1
fi

echo "[*] Kernel artifacts staged under: $KERNEL_OUT"
