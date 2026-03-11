#!/usr/bin/env bash
# Generic Linux kernel build pack (BOARD_* driven).
#
# Required env:
#   KERNEL_SRC, BUILD_ROOT, BOARD_ARCH
#
# Optional env:
#   BOARD_CROSS_COMPILE
#   BOARD_DEFCONFIG
#   BOARD_IMAGE_TARGET
#   BOARD_DTBS                 (comma-separated list: am335x-boneblack.dtb,foo.dtb)
#   BOARD_KERNEL_KCONFIG        (comma-separated list of directives, e.g.
#                               enable:CONFIG_EFI,disable:CONFIG_DEBUG_INFO,
#                               set:CONFIG_HZ:int:1000,
#                               set:CONFIG_CMDLINE:string:console=ttyO0,115200n8 root=/dev/mmcblk0p2 rootwait)
#
# Artifacts copied into:
#   ${BUILD_ROOT}/kernel/{Image|zImage}
#   ${BUILD_ROOT}/kernel/dtbs/*.dtb

set -euo pipefail

: "${KERNEL_SRC:?KERNEL_SRC required}"
: "${BOARD_ARCH:?BOARD_ARCH required}"
: "${BOARD_CROSS_COMPILE:?BOARD_CROSS_COMPILE required}"

# Map BOARD_* -> kernel expected env names
export ARCH="${BOARD_ARCH}"
export CROSS_COMPILE="${BOARD_CROSS_COMPILE}"

# Defaults based on ARCH
DEFCONFIG="${BOARD_DEFCONFIG:-defconfig}"

IMAGE_TARGET="${BOARD_IMAGE_TARGET:-}"
if [[ -z "${IMAGE_TARGET}" ]]; then
  case "${ARCH}" in
    arm64) IMAGE_TARGET="Image" ;;
    arm)   IMAGE_TARGET="zImage" ;;
    *) echo "ERROR: Unsupported BOARD_ARCH/ARCH: ${ARCH}" >&2; exit 1 ;;
  esac
fi

# Helpers
split_csv() {
  # prints items one per line
  local s="${1:-}"
  [[ -z "${s}" ]] && return 0
  echo "${s}" | tr ',' '\n' | sed '/^\s*$/d' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

apply_kconfig_directive() {
  local directive="$1"

  # Supported:
  #  enable:CONFIG_FOO
  #  disable:CONFIG_BAR
  #  module:CONFIG_BAZ
  #  set:CONFIG_X:int:123
  #  set:CONFIG_Y:string:abc def
  #
  # Note: for string values that include commas, you should avoid commas in YAML
  #       or escape them before joining; otherwise use fragments.
  local op rest
  op="${directive%%:*}"
  rest="${directive#*:}"

  case "${op}" in
    enable)
      ./scripts/config --enable "${rest}"
      ;;
    disable)
      ./scripts/config --disable "${rest}"
      ;;
    module)
      ./scripts/config --module "${rest}"
      ;;
    set)
      # rest format: CONFIG_NAME:type:value
      local name type value
      name="${rest%%:*}"
      rest="${rest#*:}"
      type="${rest%%:*}"
      value="${rest#*:}"
      case "${type}" in
        int)
          ./scripts/config --set-val "${name}" "${value}"
          ;;
        string)
          # scripts/config will handle quoting; keep as-is
          ./scripts/config --set-str "${name}" "${value}"
          ;;
        *)
          echo "ERROR: Unknown set type in directive: ${directive}" >&2
          exit 1
          ;;
      esac
      ;;
    *)
      echo "ERROR: Unknown kconfig directive: ${directive}" >&2
      exit 1
      ;;
  esac
}

cd "${KERNEL_SRC}"

# Configure baseline
make "${DEFCONFIG}"

# Always sensible defaults (can be overridden by directives)
./scripts/config --enable CONFIG_DEVTMPFS
./scripts/config --enable CONFIG_DEVTMPFS_MOUNT
./scripts/config --enable CONFIG_BLK_DEV_INITRD

# Apply board-specific config directives from YAML
if [[ -n "${BOARD_KERNEL_KCONFIG:-}" ]]; then
  while IFS= read -r d; do
    echo "KCONFIG: ${d}"
    apply_kconfig_directive "${d}"
  done < <(split_csv "${BOARD_KERNEL_KCONFIG}")
fi

make olddefconfig

# Build kernel image
make -j"$(nproc)" "${IMAGE_TARGET}"

# Build DTBs if requested
DTBS_CSV="${BOARD_DTBS:-}"
# Stage under BUILD_ROOT so host has workDir/kernel/ (container /build/kernel/)
: "${BUILD_ROOT:?BUILD_ROOT required}"
OUTDIR="${BUILD_ROOT}/kernel"

if [[ -n "${DTBS_CSV}" ]]; then
  make -j"$(nproc)" dtbs

  # Validate + stage requested dtbs
  mkdir -p "${OUTDIR}/dtbs"

  while IFS= read -r dtb; do
    # DTBs may live in subdirs under arch/${ARCH}/boot/dts
    p="$(find "arch/${ARCH}/boot/dts" -name "${dtb}" -print -quit || true)"
    if [[ -z "${p}" ]]; then
      echo "ERROR: Requested DTB not found after build: ${dtb}" >&2
      exit 1
    fi
    cp "${p}" "${OUTDIR}/dtbs/${dtb}"
  done < <(split_csv "${DTBS_CSV}")
fi

# Stage kernel image artifact in a predictable place
mkdir -p "${OUTDIR}"

case "${ARCH}" in
  arm64)
    cp "arch/arm64/boot/Image" "${OUTDIR}/Image"
    ;;
  arm)
    cp "arch/arm/boot/zImage" "${OUTDIR}/zImage"
    ;;
esac

echo "Kernel artifacts staged under: ${OUTDIR}"