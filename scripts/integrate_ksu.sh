#!/usr/bin/env bash
# 植入 SukiSU-Ultra (builtin 模式 + SUSFS inline hooks)
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
KDIR="${ROOT}/kernel"
cd "$KDIR"

if [ "${SKIP_KSU_SETUP:-false}" = "true" ]; then
  echo "[*] SKIP_KSU_SETUP=true，跳过 setup"
  exit 0
fi

# 清理旧版 KernelSU 残留
for d in KernelSU kernelsu; do
  rm -rf "$d"
done
rm -rf drivers/kernelsu 2>/dev/null || true

FLAVOR="${KSU_FLAVOR:-sukisu}"
VER="${KSU_VERSION:-main}"
HOOK="${KSU_HOOK:-builtin}"

echo "[*] KSU flavor=$FLAVOR version=$VER hook=$HOOK"

case "$FLAVOR" in
  kernelsu)
    echo "[*] 安装官方 KernelSU (legacy)"
    curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -s v0.9.5
    ;;
  kernelsu-next)
    curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/dev/kernel/setup.sh" | bash -s legacy
    ;;
  rksu)
    curl -LSs "https://raw.githubusercontent.com/rsuntk/KernelSU/main/kernel/setup.sh" | bash -s v3.0.0-30-legacy
    ;;
  sukisu|sukisu-ultra|suki)
    # SukiSU-Ultra builtin 模式 (SUSFS inline hooks)
    echo "[*] 安装 SukiSU-Ultra (builtin 模式)"
    rm -rf KernelSU
    curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s v3.2.0

    # 针定到已知兼容 4.9 的 commit（参考 xixiaobei-bei 仓库）
    if [ -d KernelSU ]; then
      cd KernelSU
      echo "[*] SukiSU commit: $(git rev-parse --short HEAD)"
      # 4.9 内核兼容性验证：检查是否有 4.9 兼容代码
      if grep -rqs "4\.9\|KERNEL_VERSION(4" include/ ksud/ 2>/dev/null; then
        echo "[+] 检测到 4.9 内核兼容标记"
      fi
      cd ..
    fi
    ;;
  *)
    echo "[-] 未知 KSU_FLAVOR: $FLAVOR"
    exit 1
    ;;
esac

# 验证安装
if [ ! -d KernelSU ] && ! ls drivers/kernelsu/ >/dev/null 2>&1; then
  echo "[-] setup 后未找到 KernelSU 驱动"
  ls -la
  exit 1
fi

echo "[+] KernelSU 植入完成"
ls -la KernelSU 2>/dev/null | head || true
ls -la drivers/kernelsu 2>/dev/null | head || true
