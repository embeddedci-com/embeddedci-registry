#!/usr/bin/env bash
# Build rootfs using Buildroot.
#
# Required env:
#   BUILD_ROOT, PROJECT_ROOT
#   SOURCE          project-relative path to Buildroot config (e.g. examples/buildroot-config-example)
#   DEFCONFIG       Buildroot defconfig target (e.g. beaglebone_defconfig)
#   BUILDROOT_CONFIG_DIR  absolute path to config (default: PROJECT_ROOT/SOURCE)
#
# Optional env:
#   BUILDROOT_TREE  Buildroot source tree (default: BUILD_ROOT/buildroot_src, from fetch dependency)
#   OUTPUTS         comma-separated or JSON array: ext4, cpio.gz (default: ext4)
#   OVERLAYS        comma-separated or JSON array of paths relative to config dir
#   HOSTNAME        target hostname
#   CONSOLE_LOGIN    enabled|disabled
#   APP_ARTIFACTS   JSON array of {artifact,dst,mode} or legacy "name:dst:mode"
#   USERS           JSON array of {name,password} or legacy "name:password"
#   APP_BIN         path to app binary (when dependency apps/build is used)
#   BUILD_TMPDIR    temp dir for compiler/toolchain (default: BUILD_ROOT/tmp); avoids small /tmp tmpfs
#
# O= output dir (see BR_OUT_* below). Artifacts end up under BUILD_ROOT/buildroot_out/images/ for applyOutputs.

set -euo pipefail

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing '$1'"; exit 1; }; }

truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|y|Y|on|ON|enabled|ENABLED) return 0 ;;
    *) return 1 ;;
  esac
}

# Parse OVERLAYS: JSON array or comma-separated
overlays_list() {
  local v="${OVERLAYS:-}"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  if [[ -z "$v" ]]; then
    return
  fi
  if [[ "$v" == "["* ]]; then
    if command -v jq >/dev/null 2>&1; then
      jq -r '.[]' <<< "$v" 2>/dev/null || true
    fi
    return
  fi
  tr ',' '\n' <<< "$v"
}

# Parse APP_ARTIFACTS: JSON array of {artifact,dst,mode} or "artifact:dst:mode"
app_artifacts_list() {
  local v="${APP_ARTIFACTS:-}"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  if [[ -z "$v" ]]; then
    return
  fi
  if [[ "$v" == "["* ]] && command -v jq >/dev/null 2>&1; then
    jq -r '.[] | "\(.artifact):\(.dst):\(.mode // "0755")"' <<< "$v" 2>/dev/null || true
    return
  fi
  echo "$v"
}

# Parse USERS: JSON array of {name,password} or "name:password"
users_list() {
  local v="${USERS:-}"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  if [[ -z "$v" ]]; then
    return
  fi
  if [[ "$v" == "["* ]] && command -v jq >/dev/null 2>&1; then
    jq -r '.[] | "\(.name):\(.password)"' <<< "$v" 2>/dev/null || true
    return
  fi
  echo "$v"
}

# Parse OUTPUTS: JSON array or comma-separated
outputs_list() {
  local v="${OUTPUTS:-ext4}"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  if [[ -z "$v" ]]; then
    echo "ext4"
    return
  fi
  if [[ "$v" == "["* ]]; then
    if command -v jq >/dev/null 2>&1; then
      jq -r '.[]' <<< "$v" 2>/dev/null || echo "ext4"
      return
    fi
  fi
  tr ',' '\n' <<< "$v"
}

# ===== Config =====
: "${BUILD_ROOT:?BUILD_ROOT required}"
: "${PROJECT_ROOT:?PROJECT_ROOT required}"

# Use build volume for temp files (GCC .s, etc.) so /tmp tmpfs or small root is not exhausted.
BUILD_TMPDIR="${BUILD_TMPDIR:-${BUILD_ROOT}/tmp}"
mkdir -p "$BUILD_TMPDIR"
export TMPDIR="$BUILD_TMPDIR"
export TMP="$BUILD_TMPDIR"
export TEMP="$BUILD_TMPDIR"
echo "[*] TMPDIR=$TMPDIR (compiler/temp files on build volume)"
: "${SOURCE:?SOURCE required (project-relative path to Buildroot config)}"
: "${DEFCONFIG:?DEFCONFIG required (e.g. beaglebone_defconfig)}"

# Derive paths: fetch copies BR2_EXTERNAL to buildroot_external; unexpanded env or bad paths fall back
case "$BUILDROOT_CONFIG_DIR" in
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
case "$BUILDROOT_TREE" in
  ""|*"{{"*) BUILDROOT_TREE="$BUILD_ROOT/buildroot_src" ;;
esac
case "$APP_BIN" in
  *"{{"*) APP_BIN="$BUILD_ROOT/app_bin" ;;
esac

HOSTNAME="${HOSTNAME:-embedded-ci}"
CONSOLE_LOGIN="${CONSOLE_LOGIN:-disabled}"
APP_BIN="${APP_BIN:-}"

echo "[*] Buildroot rootfs build"
echo "    BUILDROOT_TREE=$BUILDROOT_TREE"
echo "    BUILDROOT_CONFIG_DIR=$BUILDROOT_CONFIG_DIR"
echo "    DEFCONFIG=$DEFCONFIG"

if [[ ! -d "$BUILDROOT_CONFIG_DIR" ]]; then
  echo "ERROR: BUILDROOT_CONFIG_DIR not a directory: $BUILDROOT_CONFIG_DIR"
  exit 1
fi

if [[ ! -f "$BUILDROOT_TREE/Makefile" ]]; then
  echo "ERROR: Buildroot tree not found at $BUILDROOT_TREE (no Makefile). Fetch puts clone at BUILD_ROOT/buildroot_src; set BUILDROOT_TREE if different."
  exit 1
fi

need make

# Out-of-tree build (O=):
# - Local / non-Docker: default O=BUILD_ROOT/buildroot_out (avoids filling tmpfs /tmp; full Buildroot is GB-scale).
# - Docker (/.dockerenv): default O=/tmp/... because bind mounts often break chmod on extracts (e.g. macOS).
# Override: BR_OUT_USE_TMP=1 (always /tmp), BR_OUT_USE_MOUNT=1 (always BUILD_ROOT/buildroot_out).
BR_OUT_STAGING="$BUILD_ROOT/buildroot_out"
mkdir -p "$BR_OUT_STAGING/images"
BR_OUT_USE_TMP="${BR_OUT_USE_TMP:-}"
BR_OUT_USE_MOUNT="${BR_OUT_USE_MOUNT:-}"
if [[ "$BR_OUT_USE_MOUNT" == "1" ]]; then
  BR_OUT="$BR_OUT_STAGING"
elif [[ "$BR_OUT_USE_TMP" == "1" ]] || [[ -f /.dockerenv ]]; then
  BR_OUT=$(mktemp -d /tmp/embeddedci-br-out.XXXXXX)
  echo "[*] Buildroot O= $BR_OUT (tmp; copy to $BR_OUT_STAGING/images after build)"
else
  BR_OUT="$BR_OUT_STAGING"
  echo "[*] Buildroot O= $BR_OUT (local disk under BUILD_ROOT)"
fi

# Optional post-build script for app artifact(s)
POST_SCRIPT=""
if [[ -n "$APP_BIN" ]] && [[ -f "$APP_BIN" ]]; then
  POST_SCRIPT="$BUILDROOT_CONFIG_DIR/post_embedci_app.sh"
  {
    echo '#!/bin/sh'
    echo 'set -e'
    app_artifacts_list | while IFS=: read -r art dst mode; do
      [[ -z "$art" ]] && continue
      mode="${mode:-0755}"
      echo "cp \"$APP_BIN\" \"\$TARGET_DIR/${dst#/}\""
      echo "chmod $mode \"\$TARGET_DIR/${dst#/}\""
    done
  } > "$POST_SCRIPT"
  chmod +x "$POST_SCRIPT"
  echo "[*] Post-build script for app artifact(s): $POST_SCRIPT"
fi

# Collect overlay dirs (absolute paths)
# Avoid bash process substitution < <(...) — needs /dev/fd (unavailable in firecracker/jailer).
OVERLAY_DIRS=()
_overlay_tmp="${BUILD_ROOT}/.buildroot_overlays_list.$$"
overlays_list > "$_overlay_tmp" || true
while IFS= read -r ov || [[ -n "$ov" ]]; do
  [[ -z "$ov" ]] && continue
  abs="$BUILDROOT_CONFIG_DIR/$ov"
  [[ -d "$abs" ]] && OVERLAY_DIRS+=("$abs")
done < "$_overlay_tmp"
rm -f "$_overlay_tmp"

# Run Buildroot with O= (out-of-tree): source tree stays read-only, all output in BR_OUT
MAKE_ARGS=(BR2_EXTERNAL="$BUILDROOT_CONFIG_DIR" O="$BR_OUT")
pushd "$BUILDROOT_TREE" >/dev/null

make "${MAKE_ARGS[@]}" "${DEFCONFIG}"

# Optional: set hostname, overlays, post-script in O/.config then olddefconfig
CONFIG_FILE="$BR_OUT/.config"
if [[ -f "$CONFIG_FILE" ]]; then
  if [[ -n "$HOSTNAME" ]]; then
    if grep -q '^BR2_TARGET_GENERIC_HOSTNAME=' "$CONFIG_FILE"; then
      sed -i "s|^BR2_TARGET_GENERIC_HOSTNAME=.*|BR2_TARGET_GENERIC_HOSTNAME=\"$HOSTNAME\"|" "$CONFIG_FILE"
    else
      echo "BR2_TARGET_GENERIC_HOSTNAME=\"$HOSTNAME\"" >> "$CONFIG_FILE"
    fi
  fi
  if [[ ${#OVERLAY_DIRS[@]} -gt 0 ]]; then
    joined=$(IFS=' '; echo "${OVERLAY_DIRS[*]}")
    if grep -q '^BR2_ROOTFS_OVERLAY=' "$CONFIG_FILE"; then
      prev=$(grep '^BR2_ROOTFS_OVERLAY=' "$CONFIG_FILE" | cut -d= -f2- | tr -d '"')
      sed -i "s|^BR2_ROOTFS_OVERLAY=.*|BR2_ROOTFS_OVERLAY=\"$prev $joined\"|" "$CONFIG_FILE"
    else
      echo "BR2_ROOTFS_OVERLAY=\"$joined\"" >> "$CONFIG_FILE"
    fi
  fi
  if [[ -n "$POST_SCRIPT" ]]; then
    if grep -q '^BR2_ROOTFS_POST_SCRIPT=' "$CONFIG_FILE"; then
      prev=$(grep '^BR2_ROOTFS_POST_SCRIPT=' "$CONFIG_FILE" | cut -d= -f2- | tr -d '"')
      sed -i "s|^BR2_ROOTFS_POST_SCRIPT=.*|BR2_ROOTFS_POST_SCRIPT=\"$prev $POST_SCRIPT\"|" "$CONFIG_FILE"
    else
      echo "BR2_ROOTFS_POST_SCRIPT=\"$POST_SCRIPT\"" >> "$CONFIG_FILE"
    fi
  fi
  make "${MAKE_ARGS[@]}" olddefconfig
fi
make "${MAKE_ARGS[@]}"
popd >/dev/null

if [[ "$BR_OUT" != "$BR_OUT_STAGING" ]] && [[ -d "$BR_OUT/images" ]]; then
  cp -a "$BR_OUT/images/"* "$BR_OUT_STAGING/images/" 2>/dev/null || true
  rm -rf "$BR_OUT"
  echo "[*] Staged images to $BR_OUT_STAGING/images (for artifact export)"
fi
echo "[*] Done: outputs in $BR_OUT_STAGING/images"
