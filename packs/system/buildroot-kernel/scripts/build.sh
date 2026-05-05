#!/usr/bin/env bash
# Build Linux kernel with Buildroot without producing rootfs artifacts.
#
# Required env:
#   BUILD_ROOT, PROJECT_ROOT
#   SOURCE, ARCH, REF
#   DEFCONFIG — pack config key "defconfig": Buildroot defconfig make target from BR2_EXTERNAL (configs/*.defconfig).
#
# Device trees: BOARD_DTBS from board dtbs: YAML lists DTB basenames (e.g. am335x-boneblack.dtb).
# When BOARD_DTBS is set, this script forces BR2_LINUX_KERNEL_DTS_SUPPORT=y, extracts the kernel
# source via `make linux-extract`, then resolves each basename to its vendor-relative stem under
# arch/<KERNEL_ARCH>/boot/dts/ (Linux 6.5+ moved ARM dts files into vendor subdirs such as
# ti/omap/), and writes BR2_LINUX_KERNEL_INTREE_DTS_NAME with the resolved subpaths so Buildroot's
# `make <subpath>.dtb` invocation matches the kernel's pattern rules. Buildroot installs each DTB
# under $O/images/<basename>.dtb (notdir, since BR2_LINUX_KERNEL_DTB_KEEP_DIRNAME is unset). DTBs
# are then copied from $O/images/ into kernel/dtbs/ for artifacts.
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

: "${BUILD_ROOT:?BUILD_ROOT required}"
: "${PROJECT_ROOT:?PROJECT_ROOT required}"
: "${SOURCE:?SOURCE required (path or git URL for BR2_EXTERNAL)}"
: "${ARCH:?ARCH required}"
: "${REF:?REF required}"

: "${DEFCONFIG:?Pack config defconfig is required (BR2_EXTERNAL make target matching configs/<name>_defconfig)}"
BR2_BASE_DEFCONFIG="${DEFCONFIG}"

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
echo "    defconfig=${DEFCONFIG}"
echo "    BR2_BASE_DEFCONFIG=${BR2_BASE_DEFCONFIG}"
echo "    ARCH=$ARCH"
echo "    EFFECTIVE_ARCH=$EFFECTIVE_ARCH"
echo "    KERNEL_DEFCONFIG=$KERNEL_DEFCONFIG"
echo "    REF=$REF"
echo "    O=$BR_OUT"

MAKE_ARGS=(BR2_EXTERNAL="$BUILDROOT_CONFIG_DIR" O="$BR_OUT")
pushd "$BUILDROOT_TREE" >/dev/null
make "${MAKE_ARGS[@]}" "$BR2_BASE_DEFCONFIG"

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
  KERNEL_ARCH="arm"
elif [[ "$EFFECTIVE_ARCH" == "arm64" || "$EFFECTIVE_ARCH" == "aarch64" ]]; then
  set_no "$CONFIG_FILE" BR2_arm
  set_yes "$CONFIG_FILE" BR2_aarch64
  KERNEL_ARCH="arm64"
else
  echo "ERROR: Unsupported arch=$EFFECTIVE_ARCH (expected arm or arm64)"
  exit 1
fi

# BR2_LINUX_KERNEL_DTS_SUPPORT must be y for Buildroot to compile/install DTBs. It is gated by
# BR2_LINUX_KERNEL in linux/Config.in, so any value from the defconfig is dropped when the initial
# `make <defconfig>` runs (BR2_LINUX_KERNEL is enabled by this script *after* defconfig load).
# Re-assert it here whenever board dtbs: are requested, otherwise BR2_LINUX_KERNEL_INTREE_DTS_NAME
# would be silently stripped by `make olddefconfig`.
#
# We collect bare DTS basenames here only as a placeholder for the first olddefconfig pass: the
# Buildroot `BR_BUILDING` sanity checks reject DTS_SUPPORT=y combined with an empty INTREE_DTS_NAME,
# and we need a valid .config to run `make linux-extract`. After extraction we rewrite the names
# with the actual vendor subpaths (Linux 6.5+ moved ARM dts files into arch/arm/boot/dts/<vendor>/).
br2_intree_dts_basenames=""
if [[ -n "${BOARD_DTBS:-}" ]]; then
  while IFS= read -r piece; do
    [[ -z "$piece" ]] && continue
    stem="${piece%.dtb}"
    stem="${stem%.dts}"
    [[ -z "$stem" ]] && continue
    if [[ -n "$br2_intree_dts_basenames" ]]; then
      br2_intree_dts_basenames+=" "
    fi
    br2_intree_dts_basenames+="$stem"
  done < <(echo "${BOARD_DTBS}" | split_csv)
  if [[ -n "$br2_intree_dts_basenames" ]]; then
    set_yes "$CONFIG_FILE" BR2_LINUX_KERNEL_DTS_SUPPORT
    set_str "$CONFIG_FILE" BR2_LINUX_KERNEL_INTREE_DTS_NAME "$br2_intree_dts_basenames"
  fi
else
  set_no "$CONFIG_FILE" BR2_LINUX_KERNEL_DTS_SUPPORT
fi

make "${MAKE_ARGS[@]}" olddefconfig

if [[ -n "$br2_intree_dts_basenames" ]]; then
  echo "[*] Extracting Linux source to resolve DTS subpaths"
  make "${MAKE_ARGS[@]}" linux-extract

  LINUX_BUILD_DIR=""
  for d in "$BR_OUT/build/linux-"*; do
    [[ -d "$d/arch/$KERNEL_ARCH/boot/dts" ]] || continue
    LINUX_BUILD_DIR="$d"
    break
  done
  if [[ -z "$LINUX_BUILD_DIR" ]]; then
    echo "ERROR: cannot locate extracted linux source under $BR_OUT/build/ (looked for linux-*/arch/$KERNEL_ARCH/boot/dts/)" >&2
    ls -la "$BR_OUT/build" 2>/dev/null || true
    exit 1
  fi
  DTS_ROOT="$LINUX_BUILD_DIR/arch/$KERNEL_ARCH/boot/dts"

  br2_intree_dts_names=""
  for stem in $br2_intree_dts_basenames; do
    mapfile -t matches < <(find "$DTS_ROOT" -type f -name "${stem}.dts" -print)
    if [[ "${#matches[@]}" -eq 0 ]]; then
      echo "ERROR: ${stem}.dts not found under ${DTS_ROOT} (BOARD_DTBS=${BOARD_DTBS})." >&2
      echo "       Verify the board dtbs: list and the kernel REF=${REF}." >&2
      exit 1
    fi
    if [[ "${#matches[@]}" -gt 1 ]]; then
      echo "ERROR: ${stem}.dts is ambiguous under ${DTS_ROOT}:" >&2
      printf '         %s\n' "${matches[@]}" >&2
      exit 1
    fi
    rel_path="${matches[0]#${DTS_ROOT}/}"
    rel_dir="$(dirname "$rel_path")"
    if [[ "$rel_dir" == "." ]]; then
      full_stem="$stem"
    else
      full_stem="${rel_dir}/${stem}"
    fi
    if [[ -n "$br2_intree_dts_names" ]]; then
      br2_intree_dts_names+=" "
    fi
    br2_intree_dts_names+="$full_stem"
  done

  set_str "$CONFIG_FILE" BR2_LINUX_KERNEL_INTREE_DTS_NAME "$br2_intree_dts_names"
  echo "[*] BR2_LINUX_KERNEL_INTREE_DTS_NAME=\"${br2_intree_dts_names}\" (resolved from board dtbs:)"
  make "${MAKE_ARGS[@]}" olddefconfig
fi

make "${MAKE_ARGS[@]}" linux-reconfigure
# Buildroot has no top-level "linux-dtbs" target; the linux package builds/installs DTBs as part
# of "make linux" (see linux/linux.mk: LINUX_BUILD_CMDS → LINUX_BUILD_DTB + LINUX_INSTALL_DTB).
make "${MAKE_ARGS[@]}" linux
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

# Device trees: Buildroot installs *.dtb under $O/images/ (flat or subdirs). Copy only from there
# into kernel/dtbs/ for the pack artifact path "kernel/"; do not search the linux build tree.
if [[ -d "${BR_OUT}/images" ]]; then
  while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    cp "$f" "$KERNEL_OUT/dtbs/${base}"
    echo "[*] staged dtb: ${base} <- \${BR_OUT}/images/"
  done < <(find "${BR_OUT}/images" -type f -name '*.dtb' -print0 2>/dev/null || true)
fi

if [[ -n "${BOARD_DTBS:-}" ]]; then
  while IFS= read -r requested_dtb; do
    [[ -z "$requested_dtb" ]] && continue
    if [[ ! -f "${KERNEL_OUT}/dtbs/${requested_dtb}" ]]; then
      echo "ERROR: Board dtbs: expects ${requested_dtb} under kernel/dtbs/ but Buildroot did not install it to ${BR_OUT}/images/ (BOARD_DTBS=${BOARD_DTBS})." >&2
      echo "       Fix board dtbs: list or BR2_LINUX_KERNEL_INTREE_DTS_NAME so Buildroot installs this file under ${BR_OUT}/images/." >&2
      ls -la "${BR_OUT}/images" 2>/dev/null || echo "(no ${BR_OUT}/images directory)"
      exit 1
    fi
  done < <(echo "${BOARD_DTBS}" | split_csv)
fi

if [[ ! -f "$KERNEL_OUT/Image" && ! -f "$KERNEL_OUT/zImage" ]]; then
  echo "ERROR: No kernel image produced in $KERNEL_OUT"
  exit 1
fi

echo "[*] Kernel artifacts staged under: $KERNEL_OUT"
