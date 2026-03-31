#!/usr/bin/env bash
# Build an application. Runs CMD from dependency staging destination.
# Env: BUILD_ROOT, PROJECT_ROOT, CMD, PACK_DEPENDENCIES_JSON
# Board (target) env from boards/{target}/definitions.yaml:
#   Go:   BOARD_ARCH, BOARD_GO_OS, BOARD_GO_ARCH → GOOS, GOARCH
#   C:    BOARD_CC, BOARD_CROSS_COMPILE, BOARD_AR → CC, CROSS_COMPILE, AR
#   C++:  BOARD_CXX (e.g. aarch64-linux-gnu-g++), BOARD_CXXFLAGS → CXX, CXXFLAGS
#   Rust: BOARD_RUST_TARGET (e.g. aarch64-unknown-linux-gnu) or derived from BOARD_ARCH → RUST_TARGET
#   CGO:  BOARD_CGO_ENABLED (optional override when cross-compiling Go with C code).

set -e

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing '$1' in PATH"; exit 1; }; }

ensure_path_entry() {
  case ":${PATH}:" in
    *":$1:"*) ;;
    *) export PATH="${PATH}:$1" ;;
  esac
}

ensure_path_entry "/opt/toolchains/aarch64-linux-musl/bin"
ensure_path_entry "/opt/toolchains/arm-linux-musleabihf/bin"
need arm-linux-musleabihf-gcc

: "${BUILD_ROOT:?BUILD_ROOT required}"
: "${PROJECT_ROOT:?PROJECT_ROOT required}"
: "${CMD:?CMD required}"
: "${PACK_DEPENDENCIES_JSON:?PACK_DEPENDENCIES_JSON required}"

need jq

# Pick the source dependency destination:
# - prefer dependency named "src"
# - otherwise use the first dependency with a non-empty dest
APP_DEST="$(jq -r '
  (map(select((.name // "") == "src" and (.dest // "") != "")) | .[0].dest) //
  (map(select((.dest // "") != "")) | .[0].dest) //
  empty
' <<< "${PACK_DEPENDENCIES_JSON}")"

if [[ -z "${APP_DEST}" || "${APP_DEST}" == "null" ]]; then
  echo "Could not determine app source from PACK_DEPENDENCIES_JSON (missing dependency dest)"
  exit 1
fi

if [[ "${APP_DEST}" == /* ]]; then
  BUILD_SRC="${APP_DEST}"
else
  BUILD_SRC="${BUILD_ROOT}/${APP_DEST}"
fi

if [[ ! -d "${BUILD_SRC}" ]]; then
  echo "App source not found at dependency destination: ${BUILD_SRC}"
  exit 1
fi

cd "${BUILD_SRC}"

# Cross-compile for target when BOARD_* indicate a target arch (from boards/{target}/definitions.yaml).
# BOARD_GO_OS / BOARD_GO_ARCH override; otherwise derive from BOARD_ARCH (e.g. arm64 -> linux/arm64).
if [[ -n "${BOARD_GO_OS:-}" ]]; then
  export GOOS="${BOARD_GO_OS}"
fi
if [[ -n "${BOARD_GO_ARCH:-}" ]]; then
  export GOARCH="${BOARD_GO_ARCH}"
elif [[ -n "${BOARD_ARCH:-}" ]]; then
  case "${BOARD_ARCH}" in
    arm64) export GOOS="${GOOS:-linux}"; export GOARCH=arm64 ;;
    arm)   export GOOS="${GOOS:-linux}"; export GOARCH=arm ;;
    *)     echo "WARNING: BOARD_ARCH=${BOARD_ARCH} has no Go GOARCH mapping, building native" >&2 ;;
  esac
fi
# Default GOOS to linux when cross-compiling for embedded if only GOARCH was set.
if [[ -n "${GOARCH:-}" ]] && [[ -z "${GOOS:-}" ]]; then
  export GOOS=linux
fi
if [[ -n "${GOOS:-}" ]] || [[ -n "${GOARCH:-}" ]]; then
  # When BOARD_CC is set, allow CGO (Go + C); otherwise default CGO_ENABLED=0 for pure Go cross-compile.
  export CGO_ENABLED="${BOARD_CGO_ENABLED:-${BOARD_CC:+1}}"
  if [[ -z "${CGO_ENABLED}" ]]; then
    export CGO_ENABLED=0
  fi
  echo "Cross-compiling: GOOS=${GOOS:-<unset>} GOARCH=${GOARCH:-<unset>} CGO_ENABLED=${CGO_ENABLED}"
fi

# C cross-compiler: make and most Makefiles use CC (and optionally CROSS_COMPILE, AR).
if [[ -n "${BOARD_CC:-}" ]]; then
  export CC="${BOARD_CC}"
  echo "C compiler: CC=${CC}"
fi
if [[ -n "${BOARD_CROSS_COMPILE:-}" ]]; then
  export CROSS_COMPILE="${BOARD_CROSS_COMPILE}"
  echo "C cross-compile prefix: CROSS_COMPILE=${CROSS_COMPILE}"
fi
if [[ -n "${BOARD_AR:-}" ]]; then
  export AR="${BOARD_AR}"
  echo "C archiver: AR=${AR}"
fi

# C++ cross-compiler: make and CMake use CXX (and optionally CXXFLAGS).
if [[ -n "${BOARD_CXX:-}" ]]; then
  export CXX="${BOARD_CXX}"
  echo "C++ compiler: CXX=${CXX}"
fi
if [[ -n "${BOARD_CXXFLAGS:-}" ]]; then
  export CXXFLAGS="${BOARD_CXXFLAGS}"
  echo "C++ flags: CXXFLAGS=${CXXFLAGS}"
fi

# Rust cross-compile target: use in `cargo build --target "${RUST_TARGET}"`.
# BOARD_RUST_TARGET overrides; otherwise derive from BOARD_ARCH (e.g. arm64 → aarch64-unknown-linux-gnu).
if [[ -n "${BOARD_RUST_TARGET:-}" ]]; then
  export RUST_TARGET="${BOARD_RUST_TARGET}"
elif [[ -n "${BOARD_ARCH:-}" ]]; then
  case "${BOARD_ARCH}" in
    arm64) export RUST_TARGET=aarch64-unknown-linux-gnu ;;
    arm)   export RUST_TARGET=armv7-unknown-linux-gnueabihf ;;
    *)     ;;
  esac
fi
if [[ -n "${RUST_TARGET:-}" ]]; then
  echo "Rust target: RUST_TARGET=${RUST_TARGET}"
fi

eval "${CMD}"
echo "Build path: ${BUILD_SRC}"
