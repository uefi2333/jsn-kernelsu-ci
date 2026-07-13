#!/usr/bin/env bash
# SukiSU / KernelSU on Linux 4.9 (Huawei non-GKI) compatibility fixes
set -euo pipefail
ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KSU_DIR=""
if [ -d "$ROOT/kernel/KernelSU/kernel" ]; then
  export KSU_DIR="$ROOT/kernel/KernelSU/kernel"
elif [ -e "$ROOT/kernel/drivers/kernelsu" ]; then
  export KSU_DIR="$(readlink -f "$ROOT/kernel/drivers/kernelsu" 2>/dev/null || true)"
  if [ -z "${KSU_DIR:-}" ] || [ ! -d "${KSU_DIR:-}" ]; then
    export KSU_DIR="$ROOT/kernel/drivers/kernelsu"
  fi
fi
python3 "$SCRIPT_DIR/patch_sukisu_4_9.py"
