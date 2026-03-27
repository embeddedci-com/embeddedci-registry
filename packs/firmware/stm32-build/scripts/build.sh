#!/usr/bin/env bash
# Build STM32 firmware in a writable copy of source and stage configured artifacts.
# Env: BUILD_ROOT, PROJECT_ROOT, SRC (optional), SRC_DIR, BUILD_SYSTEM, CMD,
#      ARTIFACT_ELF, ARTIFACT_BIN, ARTIFACT_HEX, TOOLCHAIN,
#      STM32F4XX_HAL_DRIVER_SRC_DIR, CMSIS_DEVICE_F4_SRC_DIR, CMSIS_CORE_SRC_DIR

set -euo pipefail

: "${BUILD_ROOT:?BUILD_ROOT required}"
: "${PROJECT_ROOT:?PROJECT_ROOT required}"
: "${ARTIFACT_ELF:?ARTIFACT_ELF required}"
: "${ARTIFACT_BIN:?ARTIFACT_BIN required}"
: "${ARTIFACT_HEX:?ARTIFACT_HEX required}"

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
  echo "stm32-build: source directory not found: ${FW_SRC}" >&2
  exit 1
fi

# Avoid recursive copy when source is already BUILD_ROOT.
if [[ "${FW_SRC}" == "${BUILD_ROOT}" ]]; then
  BUILD_SRC="${BUILD_ROOT}"
else
  BUILD_SRC="${BUILD_ROOT}/stm32-src"
  rm -rf "${BUILD_SRC}"
  mkdir -p "${BUILD_SRC}"
  cp -a "${FW_SRC}/." "${BUILD_SRC}/"
fi
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

# Assemble expected STM32CubeF4 directory layout from fetched dependencies.
: "${STM32F4XX_HAL_DRIVER_SRC_DIR:?STM32F4XX_HAL_DRIVER_SRC_DIR required}"
: "${CMSIS_DEVICE_F4_SRC_DIR:?CMSIS_DEVICE_F4_SRC_DIR required}"
: "${CMSIS_CORE_SRC_DIR:?CMSIS_CORE_SRC_DIR required}"

CUBE_F4_DIR="${BUILD_SRC}/STM32CubeF4"
HAL_DST="${CUBE_F4_DIR}/Drivers/STM32F4xx_HAL_Driver"
CMSIS_ROOT="${CUBE_F4_DIR}/Drivers/CMSIS"
CMSIS_DEVICE_DST="${CMSIS_ROOT}/Device/ST/STM32F4xx"
CMSIS_CORE_DST="${CMSIS_ROOT}/Core"

rm -rf "${HAL_DST}" "${CMSIS_DEVICE_DST}" "${CMSIS_CORE_DST}"
mkdir -p "${CUBE_F4_DIR}/Drivers" "${CMSIS_ROOT}/Device/ST"
cp -a "${STM32F4XX_HAL_DRIVER_SRC_DIR}" "${HAL_DST}"
cp -a "${CMSIS_DEVICE_F4_SRC_DIR}" "${CMSIS_DEVICE_DST}"
if [[ -d "${CMSIS_CORE_SRC_DIR}/CMSIS/Core" ]]; then
  cp -a "${CMSIS_CORE_SRC_DIR}/CMSIS/Core" "${CMSIS_CORE_DST}"
elif [[ -d "${CMSIS_CORE_SRC_DIR}/Core" ]]; then
  cp -a "${CMSIS_CORE_SRC_DIR}/Core" "${CMSIS_CORE_DST}"
else
  echo "stm32-build: CMSIS core not found in ${CMSIS_CORE_SRC_DIR}" >&2
  exit 1
fi

# Many STM32 projects include CMSIS core headers via Drivers/CMSIS/Include.
# CMSIS_6 ships them in Drivers/CMSIS/Core/Include, so provide compatibility.
if [[ ! -e "${CMSIS_ROOT}/Include" && -d "${CMSIS_CORE_DST}/Include" ]]; then
  ln -s "Core/Include" "${CMSIS_ROOT}/Include"
fi

# Many STM32 projects keep stm32f4xx_hal_conf.h in firmware source root.
# Mirror it into HAL include dir so vendor headers can always resolve it.
if [[ -f "${BUILD_SRC}/stm32f4xx_hal_conf.h" ]]; then
  cp -f "${BUILD_SRC}/stm32f4xx_hal_conf.h" "${HAL_DST}/Inc/stm32f4xx_hal_conf.h"
fi
export CUBE_F4="${CUBE_F4_DIR}"

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
