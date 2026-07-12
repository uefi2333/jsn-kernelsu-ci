#!/usr/bin/env bash
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
KDIR="${ROOT}/kernel"
cd "$KDIR"

export ARCH="${ARCH:-arm64}"
export SUBARCH="${SUBARCH:-arm64}"
export CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
export LOCALVERSION="${LOCALVERSION:--JSN-KSU}"
JOBS="${JOBS:-$(nproc)}"
DEFCONFIG="${DEFCONFIG:-merge_kirin710_defconfig}"

# ccache
if command -v ccache >/dev/null 2>&1; then
  export CROSS_COMPILE="ccache ${CROSS_COMPILE}"
  if [ "${CC:-gcc}" = "clang" ]; then
    export CC="ccache clang"
  else
    export CC="ccache ${CROSS_COMPILE}gcc"
  fi
fi

OUT=out
mkdir -p "$OUT"

echo "[*] make $DEFCONFIG"
# 兼容 configs 在 vendor 子目录
if [ -f "arch/${ARCH}/configs/${DEFCONFIG}" ]; then
  make O="$OUT" "${DEFCONFIG}"
elif [ -f "arch/${ARCH}/configs/vendor/${DEFCONFIG}" ]; then
  make O="$OUT" "vendor/${DEFCONFIG}"
else
  # 已在源码树根写过 .config 的情况
  if [ -f "arch/${ARCH}/configs/${DEFCONFIG}" ] || ls arch/${ARCH}/configs/*"${DEFCONFIG}"* >/dev/null 2>&1; then
    DEFCONFIG_FILE=$(ls arch/${ARCH}/configs/*"${DEFCONFIG}"* | head -n1)
    make O="$OUT" "$(basename "$DEFCONFIG_FILE")"
  else
    echo "[-] defconfig 不存在: $DEFCONFIG"
    ls "arch/${ARCH}/configs" | head
    exit 1
  fi
fi

# 强制打开 KSU（防止 defconfig fragment 被 olddefconfig 吃掉）
CFG="$OUT/.config"
if [ -f "$CFG" ]; then
  scripts/config --file "$CFG" --enable KSU || true
  if [ "${KSU_HOOK:-manual}" = "kprobe" ]; then
    scripts/config --file "$CFG" --enable KPROBES --enable KPROBE_EVENTS --enable MODULES || true
  else
    scripts/config --file "$CFG" --disable KPROBES --disable KPROBE_EVENTS || true
  fi
  make O="$OUT" olddefconfig
fi

echo "[*] building Image (jobs=$JOBS)"
# 华为/海思常见目标
set +e
make O="$OUT" -j"$JOBS" Image.gz-dtb
RC=$?
if [ $RC -ne 0 ]; then
  echo "[*] Image.gz-dtb 失败，试 Image.gz"
  make O="$OUT" -j"$JOBS" Image.gz
  RC=$?
fi
if [ $RC -ne 0 ]; then
  echo "[*] Image.gz 失败，试 Image"
  make O="$OUT" -j"$JOBS" Image
  RC=$?
fi
set -e
if [ $RC -ne 0 ]; then
  echo "[-] 编译失败"
  exit $RC
fi

echo "[+] 编译完成"
find "$OUT/arch/${ARCH}/boot" -maxdepth 1 -type f \( -name 'Image*' -o -name 'Image.gz*' \) -ls || \
find arch/${ARCH}/boot -maxdepth 1 -type f -name 'Image*' -ls
