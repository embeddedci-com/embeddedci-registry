#!/usr/bin/env bash
# Build an application. Runs CMD in a writable copy of SRC; artifact is the produced binary.
# PROJECT is mounted read-only, so we copy SRC to BUILD_ROOT and build there.
# Env: BUILD_ROOT, PROJECT_ROOT, CMD, SRC, ARTIFACT

set -e

: "${BUILD_ROOT:?BUILD_ROOT required}"
: "${PROJECT_ROOT:?PROJECT_ROOT required}"
: "${CMD:?CMD required}"
: "${SRC:?SRC required}"
: "${ARTIFACT:?ARTIFACT required}"

# SRC is either a path relative to PROJECT_ROOT (local) or an absolute path under BUILD_ROOT (git fetch).
if [[ "${SRC}" == /* ]]; then
  APP_SRC="${SRC}"
else
  APP_SRC="${PROJECT_ROOT}/${SRC}"
fi
if [[ ! -d "${APP_SRC}" ]]; then
  echo "App source not found: ${APP_SRC}"
  exit 1
fi

# Copy source to writable area (project is mounted read-only)
BUILD_SRC="${BUILD_ROOT}/app-src"
rm -rf "${BUILD_SRC}"
mkdir -p "${BUILD_SRC}"
cp -a "${APP_SRC}/." "${BUILD_SRC}/"

cd "${BUILD_SRC}"
eval "${CMD}"

if [[ ! -f "${BUILD_SRC}/${ARTIFACT}" ]]; then
  echo "Build did not produce ${ARTIFACT} in ${BUILD_SRC}"
  exit 1
fi

# Copy artifact to out dir for engine / rootfs-image pack
OUT_DIR="${BUILD_ROOT}/out/app-build"
mkdir -p "${OUT_DIR}"
cp -v "${BUILD_SRC}/${ARTIFACT}" "${OUT_DIR}/${ARTIFACT}"
