#!/usr/bin/env bash
# Build Raspberry Pi Pico firmware with pico-sdk in a writable copy of source and stage artifacts.
# Env: BUILD_ROOT, PROJECT_ROOT, SRC (optional), SRC_DIR, BUILD_SYSTEM, CMD,
#      ARTIFACT_ELF, ARTIFACT_BIN, ARTIFACT_HEX, TOOLCHAIN (optional), PICO_SDK_DIR

set -euo pipefail

: "${BUILD_ROOT:?BUILD_ROOT required}"
: "${PROJECT_ROOT:?PROJECT_ROOT required}"
: "${ARTIFACT_ELF:?ARTIFACT_ELF required}"
: "${ARTIFACT_BIN:?ARTIFACT_BIN required}"
: "${ARTIFACT_HEX:?ARTIFACT_HEX required}"
: "${PICO_SDK_DIR:?PICO_SDK_DIR required}"

if [[ ! -d "${PICO_SDK_DIR}" ]]; then
  echo "pico-build: pico-sdk not found: ${PICO_SDK_DIR}" >&2
  exit 1
fi
export PICO_SDK_PATH="${PICO_SDK_DIR}"

if [[ -n "${SRC_DIR:-}" && -d "${SRC_DIR}" ]]; then
  FW_SRC="${SRC_DIR}"
elif [[ -n "${SRC:-}" ]]; then
  if [[ "${SRC}" == /* ]]; then
    FW_SRC="${SRC}"
  else
    FW_SRC="${PROJECT_ROOT}/${SRC}"
  fi
else
  FW_SRC="${BUILD_ROOT}"
fi

if [[ ! -d "${FW_SRC}" ]]; then
  echo "pico-build: source directory not found: ${FW_SRC}" >&2
  exit 1
fi

# Avoid recursive copy when source is already BUILD_ROOT.
if [[ "${FW_SRC}" == "${BUILD_ROOT}" ]]; then
  BUILD_SRC="${BUILD_ROOT}"
else
  BUILD_SRC="${BUILD_ROOT}/pico-src"
  rm -rf "${BUILD_SRC}"
  mkdir -p "${BUILD_SRC}"
  cp -a "${FW_SRC}/." "${BUILD_SRC}/"
fi
cd "${BUILD_SRC}"

unset CC CXX AR AS LD

# Optional: common GNU Arm Embedded names for non-CMake builds (CMake+pico-sdk sets the toolchain itself).
if [[ -n "${TOOLCHAIN:-}" && "${BUILD_SYSTEM:-cmake}" != "cmake" ]]; then
  export CROSS_COMPILE="${TOOLCHAIN}-"
  export CC="${TOOLCHAIN}-gcc"
  export CXX="${TOOLCHAIN}-g++"
  export AR="${TOOLCHAIN}-ar"
  export AS="${TOOLCHAIN}-as"
  export OBJCOPY="${TOOLCHAIN}-objcopy"
  export OBJDUMP="${TOOLCHAIN}-objdump"
  export SIZE="${TOOLCHAIN}-size"
  echo "pico-build: toolchain=${TOOLCHAIN}"
fi

if [[ -n "${CMD:-}" ]]; then
  eval "${CMD}"
else
  case "${BUILD_SYSTEM:-cmake}" in
    cmake)
      cmake -S . -B build
      cmake --build build -j"$(getconf _NPROCESSORS_ONLN)"
      ;;
    make)
      make -j"$(getconf _NPROCESSORS_ONLN)"
      ;;
    *)
      echo "pico-build: unsupported build_system=${BUILD_SYSTEM}. Provide cmd." >&2
      exit 1
      ;;
  esac
fi

need_artifact() {
  local rel="$1"
  if [[ ! -f "${BUILD_SRC}/${rel}" ]]; then
    echo "pico-build: missing artifact ${rel}" >&2
    exit 1
  fi
}

need_artifact "${ARTIFACT_ELF}"
need_artifact "${ARTIFACT_BIN}"
need_artifact "${ARTIFACT_HEX}"

OUT_DIR="${BUILD_ROOT}/out/pico-build"
mkdir -p "${OUT_DIR}"
mkdir -p "$(dirname "${OUT_DIR}/${ARTIFACT_ELF}")"
mkdir -p "$(dirname "${OUT_DIR}/${ARTIFACT_BIN}")"
mkdir -p "$(dirname "${OUT_DIR}/${ARTIFACT_HEX}")"
cp -v "${BUILD_SRC}/${ARTIFACT_ELF}" "${OUT_DIR}/${ARTIFACT_ELF}"
cp -v "${BUILD_SRC}/${ARTIFACT_BIN}" "${OUT_DIR}/${ARTIFACT_BIN}"
cp -v "${BUILD_SRC}/${ARTIFACT_HEX}" "${OUT_DIR}/${ARTIFACT_HEX}"
