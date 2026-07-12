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
USE_CCACHE="${USE_CCACHE:-0}"

# 清理错误的 ccache 前缀（防止 CROSS_COMPILE 被包成 "ccache /path/"）
CROSS_COMPILE="${CROSS_COMPILE#ccache }"
CROSS_COMPILE="${CROSS_COMPILE// /}"

# 校验交叉编译器真实存在
GCC_BIN="${CROSS_COMPILE}gcc"
if [ ! -f "$GCC_BIN" ] && ! command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1; then
  echo "[-] CROSS_COMPILE gcc 不存在: $GCC_BIN"
  echo "    CROSS_COMPILE=$CROSS_COMPILE"
  echo "    PATH=$PATH"
  exit 1
fi

if command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1; then
  echo "[*] compiler: $("${CROSS_COMPILE}gcc" --version | head -n1)"
else
  echo "[*] compiler: $($GCC_BIN --version | head -n1)"
fi

# ccache：用 CC/CXX 包一层，绝不污染 CROSS_COMPILE 路径
if [ "$USE_CCACHE" = "1" ] && command -v ccache >/dev/null 2>&1; then
  export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
  export CC="ccache ${CROSS_COMPILE}gcc"
  export CXX="ccache ${CROSS_COMPILE}g++"
  if [ "${CC_REAL:-}" = "clang" ] || [ "${CC_LANG:-gcc}" = "clang" ]; then
    export CC="ccache clang"
  fi
  echo "[*] ccache enabled"
else
  # 默认关掉 ccache，老 gcc-4.9 在 runner 上更稳
  export CC="${CROSS_COMPILE}gcc"
  echo "[*] ccache disabled (USE_CCACHE=$USE_CCACHE)"
fi

export CROSS_COMPILE
export ARCH SUBARCH LOCALVERSION

OUT=out
mkdir -p "$OUT"

# 华为源常见脏状态
rm -rf include/config 2>/dev/null || true

echo "[*] make $DEFCONFIG"
if [ -f "arch/${ARCH}/configs/${DEFCONFIG}" ]; then
  make O="$OUT" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" "${DEFCONFIG}"
elif [ -f "arch/${ARCH}/configs/vendor/${DEFCONFIG}" ]; then
  make O="$OUT" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" "vendor/${DEFCONFIG}"
else
  if ls arch/${ARCH}/configs/*"${DEFCONFIG}"* >/dev/null 2>&1; then
    DEFCONFIG_FILE=$(ls arch/${ARCH}/configs/*"${DEFCONFIG}"* | head -n1)
    make O="$OUT" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" "$(basename "$DEFCONFIG_FILE")"
  else
    echo "[-] defconfig 不存在: $DEFCONFIG"
    ls "arch/${ARCH}/configs" | head
    exit 1
  fi
fi

# 强制打开 KSU
CFG="$OUT/.config"
if [ -f "$CFG" ]; then
  scripts/config --file "$CFG" --enable KSU || true
  if [ "${KSU_HOOK:-manual}" = "kprobe" ]; then
    scripts/config --file "$CFG" --enable KPROBES --enable KPROBE_EVENTS --enable MODULES || true
  else
    scripts/config --file "$CFG" --disable KPROBES --disable KPROBE_EVENTS || true
  fi
  # 老工具链若 stack-protector-strong 不可用，降级避免 prepare-compiler-check 直接炸
  if ! ${CROSS_COMPILE}gcc -fstack-protector-strong -E -x c /dev/null -o /dev/null 2>/dev/null; then
    echo "[*] gcc 不支持 -fstack-protector-strong，关闭 CONFIG_CC_STACKPROTECTOR_STRONG"
    scripts/config --file "$CFG" --disable CC_STACKPROTECTOR_STRONG || true
    scripts/config --file "$CFG" --enable CC_STACKPROTECTOR_REGULAR || true
  fi
  make O="$OUT" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
fi

echo "[*] building Image (jobs=$JOBS)"
set +e
make O="$OUT" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" CC="$CC" -j"$JOBS" Image.gz-dtb
RC=$?
if [ $RC -ne 0 ]; then
  echo "[*] Image.gz-dtb 失败，试 Image.gz"
  make O="$OUT" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" CC="$CC" -j"$JOBS" Image.gz
  RC=$?
fi
if [ $RC -ne 0 ]; then
  echo "[*] Image.gz 失败，试 Image"
  make O="$OUT" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" CC="$CC" -j"$JOBS" Image
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
