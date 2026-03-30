#!/usr/bin/env bash
# Copy prebuilt files or directories into BUILD_ROOT at paths expected by other packs
# (e.g. kernel/zImage, uboot/u-boot.bin) so you can skip system/kernel-linux / system/uboot.
#
# Required env:
#   BUILD_ROOT
#   PROJECT_ROOT
#   PACK_ARTIFACTS_JSON   JSON array of artifact objects from resolved artifacts list:
#                         [{"path":"...","source_path":"...","optional":false}, ...]
#     source_path         Path to source file/dir: absolute, or relative to PROJECT_ROOT
#     path                Destination path relative to BUILD_ROOT
#
# Artifacts contract:
#   This script only copies files into BUILD_ROOT. Declared outputs must come from the
#   pack artifacts contract (definitions.yaml defaults and/or top-level pack ref override).

set -euo pipefail

: "${BUILD_ROOT:?BUILD_ROOT required}"
: "${PROJECT_ROOT:?PROJECT_ROOT required}"
: "${PACK_ARTIFACTS_JSON:?PACK_ARTIFACTS_JSON required}"

export BUILD_ROOT PROJECT_ROOT PACK_ARTIFACTS_JSON

exec python3 - <<'PY'
import json
import os
import shutil
from pathlib import Path

build_root = Path(os.environ["BUILD_ROOT"]).resolve()
project_root = Path(os.environ["PROJECT_ROOT"]).resolve()
raw = os.environ["PACK_ARTIFACTS_JSON"]
items = json.loads(raw)
if not isinstance(items, list) or not items:
    raise SystemExit("import/artifacts: PACK_ARTIFACTS_JSON must be a non-empty JSON array")

for i, item in enumerate(items):
    if not isinstance(item, dict):
        raise SystemExit(f"import/artifacts: artifacts[{i}] must be an object")
    src = item.get("source_path")
    artifact = item.get("path")
    if not src or not artifact:
        raise SystemExit(
            f"import/artifacts: artifacts[{i}] needs non-empty 'source_path' and 'path'"
        )
    if isinstance(src, str) and src.startswith("/"):
        src_path = Path(src)
    else:
        src_path = (project_root / str(src)).resolve()

    if not src_path.exists():
        raise SystemExit(f"import/artifacts: source_path does not exist: {src_path}")

    dst_path = (build_root / str(artifact)).resolve()
    try:
        dst_path.relative_to(build_root)
    except ValueError as e:
        raise SystemExit(
            f"import/artifacts: artifact must stay under BUILD_ROOT: {artifact}"
        ) from e

    if src_path.is_dir():
        if dst_path.exists():
            shutil.rmtree(dst_path)
        shutil.copytree(src_path, dst_path, symlinks=True)
        print(f"import/artifacts: dir  {src_path} -> {dst_path}")
    else:
        dst_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src_path, dst_path)
        print(f"import/artifacts: file {src_path} -> {dst_path}")

print("import/artifacts: done")
PY
