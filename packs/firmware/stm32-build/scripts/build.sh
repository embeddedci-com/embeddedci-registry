#!/usr/bin/env bash
# Build STM32 firmware in a writable copy of source and stage configured artifacts.
# Env: BUILD_ROOT, PROJECT_ROOT, SRC, SRC_DIR, BUILD_SYSTEM, CMD,
#      ARTIFACT_ELF, ARTIFACT_BIN, ARTIFACT_HEX, TOOLCHAIN

set -euo pipefail

: "${BUILD_ROOT:?BUILD_ROOT required}"
: "${PROJECT_ROOT:?PROJECT_ROOT required}"
: "${SRC:?SRC required}"
: "${ARTIFACT_ELF:?ARTIFACT_ELF required}"
: "${ARTIFACT_BIN:?ARTIFACT_BIN required}"
: "${ARTIFACT_HEX:?ARTIFACT_HEX required}"

if [[ -n "${SRC_DIR:-}" && -d "${SRC_DIR}" ]]; then
  FW_SRC="${SRC_DIR}"
elif [[ "${SRC}" == /* ]]; then
  FW_SRC="${SRC}"
else
  FW_SRC="${PROJECT_ROOT}/${SRC}"
fi

if [[ ! -d "${FW_SRC}" ]]; then
  echo "stm32-build: source directory not found: ${FW_SRC}" >&2
  exit 1
fi

BUILD_SRC="${BUILD_ROOT}/stm32-src"
rm -rf "${BUILD_SRC}"
mkdir -p "${BUILD_SRC}"
cp -a "${FW_SRC}/." "${BUILD_SRC}/"
cd "${BUILD_SRC}"

# Common GNU Arm Embedded toolchain env (used by many Make/CMake projects).
if [[ -n "${TOOLCHAIN:-}" ]]; then
  export CROSS_COMPILE="${TOOLCHAIN}-"
  export CC="${TOOLCHAIN}-gcc"
  export CXX="${TOOLCHAIN}-g++"
  export AR="${TOOLCHAIN}-ar"
  export AS="${TOOLCHAIN}-as"
  export OBJCOPY="${TOOLCHAIN}-objcopy"
  export OBJDUMP="${TOOLCHAIN}-objdump"
  export SIZE="${TOOLCHAIN}-size"
  echo "stm32-build: toolchain=${TOOLCHAIN}"
fi

if [[ -n "${CMD:-}" ]]; then
  eval "${CMD}"
else
  case "${BUILD_SYSTEM:-make}" in
    make)
      make -j"$(getconf _NPROCESSORS_ONLN)"
      ;;
    cmake)
      cmake -S . -B build
      cmake --build build -j"$(getconf _NPROCESSORS_ONLN)"
      ;;
    *)
      echo "stm32-build: unsupported build_system=${BUILD_SYSTEM}. Provide cmd." >&2
      exit 1
      ;;
  esac
fi

need_artifact() {
  local rel="$1"
  if [[ ! -f "${BUILD_SRC}/${rel}" ]]; then
    echo "stm32-build: missing artifact ${rel}" >&2
    exit 1
  fi
}

need_artifact "${ARTIFACT_ELF}"
need_artifact "${ARTIFACT_BIN}"
need_artifact "${ARTIFACT_HEX}"

OUT_DIR="${BUILD_ROOT}/out/stm32-build"
mkdir -p "${OUT_DIR}"
mkdir -p "$(dirname "${OUT_DIR}/${ARTIFACT_ELF}")"
mkdir -p "$(dirname "${OUT_DIR}/${ARTIFACT_BIN}")"
mkdir -p "$(dirname "${OUT_DIR}/${ARTIFACT_HEX}")"
cp -v "${BUILD_SRC}/${ARTIFACT_ELF}" "${OUT_DIR}/${ARTIFACT_ELF}"
cp -v "${BUILD_SRC}/${ARTIFACT_BIN}" "${OUT_DIR}/${ARTIFACT_BIN}"
cp -v "${BUILD_SRC}/${ARTIFACT_HEX}" "${OUT_DIR}/${ARTIFACT_HEX}"
