#!/bin/sh

set -eu

PATH=/sbin:/bin:/usr/sbin:/usr/bin
export PATH

log()  { echo "[init] $*"; }
warn() { echo "[init] WARN: $*" >&2; }
die()  { echo "[init] ERROR: $*" >&2; emergency_shell; }

emergency_shell() {
  echo
  echo "Dropping to emergency shell."
  echo "Useful commands:"
  echo "  cat /proc/cmdline"
  echo "  cat /proc/partitions"
  echo "  ls -l /dev"
  echo "  dmesg | tail -200"
  echo
  exec sh
}

# Enable tracing if cmdline contains "debug" or "initdebug"
case " $(cat /proc/cmdline 2>/dev/null || true) " in
  *" debug "*|*" initdebug "*) set -x ;;
esac

mount_if_needed() {
  mp="$1"; fstype="$2"; src="${3:-none}"; opts="${4:-}"
  mkdir -p "$mp"
  if command -v mountpoint >/dev/null 2>&1; then
    mountpoint -q "$mp" && return 0
  else
    # Fallback: check /proc/mounts
    grep -q " $mp " /proc/mounts 2>/dev/null && return 0
  fi
  if [ -n "$opts" ]; then
    mount -t "$fstype" -o "$opts" "$src" "$mp" || return 1
  else
    mount -t "$fstype" "$src" "$mp" || return 1
  fi
  return 0
}

# 1) Bring up pseudo filesystems
mount_if_needed /proc proc proc || die "mount /proc failed"
mount_if_needed /sys  sysfs sysfs || die "mount /sys failed"
mount_if_needed /run  tmpfs tmpfs "mode=0755,nosuid,nodev" || die "mount /run failed"

mkdir -p /dev /dev/pts
# devtmpfs is best; tolerate failure (some kernels may auto-mount it)
mount_if_needed /dev devtmpfs devtmpfs "mode=0755,nosuid" || warn "devtmpfs mount failed (continuing)"
mount_if_needed /dev/pts devpts devpts "gid=5,mode=0620,nosuid,noexec" || warn "devpts mount failed (continuing)"

# 2) Parse kernel cmdline
CMDLINE="$(cat /proc/cmdline 2>/dev/null || true)"

get_arg() {
  key="$1"
  for x in $CMDLINE; do
    case "$x" in
      "$key"=*) echo "${x#"$key"=}" ; return 0 ;;
    esac
  done
  return 1
}

has_flag() {
  flag="$1"
  case " $CMDLINE " in
    *" $flag "*) return 0 ;;
  esac
  return 1
}

ROOT="$(get_arg root || true)"
FSTYPE="$(get_arg rootfstype || true)"
ROOTFLAGS="$(get_arg rootflags || true)"

# ro/rw preference from cmdline; default rw (your APPEND has rw)
ROOTMODE="rw"
has_flag ro && ROOTMODE="ro"
has_flag rw && ROOTMODE="rw"

# If rootfstype missing, default ext4 (good for your use case)
[ -n "${FSTYPE:-}" ] || FSTYPE="ext4"

# 3) Resolve UUID=/PARTUUID= if possible (optional)
resolve_root_spec() {
  spec="$1"
  case "$spec" in
    UUID=*|PARTUUID=*)
      if command -v blkid >/dev/null 2>&1; then
        blkid -o device -t "$spec" 2>/dev/null | head -n1
        return 0
      fi
      # If blkid not available, we cannot resolve here; return as-is
      echo "$spec"
      return 0
      ;;
    *)
      echo "$spec"
      return 0
      ;;
  esac
}

ROOT_RESOLVED=""
if [ -n "${ROOT:-}" ]; then
  ROOT_RESOLVED="$(resolve_root_spec "$ROOT")"
fi

# 4) Fallback probing (if root= missing or unusable)
is_block() { [ -n "$1" ] && [ -b "$1" ]; }

ext_magic_is_present() {
  dev="$1"
  # ext2/3/4 superblock magic 0xEF53 at offset 1080 bytes
  magic="$(dd if="$dev" bs=1 skip=1080 count=2 2>/dev/null | hexdump -e '1/2 "%04x"')"
  [ "$magic" = "ef53" ]
}

probe_ext_root() {
  for d in /dev/vd[a-z] /dev/vd[a-z][0-9] /dev/vd[a-z]p[0-9] \
           /dev/mmcblk*p* /dev/nvme*n*p*; do
    [ -b "$d" ] || continue
    ext_magic_is_present "$d" && { echo "$d"; return 0; }
  done
  return 1
}

# 5) Rootwait behavior: wait for device node to appear
wait_for_block() {
  dev="$1"
  timeout_s="${2:-30}"
  i=0
  while [ $i -lt $((timeout_s*10)) ]; do
    is_block "$dev" && return 0
    i=$((i+1))
    sleep 0.1
  done
  return 1
}

if ! is_block "$ROOT_RESOLVED"; then
  # If it looks like UUID=/PARTUUID= and we couldn't resolve, try probing instead
  case "${ROOT_RESOLVED:-}" in
    UUID=*|PARTUUID=*) warn "Cannot resolve $ROOT_RESOLVED (blkid missing?)" ;;
    "") warn "No root= provided; probing for ext filesystem" ;;
    *)  warn "root=$ROOT_RESOLVED is not a block device; probing for ext filesystem" ;;
  esac
  ROOT_RESOLVED="$(probe_ext_root || true)"
fi

[ -n "${ROOT_RESOLVED:-}" ] || die "No usable root device found"

# Honor rootwait if specified; your cmdline includes rootwait
if has_flag rootwait; then
  log "Waiting for root device $ROOT_RESOLVED ..."
  wait_for_block "$ROOT_RESOLVED" 30 || die "Timed out waiting for $ROOT_RESOLVED"
fi

log "Root device: $ROOT_RESOLVED"
log "Root fstype: $FSTYPE"
log "Root mode:   $ROOTMODE"

# 6) Mount root (safer: mount ro first, then remount rw if requested)
mkdir -p /newroot

# Compose mount options
BASE_OPTS="errors=remount-ro"
[ -n "${ROOTFLAGS:-}" ] && BASE_OPTS="$BASE_OPTS,${ROOTFLAGS}"

mount -t "$FSTYPE" -o "ro,$BASE_OPTS" "$ROOT_RESOLVED" /newroot || die "Mount root (ro) failed"

if [ "$ROOTMODE" = "rw" ]; then
  mount -o remount,rw /newroot || die "Remount root (rw) failed"
fi

# Optional: sanity check for init
if [ ! -e /newroot/sbin/init ]; then
  warn "/newroot/sbin/init not found"
  ls -la /newroot || true
  ls -la /newroot/sbin || true
  die "No init in new root"
fi

# 7) Move mounts and switch_root
mkdir -p /newroot/proc /newroot/sys /newroot/dev /newroot/run
mount --move /proc /newroot/proc || die "move /proc failed"
mount --move /sys  /newroot/sys  || die "move /sys failed"
mount --move /dev  /newroot/dev  || die "move /dev failed"
mount --move /run  /newroot/run  2>/dev/null || true

exec switch_root /newroot /sbin/init || die "switch_root failed"