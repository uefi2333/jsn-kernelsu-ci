#!/usr/bin/env bash
# KPM (Kernel Patch Module) 编译后修补
# 下载 SukiSU-KernelPatch_patch 的 patch_linux 工具，修补编译好的 Image
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
KDIR="${ROOT}/kernel"

if [ "${ENABLE_KPM:-false}" != "true" ]; then
  echo "[*] ENABLE_KPM=false, 跳过 KPM 修补"
  exit 0
fi

echo "[*] KPM: 检查 .config 中 CONFIG_KPM ..."
CFG="$KDIR/out/.config"
if [ ! -f "$CFG" ]; then
  echo "[-] .config 不存在: $CFG"
  exit 1
fi

if ! grep -q "^CONFIG_KPM=y" "$CFG"; then
  echo "[*] CONFIG_KPM 未启用，跳过 KPM 修补"
  exit 0
fi

echo "[+] CONFIG_KPM=y 已启用，开始 KPM 修补"

# 下载 patch_linux
KPM_VERSION="0.13.0"
KPM_URL="https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/${KPM_VERSION}/patch_linux"
BOOT_DIR="$KDIR/out/arch/arm64/boot"

cd "$BOOT_DIR"
echo "[*] 下载 patch_linux (v${KPM_VERSION})..."
wget -q -O patch_linux "$KPM_URL" || {
  echo "[-] 下载 patch_linux 失败，尝试 v0.12.5..."
  KPM_VERSION="0.12.5"
  wget -q -O patch_linux "https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/${KPM_VERSION}/patch_linux"
}
chmod +x patch_linux

echo "[*] 运行 patch_linux 修补内核 Image..."
./patch_linux

# 检查结果
if [ -f "oImage" ]; then
  echo "[+] patch_linux 生成了 oImage，替换原 Image"
  rm -f Image.gz
  mv -f oImage Image
fi

# 重新压缩为 Image.gz
if [ -f "Image" ]; then
  echo "[*] 重新压缩 Image -> Image.gz"
  gzip -k -f Image Image.gz
  echo "[+] KPM 修补完成"
  ls -lh Image Image.gz 2>/dev/null
else
  echo "[-] patch_linux 未生成 Image，检查输出"
  ls -la
  exit 1
fi
