#!/usr/bin/env bash
# Run QEMU aarch64 with U-Boot and bootfat image.
# Env: UBOOT_BIN, BOOTFAT_IMG, MACHINE, CPU, MEMORY, [ROOTFS_IMG], [LOG_FILE]
# ROOTFS_IMG: optional rootfs.ext4 from app/rootfs-image pack (adds second block device).
# Output goes to stdout and optionally to LOG_FILE (tee).
# Caller may wrap with `timeout N` for CI boot verification.

set -e

: "${UBOOT_BIN:?UBOOT_BIN required}"
: "${BOOTFAT_IMG:?BOOTFAT_IMG required}"

MACHINE="${MACHINE:-virt}"
CPU="${CPU:-cortex-a53}"
MEMORY="${MEMORY:-1024}"

# Build drive/device args
DRIVE_BOOT="-drive if=none,file=${BOOTFAT_IMG},format=raw,id=boot -device virtio-blk-pci,drive=boot"
ROOTFS_ARGS=""
if [[ -n "${ROOTFS_IMG:-}" && -f "${ROOTFS_IMG}" ]]; then
  ROOTFS_ARGS="-drive if=none,file=${ROOTFS_IMG},format=raw,id=root -device virtio-blk-pci,drive=root"
fi

echo "qemu-system-aarch64 -machine ${MACHINE} -cpu ${CPU} -m ${MEMORY} -nographic -bios ${UBOOT_BIN} ${DRIVE_BOOT} ${ROOTFS_ARGS}"

QEMU_ARGS=(
  -machine "${MACHINE}"
  -cpu "${CPU}"
  -m "${MEMORY}"
  -nographic
  -bios "${UBOOT_BIN}"
  -drive "if=none,file=${BOOTFAT_IMG},format=raw,id=boot"
  -device virtio-blk-pci,drive=boot,bootindex=0
)
if [[ -n "${ROOTFS_IMG:-}" && -f "${ROOTFS_IMG}" ]]; then
  QEMU_ARGS+=(
    -drive "if=none,file=${ROOTFS_IMG},format=raw,id=root"
    -device virtio-blk-pci,drive=root,bootindex=1
  )
fi

if [[ -n "${LOG_FILE}" ]]; then
  qemu-system-aarch64 "${QEMU_ARGS[@]}" 2>&1 | tee "${LOG_FILE}"
else
  exec qemu-system-aarch64 "${QEMU_ARGS[@]}"
fi
