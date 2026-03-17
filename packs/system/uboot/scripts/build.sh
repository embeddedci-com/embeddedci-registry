#!/usr/bin/env bash
# Build U-Boot (BOARD_* driven).
#
# Required env:
#   UBOOT_SRC, BUILD_ROOT, BOARD_ARCH, BOARD_UBOOT_DEFCONFIG
#
# Optional env:
#   BOARD_CROSS_COMPILE
#   BOARD_UBOOT_ENABLE_DISTRO_BOOT   (default: 1)
#   BOARD_UBOOT_ENABLE_BOOTSTD       (default: 0)
#
# Artifacts staged under:
#   ${BUILD_ROOT}/uboot/...

set -euo pipefail

: "${UBOOT_SRC:?UBOOT_SRC required}"
: "${BUILD_ROOT:?BUILD_ROOT required}"
: "${BOARD_ARCH:?BOARD_ARCH required}"
: "${BOARD_UBOOT_DEFCONFIG:?BOARD_UBOOT_DEFCONFIG required}"

ARCH="${BOARD_ARCH}"

# Derive CROSS_COMPILE if not provided
if [[ -z "${BOARD_CROSS_COMPILE:-}" ]]; then
  case "${BOARD_ARCH}" in
    arm)   BOARD_CROSS_COMPILE="arm-linux-gnueabihf-" ;;
    arm64) BOARD_CROSS_COMPILE="aarch64-linux-gnu-" ;; # or your musl prefix if that’s what you use
    *) echo "ERROR: Unsupported BOARD_ARCH=${BOARD_ARCH}" >&2; exit 1 ;;
  esac
fi
CROSS_COMPILE="${BOARD_CROSS_COMPILE}"

ENABLE_DISTRO="${BOARD_UBOOT_ENABLE_DISTRO_BOOT:-1}"
ENABLE_BOOTSTD="${BOARD_UBOOT_ENABLE_BOOTSTD:-0}"

echo "U-Boot build:"
echo "  ARCH=${ARCH}"
echo "  CROSS_COMPILE=${CROSS_COMPILE}"
echo "  DEFCONFIG=${BOARD_UBOOT_DEFCONFIG}"
echo "  DISTRO_DEFAULTS=${ENABLE_DISTRO}"
echo "  BOOTSTD=${ENABLE_BOOTSTD}"

cd "${UBOOT_SRC}"
# U-Boot Makefile's clean tries 'rm SPL'; if SPL is a directory (e.g. from a previous build in cached source), that fails. Remove it first.
rm -rf SPL spl
make distclean

# Always pass vars explicitly to avoid env leakage
MAKEVARS=( "ARCH=${ARCH}" "CROSS_COMPILE=${CROSS_COMPILE}" )

make "${MAKEVARS[@]}" "${BOARD_UBOOT_DEFCONFIG}"

# Optional: enable distro boot + extlinux/script
if [[ "${ENABLE_DISTRO}" == "true" ]]; then
  ./scripts/config --enable CONFIG_DISTRO_DEFAULTS || true
  # extlinux + scripts is the main win
  ./scripts/config --enable CONFIG_BOOTMETH_EXTLINUX || true
  ./scripts/config --enable CONFIG_BOOTMETH_SCRIPT || true
fi

# Optional: bootstd/bootflow (nice, but not required)
if [[ "${ENABLE_BOOTSTD}" == "true" ]]; then
  ./scripts/config --enable CONFIG_CMD_BOOTFLOW || true
  ./scripts/config --enable CONFIG_BOOTSTD || true
  ./scripts/config --enable CONFIG_BOOTSTD_DEFAULTS || true
fi

make "${MAKEVARS[@]}" olddefconfig
make -j"$(nproc)" "${MAKEVARS[@]}"

# Stage outputs
OUTDIR="${BUILD_ROOT}/uboot"
mkdir -p "${OUTDIR}"

# Common outputs
if [[ -f "u-boot.bin" ]]; then cp "u-boot.bin" "${OUTDIR}/u-boot.bin"; fi
if [[ -f "u-boot.img" ]]; then cp "u-boot.img" "${OUTDIR}/u-boot.img"; fi
if [[ -f "u-boot" ]]; then cp "u-boot" "${OUTDIR}/u-boot.elf" || true; fi

# SPL outputs for AM335x/Bone (often named MLO in top dir)
# U-Boot build usually produces:
#  - spl/u-boot-spl.bin
#  - MLO (a copy/processed form), depending on config/tools
if [[ -f "MLO" ]]; then
  cp "MLO" "${OUTDIR}/MLO"
elif [[ -f "spl/u-boot-spl.bin" ]]; then
  # Some setups do not create MLO; provide SPL as fallback
  cp "spl/u-boot-spl.bin" "${OUTDIR}/u-boot-spl.bin"
fi

echo "U-Boot artifacts staged under: ${OUTDIR}"
ls -la "${OUTDIR}"