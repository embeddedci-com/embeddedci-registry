#!/usr/bin/env bash
# Yocto image build via Kas (https://kas.readthedocs.io/).
#
# Kas project checkout: engine `fetch` (definitions dependencies) clones `source` into
# BUILD_ROOT/kas_config_src; env KAS_CONFIG_SRC points at that tree after URL→path replacement.
#
# Configuration (merged into env by the engine):
#   SOURCE            Git URL from pack config (may be rewritten to KAS_CONFIG_SRC path when it matched fetch)
#   KAS_CONFIG_SRC    Directory containing kas.yml (from definitions config template)
#   KAS_FILE          Kas manifest filename (default kas.yml)
#   PACK_ARTIFACTS_JSON
#                     JSON array of artifact objects from resolved artifacts list:
#                     [{"name":"...","path":"...","source_path":"...","optional":false}, ...]
#                     This script resolves each artifact object's `path` under
#                     tmp/deploy. A leading tmp/deploy/ component is accepted
#                     because `path` is also the logical published path.
#
# Paths:
#   BUILD_ROOT, YOCTO_SSTATE_DIR, YOCTO_DL_DIR — see definitions.yaml
#   YOCTO_GIT_MIRROR_LIST (optional; default /cache/git-mirror-list.txt)
#     Lines: upstream_git_url|/absolute/path/to/bare/mirror.git (see delimiter note in that file).
#     When present and non-empty, BitBake uses explicit PREMIRRORS to local bare repos, plus
#     BB_FETCH_PREMIRRORONLY=1 and BB_NO_NETWORK=1 (no own-mirrors / SOURCE_MIRROR_URL).
#
# Required on PATH: cp, dirname, find, head, jq, mkdir, rm, python3 (+ venv), git.

set -euo pipefail

need() {
  local x
  for x in "$@"; do
    command -v "$x" >/dev/null 2>&1 || {
      echo "yocto-image: required command not found: ${x}" >&2
      exit 1
    }
  done
}

BUILD_ROOT="${BUILD_ROOT:-/build}"
BUILD_ROOT="${BUILD_ROOT%/}"

# Host tools this script uses; kas/bitbake will also invoke git.
need cp dirname find head jq mkdir rm python3 git
python3 -m venv -h >/dev/null 2>&1 || {
  echo "yocto-image: need python3 venv support (e.g. apt install python3-venv)" >&2
  exit 1
}

# BitBake sanity checks require en_US.UTF-8 to be available.
# This script only verifies; the Firecracker/container image should provision it.
if ! python3 -c "import locale; locale.setlocale(locale.LC_ALL, 'en_US.UTF-8')" >/dev/null 2>&1; then
  echo "yocto-image: missing required locale en_US.UTF-8 (bake it into the image)" >&2
  exit 1
fi
export LANG=en_US.UTF-8
export LANGUAGE=en_US:en
export LC_ALL=en_US.UTF-8

locale
env | grep -E '^(LANG|LANGUAGE|LC_)'

yocto_resolve_path() {
  local p="${1:-}"
  [[ -z "${p}" ]] && return 0
  if [[ "${p}" = /* ]]; then
    echo "${p}"
  else
    p="${p#/}"
    echo "${BUILD_ROOT}/${p}"
  fi
}

# Keep Python/pip caches in writable build storage.
YOCTO_CACHE_DIR="$(yocto_resolve_path "${YOCTO_CACHE_DIR:-.cache}")"
export XDG_CACHE_HOME="${YOCTO_CACHE_DIR}"
export PIP_CACHE_DIR="${YOCTO_CACHE_DIR}/pip"
mkdir -p "${XDG_CACHE_HOME}" "${PIP_CACHE_DIR}"

# Local bare git mirrors: map each upstream URL from YOCTO_GIT_MIRROR_LIST to git:///path
# (PREMIRRORS replacement), not SOURCE_MIRROR_URL tarball layout (own-mirrors).
yocto_trim() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

YOCTO_GIT_MIRROR_LIST="${YOCTO_GIT_MIRROR_LIST:-/cache/git-mirror-list.txt}"
PREMIRRORS_BUILD=""
if [[ -f "${YOCTO_GIT_MIRROR_LIST}" ]]; then
  while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
    line="${raw_line%%#*}"
    line="$(yocto_trim "${line}")"
    [[ -z "${line}" ]] && continue
    [[ "${line}" != *"|"* ]] && continue
    upstream="$(yocto_trim "${line%%|*}")"
    local_path="$(yocto_trim "${line#*|}")"
    [[ -z "${upstream}" || -z "${local_path}" ]] && continue
    [[ "${local_path}" != /* ]] && {
      echo "yocto-image: skip mirror entry (local path must be absolute): ${raw_line}" >&2
      continue
    }
    replacement="git://${local_path}"
    # BitBake matches SRC_URI scheme; emit both https and git forms when upstream is https.
    PREMIRRORS_BUILD+="${upstream}  ${replacement}"$'\n'
    if [[ "${upstream}" == https://* ]]; then
      git_form="git://${upstream#https://}"
      PREMIRRORS_BUILD+="${git_form}  ${replacement}"$'\n'
    elif [[ "${upstream}" == git://* ]]; then
      https_form="https://${upstream#git://}"
      PREMIRRORS_BUILD+="${https_form}  ${replacement}"$'\n'
    fi
  done < "${YOCTO_GIT_MIRROR_LIST}"
fi

if [[ -n "${PREMIRRORS_BUILD}" ]]; then
  export PREMIRRORS="${PREMIRRORS_BUILD}"
  export BB_FETCH_PREMIRRORONLY="1"
  export BB_NO_NETWORK="1"
  export BB_ENV_PASSTHROUGH_ADDITIONS="${BB_ENV_PASSTHROUGH_ADDITIONS:-} PREMIRRORS BB_FETCH_PREMIRRORONLY BB_NO_NETWORK"
  echo "yocto-image: PREMIRRORS + premirror-only + no-network from ${YOCTO_GIT_MIRROR_LIST}"
  # After env is active in the build tree: bitbake -e <recipe> | egrep '^(INHERIT|SOURCE_MIRROR_URL|PREMIRRORS|BB_FETCH_PREMIRRORONLY|BB_NO_NETWORK)='
else
  [[ -f "${YOCTO_GIT_MIRROR_LIST}" ]] &&
    echo "yocto-image: ${YOCTO_GIT_MIRROR_LIST} has no usable entries; network fetch unchanged" >&2
fi

KAS_WORK="${KAS_CONFIG_SRC:-}"
if [[ -z "${KAS_WORK}" || ! -d "${KAS_WORK}" ]]; then
  echo "yocto-image: KAS_CONFIG_SRC must be set to the fetched kas config directory (engine fetch + prepareInputs)" >&2
  exit 1
fi

KAS_YML_NAME="${KAS_FILE:-kas.yml}"
KAS_YML="${KAS_WORK}/${KAS_YML_NAME}"
if [[ ! -f "${KAS_YML}" ]]; then
  echo "yocto-image: kas file not found: ${KAS_YML}" >&2
  exit 1
fi

KAS_VENV_DIR="$(yocto_resolve_path "${YOCTO_KAS_VENV_DIR:-.venv/yocto-kas}")"
KAS_VENV_BIN="${KAS_VENV_DIR}/bin"
KAS_BIN="${KAS_VENV_BIN}/kas"

if [[ ! -x "${KAS_BIN}" ]]; then
  echo "yocto-image: creating kas venv at ${KAS_VENV_DIR}"
  mkdir -p "$(dirname "${KAS_VENV_DIR}")"
  python3 -m venv "${KAS_VENV_DIR}"
  "${KAS_VENV_BIN}/python" -m pip install --quiet --upgrade pip
  "${KAS_VENV_BIN}/python" -m pip install --quiet kas
fi

SSTATE_DIR="$(yocto_resolve_path "${YOCTO_SSTATE_DIR:-yocto/sstate}")"
DL_DIR="$(yocto_resolve_path "${YOCTO_DL_DIR:-yocto/downloads}")"
export SSTATE_DIR DL_DIR
mkdir -p "${SSTATE_DIR}" "${DL_DIR}"
echo "yocto-image: KAS_WORK=${KAS_WORK} SSTATE_DIR=${SSTATE_DIR} DL_DIR=${DL_DIR}"

echo "yocto-image: kas build ${KAS_YML_NAME} in ${KAS_WORK}"
(
  cd "${KAS_WORK}"
  "${KAS_BIN}" build "${KAS_YML_NAME}"
)

yocto_bitbake_var() {
  local var="${1}"
  (
    cd "${KAS_WORK}"
    "${KAS_BIN}" shell -k "${KAS_YML_NAME}" -c "bitbake -e | sed -n 's/^${var}=\"\\(.*\\)\"$/\\1/p' | tail -1"
  ) 2>/dev/null | tail -1 || true
}

deploy_image_dir="$(yocto_bitbake_var DEPLOY_DIR_IMAGE)"
deploy_root="$(
  find "${KAS_WORK}" -type d -path '*/tmp/deploy' 2>/dev/null |
    while IFS= read -r candidate; do
      if [[ -d "${candidate}/images" ]]; then
        printf '%s\n' "${candidate}"
        break
      fi
    done
)"
if [[ -n "${deploy_image_dir}" ]]; then
  echo "yocto-image: DEPLOY_DIR_IMAGE=${deploy_image_dir}"
  if [[ -d "${deploy_image_dir}" ]]; then
    deploy_root="$(dirname "$(dirname "${deploy_image_dir}")")"
  fi
fi
if [[ -z "${deploy_root}" ]]; then
  deploy_root="$(find "${KAS_WORK}" -type d -path '*/tmp/deploy' 2>/dev/null | head -1 || true)"
fi
if [[ -z "${deploy_root}" ]]; then
  echo "yocto-image: could not find */tmp/deploy under ${KAS_WORK}" >&2
  exit 1
fi
echo "yocto-image: deploy root ${deploy_root}"

yocto_list_dir() {
  local label="${1}"
  local dir="${2}"
  echo "yocto-image: ${label}: ${dir}" >&2
  if [[ ! -d "${dir}" ]]; then
    echo "yocto-image: ${label}: not a directory" >&2
    return 0
  fi
  find "${dir}" -maxdepth 2 -mindepth 1 -printf 'yocto-image:   %y %p\n' 2>/dev/null | head -50 >&2 || true
}

yocto_find_image_candidates() {
  echo "yocto-image: deploy roots under KAS_WORK:" >&2
  find "${KAS_WORK}" -type d -path '*/tmp/deploy' -printf 'yocto-image:   %p\n' 2>/dev/null | head -20 >&2 || true
  echo "yocto-image: deploy image directories under KAS_WORK:" >&2
  find "${KAS_WORK}" -type d -path '*/deploy/images*' -printf 'yocto-image:   %p\n' 2>/dev/null | head -50 >&2 || true
  echo "yocto-image: likely image files under KAS_WORK:" >&2
  find "${KAS_WORK}" -type f \( \
    -name '*.wic' -o -name '*.wic.*' -o \
    -name '*.ext2' -o -name '*.ext3' -o -name '*.ext4' -o -name '*.ext4.*' -o \
    -name '*.tar' -o -name '*.tar.*' -o \
    -name '*core-image*' \
  \) -printf 'yocto-image:   %p\n' 2>/dev/null | head -100 >&2 || true
}

if [[ -z "${PACK_ARTIFACTS_JSON:-}" ]]; then
  echo "yocto-image: PACK_ARTIFACTS_JSON must be set (JSON array of artifact objects)" >&2
  exit 1
fi
if ! jq -e 'type == "array" and length > 0' <<<"${PACK_ARTIFACTS_JSON}" >/dev/null 2>&1; then
  echo "yocto-image: PACK_ARTIFACTS_JSON must be a non-empty JSON array" >&2
  exit 1
fi

while IFS= read -r rel; do
  [[ -z "${rel}" ]] && continue
  deploy_rel="${rel#/}"
  deploy_rel="${deploy_rel#tmp/deploy/}"
  src="${deploy_root}/${deploy_rel}"
  if [[ ! -e "${src}" ]]; then
    echo "yocto-image: missing artifact" >&2
    echo "yocto-image:   declared path: ${rel}" >&2
    echo "yocto-image:   deploy-relative path: ${deploy_rel}" >&2
    echo "yocto-image:   deploy root: ${deploy_root}" >&2
    echo "yocto-image:   expected source: ${src}" >&2
    if [[ "${deploy_rel}" == images/* && ! -d "${deploy_root}/images" ]]; then
      echo "yocto-image:   note: ${deploy_root}/images does not exist; the Yocto build completed without deployable image outputs" >&2
      echo "yocto-image:   hint: set IMAGE_FSTYPES in the kas local_conf_header or adjust the artifact path to an output that is actually produced" >&2
    fi
    yocto_list_dir "deploy root listing" "${deploy_root}"
    yocto_list_dir "deploy images listing" "${deploy_root}/images"
    yocto_list_dir "expected parent listing" "$(dirname "${src}")"
    yocto_find_image_candidates
    exit 1
  fi
  dst="${BUILD_ROOT}/${rel#/}"
  rm -rf "${dst}"
  mkdir -p "$(dirname "${dst}")"
  if mv "${src}" "${dst}"; then
    echo "yocto-image: moved ${rel}"
  else
    cp -a "${src}" "${dst}"
    echo "yocto-image: staged ${rel}"
  fi
done < <(jq -r '.[] | select(type == "object") | .path // empty' <<< "${PACK_ARTIFACTS_JSON}")

echo "yocto-image: done"
