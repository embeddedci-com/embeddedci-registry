#!/usr/bin/env bash
# image/sdcard: Combine boot FAT partition + ext4 rootfs into a single flashable sdcard.img
#
# Inputs (required):
#   BUILD_ROOT           working/output directory
#   BOOTFAT_IMG          path to bootfat.img (contains MBR + partition 1 FAT32)
#   ROOTFS_IMG           path to rootfs.ext4 (raw ext4 filesystem image)
#
# Optional board/env knobs:
#   SDCARD_IMG_NAME      output filename (default: sdcard.img)
#   SDCARD_SIZE_MB       total sdcard image size in MiB (default: auto-fit)
#   BOOT_PART_START_MB   start offset for boot partition (default: 1)
#   BOOT_PART_SIZE_MB    size for boot partition in MiB (default: inferred from BOOTFAT_IMG file size, rounded up)
#   ROOT_PART_SIZE_MB    size for root partition in MiB (default: inferred from ROOTFS_IMG file size, rounded up)
#   ALIGN_MB             alignment in MiB for partitions (default: 4)
#
# Output:
#   ${BUILD_ROOT}/${SDCARD_IMG_NAME}

set -euo pipefail

: "${BUILD_ROOT:?BUILD_ROOT required}"
: "${BOOTFAT_IMG:?BOOTFAT_IMG required}"
: "${ROOTFS_IMG:?ROOTFS_IMG required}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing '$1'"; exit 1; }; }

need dd
need parted
need awk
need stat
need truncate

OUT_NAME="${SDCARD_IMG_NAME:-sdcard.img}"
OUT_PATH="${BUILD_ROOT}/${OUT_NAME}"

ALIGN_MB="${ALIGN_MB:-4}"
BOOT_PART_START_MB="${BOOT_PART_START_MB:-1}"

# Round bytes to MiB
bytes_to_mib_ceil() {
  local bytes="$1"
  # ceil(bytes / 1048576)
  echo $(( (bytes + 1048576 - 1) / 1048576 ))
}

BOOTFAT_BYTES="$(stat -c '%s' "${BOOTFAT_IMG}")"
ROOTFS_BYTES="$(stat -c '%s' "${ROOTFS_IMG}")"

# Infer partition sizes if not provided
BOOT_PART_SIZE_MB="${BOOT_PART_SIZE_MB:-$(bytes_to_mib_ceil "${BOOTFAT_BYTES}")}"
ROOT_PART_SIZE_MB="${ROOT_PART_SIZE_MB:-$(bytes_to_mib_ceil "${ROOTFS_BYTES}")}"

# Align sizes up to ALIGN_MB
align_up() {
  local v="$1" a="$2"
  echo $(( ((v + a - 1) / a) * a ))
}
BOOT_PART_SIZE_MB="$(align_up "${BOOT_PART_SIZE_MB}" "${ALIGN_MB}")"
ROOT_PART_SIZE_MB="$(align_up "${ROOT_PART_SIZE_MB}" "${ALIGN_MB}")"

# Compute partition boundaries
BOOT_PART_END_MB=$(( BOOT_PART_START_MB + BOOT_PART_SIZE_MB ))
ROOT_PART_START_MB="$(align_up "${BOOT_PART_END_MB}" "${ALIGN_MB}")"
ROOT_PART_END_MB=$(( ROOT_PART_START_MB + ROOT_PART_SIZE_MB ))

# Total size (allow a little slack at end)
AUTO_TOTAL_MB=$(( ROOT_PART_END_MB + ALIGN_MB ))
SDCARD_SIZE_MB="${SDCARD_SIZE_MB:-${AUTO_TOTAL_MB}}"
SDCARD_SIZE_MB="$(align_up "${SDCARD_SIZE_MB}" "${ALIGN_MB}")"

echo "[*] BOOTFAT_IMG: ${BOOTFAT_IMG} (${BOOTFAT_BYTES} bytes, ${BOOT_PART_SIZE_MB} MiB allocated)"
echo "[*] ROOTFS_IMG:  ${ROOTFS_IMG} (${ROOTFS_BYTES} bytes, ${ROOT_PART_SIZE_MB} MiB allocated)"
echo "[*] Layout:"
echo "    p1 (FAT32 boot): start=${BOOT_PART_START_MB}MiB size=${BOOT_PART_SIZE_MB}MiB end=${BOOT_PART_END_MB}MiB"
echo "    p2 (EXT4 root):  start=${ROOT_PART_START_MB}MiB size=${ROOT_PART_SIZE_MB}MiB end=${ROOT_PART_END_MB}MiB"
echo "[*] Output: ${OUT_PATH} (${SDCARD_SIZE_MB} MiB)"

mkdir -p "${BUILD_ROOT}"
rm -f "${OUT_PATH}"
truncate -s "${SDCARD_SIZE_MB}M" "${OUT_PATH}"

# Partition table: MBR + 2 partitions
parted -s "${OUT_PATH}" mklabel msdos
parted -s "${OUT_PATH}" mkpart primary fat32 "${BOOT_PART_START_MB}MiB" "${BOOT_PART_END_MB}MiB"
parted -s "${OUT_PATH}" set 1 boot on
parted -s "${OUT_PATH}" mkpart primary ext4 "${ROOT_PART_START_MB}MiB" "${ROOT_PART_END_MB}MiB"

# Compute byte offsets for partitions
P1_START_B="$(
  parted -ms "${OUT_PATH}" unit B print \
    | awk -F: '$1=="1"{gsub(/B/,"",$2); print $2}'
)"
P2_START_B="$(
  parted -ms "${OUT_PATH}" unit B print \
    | awk -F: '$1=="2"{gsub(/B/,"",$2); print $2}'
)"

[[ -n "${P1_START_B}" ]] || { echo "Failed to get p1 start offset"; exit 1; }
[[ -n "${P2_START_B}" ]] || { echo "Failed to get p2 start offset"; exit 1; }

echo "[*] Writing boot partition image into p1 region..."
dd if="${BOOTFAT_IMG}" of="${OUT_PATH}" bs=4M seek="${P1_START_B}" oflag=seek_bytes conv=notrunc status=progress

echo "[*] Writing ext4 rootfs image into p2 region..."
dd if="${ROOTFS_IMG}" of="${OUT_PATH}" bs=4M seek="${P2_START_B}" oflag=seek_bytes conv=notrunc status=progress

echo "[*] Done: ${OUT_PATH}"
echo "[*] Tip: flash with: sudo dd if='${OUT_PATH}' of=/dev/sdX bs=4M conv=fsync status=progress"