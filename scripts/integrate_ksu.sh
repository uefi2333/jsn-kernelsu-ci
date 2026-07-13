#!/usr/bin/env bash
# 植入 KernelSU / KernelSU-Next / RKSU / SukiSU-Ultra
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
KDIR="${ROOT}/kernel"
cd "$KDIR"

if [ "${SKIP_KSU_SETUP:-false}" = "true" ]; then
  echo "[*] SKIP_KSU_SETUP=true，跳过 setup"
  exit 0
fi

# 若源码已带 KernelSU 目录/子模块，先清掉再装指定版本
if [ -d KernelSU ] || [ -d kernelsu ] || [ -e KernelSU ]; then
  echo "[*] 源码已有 KernelSU，重装前先移除"
  rm -rf KernelSU kernelsu
fi
# 清掉可能残留的 drivers/kernelsu 链接
if [ -L drivers/kernelsu ] || [ -d drivers/kernelsu ]; then
  rm -rf drivers/kernelsu
fi

FLAVOR="${KSU_FLAVOR:-sukisu}"
VER="${KSU_VERSION:-v3.2.0}"

echo "[*] KSU flavor=$FLAVOR version=$VER hook=${KSU_HOOK:-manual}"

case "$FLAVOR" in
  kernelsu)
    if [[ "$VER" == main || "$VER" == master ]]; then
      echo "[!] 官方 KernelSU main 已弃非 GKI，强制改用 v0.9.5"
      VER="v0.9.5"
    fi
    curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -s "$VER"
    ;;
  kernelsu-next)
    curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -s "${VER:-next}"
    ;;
  rksu)
    curl -LSs "https://raw.githubusercontent.com/rsuntk/KernelSU/main/kernel/setup.sh" | bash -s "${VER:-main}"
    ;;
  sukisu|sukisu-ultra|suki)
    # SukiSU-Ultra：4.9 非GKI 建议 v3.2.0 + manual hook
    if [[ "$VER" == main || "$VER" == master ]]; then
      echo "[!] SukiSU main/v4 对 4.9 风险高，强制改用 v3.2.0"
      VER="v3.2.0"
    fi
    # 优先用对应 tag 的 setup.sh，失败回退 main
    if ! curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/${VER}/kernel/setup.sh" | bash -s "$VER"; then
      echo "[*] tag setup 失败，回退 main setup.sh"
      curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s "$VER"
    fi
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
  ls -la drivers 2>/dev/null | head || true
  exit 1
fi

echo "[+] KernelSU/SukiSU 植入完成"
ls -la KernelSU 2>/dev/null | head || true
ls -la drivers/kernelsu 2>/dev/null | head || true

# 4.9 兼容在 workflow 下一步 patch_sukisu_4.9.sh 处理

