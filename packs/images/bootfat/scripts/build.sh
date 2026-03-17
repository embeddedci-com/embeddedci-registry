#!/usr/bin/env bash
# Create bootable FAT32 *filesystem image* (no partition table) containing:
# - U-Boot files (optional): MLO, u-boot.img (BBB)
# - Kernel: Image or zImage
# - DTBs (optional)
# - extlinux.conf
#
# Required env:
#   BUILD_ROOT
#   KERNEL_IMAGE              path to kernel image (Image or zImage)
#
# Optional env:
#   INITRD                    path to initramfs.cpio.gz (required if BOARD_BOOT_MODE=initramfs)
#   UBOOT_MLO                 path to MLO (BBB)
#   UBOOT_IMG                 path to u-boot.img (BBB)
#   BOARD_DTBS                comma-separated list of dtb filenames to copy
#
# Board env (recommended):
#   BOARD_BOOT_MODE           initramfs|disk  (default: initramfs)
#   BOARD_ARCH                arm64|arm       (optional, used for defaults)
#   BOARD_CONSOLE             e.g. ttyAMA0,115200n8 or ttyO0,115200n8
#   BOARD_ROOTFS_DEVICE       e.g. /dev/vdb or /dev/mmcblk0p2
#   BOARD_ROOTFS_TYPE         e.g. ext4
#   BOARD_KERNEL_FILENAME     override filename on FAT (default: Image for arm64, zImage for arm)
#
# Pack vars (optional):
#   BOOTFAT_SIZE_MB           FAT filesystem size in MiB (default: 128)
#   BOOTFAT_IMG_NAME          output filename (default: bootfat.img)
#   BOOTFAT_LABEL             FAT label (default: BOOT)
#
# Artifact:
#   ${BUILD_ROOT}/bootfat.img (or $BOOTFAT_IMG_NAME)

set -euo pipefail

: "${BUILD_ROOT:?BUILD_ROOT required}"

BOOT_MODE="${BOARD_BOOT_MODE:-initramfs}"
ARCH_HINT="${BOARD_ARCH:-}"
CONSOLE="${BOARD_CONSOLE:-ttyAMA0,115200n8}"
ROOTFS_DEVICE="${BOARD_ROOTFS_DEVICE:-/dev/vdb}"
ROOTFS_TYPE="${BOARD_ROOTFS_TYPE:-ext4}"
KERNEL_IMAGE="kernel"

# Decide what to name kernel on FAT
KERNEL_FILENAME="${BOARD_KERNEL_FILENAME:-}"
if [[ -z "${KERNEL_FILENAME}" ]]; then
  if [[ "${ARCH_HINT}" == "arm" ]]; then
    KERNEL_FILENAME="zImage"
  else
    KERNEL_FILENAME="Image"
  fi
fi

# Validate initrd presence if needed
if [[ "${BOOT_MODE}" == "initramfs" ]]; then
  : "${INITRD:?INITRD required when BOARD_BOOT_MODE=initramfs}"
fi

cd "${BUILD_ROOT}"

SIZE_MB="${BOOTFAT_SIZE_MB:-128}"
IMG="${BOOTFAT_IMG_NAME:-bootfat.img}"
LABEL="${BOOTFAT_LABEL:-BOOT}"

rm -f "${IMG}"

# Create empty file of desired size
dd if=/dev/zero of="${IMG}" bs=1M count="${SIZE_MB}"

# Format as FAT32 filesystem directly (NO partition table)
# Prefer mkfs.vfat if available; fallback to mtools mformat.
if command -v mkfs.vfat >/dev/null 2>&1; then
  mkfs.vfat -F 32 -n "${LABEL}" "${IMG}"
else
  # mformat formats directly too
  mformat -i "${IMG}" -F -v "${LABEL}" ::
fi

# Optional: copy BBB U-Boot bootloader files
if [[ -n "${UBOOT_MLO:-}" ]]; then
  mcopy -i "${IMG}" -v "${UBOOT_MLO}" ::/MLO
fi
if [[ -n "${UBOOT_IMG:-}" ]]; then
  mcopy -i "${IMG}" -v "${UBOOT_IMG}" ::/u-boot.img
fi

# Copy kernel
mcopy -i "${IMG}" -v "${KERNEL_IMAGE}" "::/${KERNEL_FILENAME}"

# Optional: copy DTBs
if [[ -n "${BOARD_DTBS:-}" ]]; then
  DTB_DIR="./kernel/dtbs"

  # Split comma-separated list, trim whitespace, and process.
  # Avoid bash process substitution (</dev/fd/...) for environments without /dev/fd.
  echo "${BOARD_DTBS}" | tr ',' '\n' | while IFS= read -r dtb; do
    dtb="$(echo "${dtb}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "${dtb}" ]] || continue

    src="${DTB_DIR}/${dtb}"
    if [[ ! -f "${src}" ]]; then
      echo "ERROR: DTB listed in BOARD_DTBS not found: ${src}"
      echo "       BOARD_DTBS=${BOARD_DTBS}"
      exit 1
    fi

    # Copy into FAT root with same filename
    mcopy -i "${IMG}" -v "${src}" "::/${dtb}"
  done
fi

# Build extlinux.conf
mkdir -p boot/extlinux

FDT_LINE=""

if [[ -n "${BOARD_DTBS:-}" ]]; then
  # Use first DTB from comma-separated list
  FIRST_DTB="$(echo "${BOARD_DTBS}" | cut -d',' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  if [[ -z "${FIRST_DTB}" ]]; then
    echo "ERROR: BOARD_DTBS is set but empty after parsing"
    exit 1
  fi

  # Verify the DTB exists in FAT image
  if ! mdir -i "${IMG}" "::/${FIRST_DTB}" >/dev/null 2>&1; then
    echo "ERROR: DTB '${FIRST_DTB}' not found in FAT image"
    echo "       Ensure it was copied before generating extlinux.conf"
    exit 1
  fi

  FDT_LINE="  FDT /${FIRST_DTB}"
fi

if [[ "${BOOT_MODE}" == "disk" ]]; then
  APPEND_LINE="  APPEND console=${CONSOLE} root=${ROOTFS_DEVICE} rootfstype=${ROOTFS_TYPE} rw rootwait"

  cat > boot/extlinux/extlinux.conf <<EOF
TIMEOUT 1
DEFAULT linux

LABEL linux
  KERNEL /${KERNEL_FILENAME}
${FDT_LINE}
${APPEND_LINE}
EOF

else
  APPEND_LINE="  APPEND console=${CONSOLE} rdinit=/init"

  cat > boot/extlinux/extlinux.conf <<EOF
TIMEOUT 1
DEFAULT linux

LABEL linux
  KERNEL /${KERNEL_FILENAME}
  INITRD /initramfs.cpio.gz
${FDT_LINE}
${APPEND_LINE}
EOF

  mcopy -i "${IMG}" -v "${INITRD}" ::/initramfs.cpio.gz
fi

mmd   -i "${IMG}" ::/boot || true
mmd   -i "${IMG}" ::/boot/extlinux || true
mcopy -i "${IMG}" -v boot/extlinux/extlinux.conf ::/boot/extlinux/extlinux.conf

echo "=== FAT filesystem root ==="
mdir -i "${IMG}" ::/
echo "=== /boot/extlinux ==="
mdir -i "${IMG}" ::/boot/extlinux