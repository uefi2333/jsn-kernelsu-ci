#!/usr/bin/env bash
# 植入 KernelSU / KernelSU-Next / RKSU
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
KDIR="${ROOT}/kernel"
cd "$KDIR"

if [ "${SKIP_KSU_SETUP:-false}" = "true" ]; then
  echo "[*] SKIP_KSU_SETUP=true，跳过 setup"
  exit 0
fi

# 若源码已带 KernelSU 目录，先备份/清掉再装指定版本，避免混版本
if [ -d KernelSU ] || [ -d kernelsu ]; then
  echo "[*] 源码已有 KernelSU 目录，重装指定版本前先移除"
  rm -rf KernelSU kernelsu
fi

FLAVOR="${KSU_FLAVOR:-kernelsu}"
VER="${KSU_VERSION:-v0.9.5}"

echo "[*] KSU flavor=$FLAVOR version=$VER hook=${KSU_HOOK:-manual}"

case "$FLAVOR" in
  kernelsu)
    # 官方：非 GKI 必须钉 v0.9.5，禁止拉 main
    if [[ "$VER" == main || "$VER" == master ]]; then
      echo "[!] 官方 KernelSU main 已弃非 GKI，强制改用 v0.9.5"
      VER="v0.9.5"
    fi
    curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -s "$VER"
    ;;
  kernelsu-next)
    # Next 仍维护非 GKI；tag 可用 next / 具体版本
    curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -s "${VER:-next}"
    ;;
  rksu)
    # rsuntk 分支，对 <5.x 更友好
    curl -LSs "https://raw.githubusercontent.com/rsuntk/KernelSU/main/kernel/setup.sh" | bash -s "${VER:-main}"
    ;;
  *)
    echo "[-] 未知 KSU_FLAVOR: $FLAVOR"
    exit 1
    ;;
esac

# 确认驱动目录存在
if [ ! -d KernelSU/kernel ] && [ ! -d drivers/kernelsu ] && ! grep -Rqs "CONFIG_KSU" KernelSU 2>/dev/null; then
  echo "[-] setup 后未找到 KernelSU 驱动，检查网络/URL"
  ls -la
  exit 1
fi

echo "[+] KernelSU 植入完成"
ls -la KernelSU 2>/dev/null || true
