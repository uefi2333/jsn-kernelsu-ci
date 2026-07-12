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

# 清理错误的 ccache 前缀
CROSS_COMPILE="${CROSS_COMPILE#ccache }"
CROSS_COMPILE="${CROSS_COMPILE// /}"

# 校验交叉编译器
if ! command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1 && [ ! -x "${CROSS_COMPILE}gcc" ]; then
  echo "[-] CROSS_COMPILE gcc 不存在: ${CROSS_COMPILE}gcc"
  echo "    CROSS_COMPILE=$CROSS_COMPILE"
  echo "    PATH=$PATH"
  exit 1
fi
echo "[*] compiler: $("${CROSS_COMPILE}gcc" --version | head -n1)"

# 目标 CC：只用交叉编译器；host 工具强制系统 gcc
if [ "$USE_CCACHE" = "1" ] && command -v ccache >/dev/null 2>&1; then
  export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
  TARGET_CC="ccache ${CROSS_COMPILE}gcc"
  echo "[*] ccache enabled"
else
  TARGET_CC="${CROSS_COMPILE}gcc"
  echo "[*] ccache disabled (USE_CCACHE=$USE_CCACHE)"
fi

# ------------------------------------------------------------
# 老内核 + 新 GCC 兼容补丁
# 1) dtc: multiple definition of yylloc (GCC 10+ 默认 -fno-common)
# 2) HOSTCFLAGS=-fcommon / allow-multiple-definition
# ------------------------------------------------------------
fix_yylloc() {
  local f
  for f in \
    scripts/dtc/dtc-lexer.l \
    scripts/dtc/dtc-lexer.lex.c \
    scripts/dtc/dtc-lexer.lex.c_shipped \
    scripts/dtc/dtc-parser.tab.c \
    scripts/dtc/dtc-parser.tab.c_shipped
  do
    if [ -f "$f" ]; then
      # 只改定义，不改声明
      sed -i -E 's/^YYLTYPE[[:space:]]+yylloc;/extern YYLTYPE yylloc;/' "$f" || true
      sed -i -E 's/^YYLTYPE[[:space:]]+yylloc[[:space:]]*=/extern YYLTYPE yylloc; \/* patched *\//;' "$f" || true
    fi
  done
  echo "[*] yylloc host-tool patch applied (if sources present)"
}

fix_yylloc

# 华为源常见脏状态
rm -rf include/config 2>/dev/null || true

# host 侧：Ubuntu 22.04 的 gcc-11/12 必须开 -fcommon
export HOSTCC="${HOSTCC:-gcc}"
export HOSTCXX="${HOSTCXX:-g++}"
export HOSTCFLAGS="${HOSTCFLAGS:--fcommon -Wno-error}"
export HOSTCXXFLAGS="${HOSTCXXFLAGS:--fcommon -Wno-error}"
export HOSTLDFLAGS="${HOSTLDFLAGS:--Wl,--allow-multiple-definition}"

# 部分老脚本读 CC 当 host cc；明确拆开
export CC="$TARGET_CC"
export CROSS_COMPILE ARCH SUBARCH LOCALVERSION

OUT=out
mkdir -p "$OUT"

MAKE_COMMON=(
  O="$OUT"
  ARCH="$ARCH"
  CROSS_COMPILE="$CROSS_COMPILE"
  CC="$TARGET_CC"
  HOSTCC="$HOSTCC"
  HOSTCXX="$HOSTCXX"
  HOSTCFLAGS="$HOSTCFLAGS"
  HOSTCXXFLAGS="$HOSTCXXFLAGS"
  HOSTLDFLAGS="$HOSTLDFLAGS"
)

echo "[*] make $DEFCONFIG"
if [ -f "arch/${ARCH}/configs/${DEFCONFIG}" ]; then
  make "${MAKE_COMMON[@]}" "${DEFCONFIG}"
elif [ -f "arch/${ARCH}/configs/vendor/${DEFCONFIG}" ]; then
  make "${MAKE_COMMON[@]}" "vendor/${DEFCONFIG}"
else
  if ls arch/${ARCH}/configs/*"${DEFCONFIG}"* >/dev/null 2>&1; then
    DEFCONFIG_FILE=$(ls arch/${ARCH}/configs/*"${DEFCONFIG}"* | head -n1)
    make "${MAKE_COMMON[@]}" "$(basename "$DEFCONFIG_FILE")"
  else
    echo "[-] defconfig 不存在: $DEFCONFIG"
    ls "arch/${ARCH}/configs" | head
    exit 1
  fi
fi

CFG="$OUT/.config"
if [ -f "$CFG" ]; then
  scripts/config --file "$CFG" --enable KSU || true
  if [ "${KSU_HOOK:-manual}" = "kprobe" ]; then
    scripts/config --file "$CFG" --enable KPROBES --enable KPROBE_EVENTS --enable MODULES || true
  else
    scripts/config --file "$CFG" --disable KPROBES --disable KPROBE_EVENTS || true
  fi
  # stack-protector-strong 探测
  if ! ${CROSS_COMPILE}gcc -fstack-protector-strong -E -x c /dev/null -o /dev/null 2>/dev/null; then
    echo "[*] gcc 不支持 -fstack-protector-strong，降级"
    scripts/config --file "$CFG" --disable CC_STACKPROTECTOR_STRONG || true
    scripts/config --file "$CFG" --enable CC_STACKPROTECTOR_REGULAR || true
  fi
  make "${MAKE_COMMON[@]}" olddefconfig
fi

# out-of-tree 时 dtc 可能在 out/ 下重新生成 lexer，编译前再补一次并清 host 产物
fix_yylloc
rm -f "$OUT"/scripts/dtc/dtc \
      "$OUT"/scripts/dtc/*.o \
      "$OUT"/scripts/dtc/dtc-lexer.lex.c \
      "$OUT"/scripts/dtc/dtc-parser.tab.c 2>/dev/null || true

echo "[*] building Image (jobs=$JOBS)"
# Coconutat 官方脚本目标是 Image.gz
set +e
make "${MAKE_COMMON[@]}" -j"$JOBS" Image.gz
RC=$?
if [ $RC -ne 0 ]; then
  echo "[*] Image.gz 失败，试 Image.gz-dtb"
  # 失败时再打一次补丁（防止 make 覆盖）
  fix_yylloc
  make "${MAKE_COMMON[@]}" -j"$JOBS" Image.gz-dtb
  RC=$?
fi
if [ $RC -ne 0 ]; then
  echo "[*] Image.gz-dtb 失败，试 Image"
  fix_yylloc
  make "${MAKE_COMMON[@]}" -j"$JOBS" Image
  RC=$?
fi
set -e
if [ $RC -ne 0 ]; then
  echo "[-] 编译失败"
  # 把 dtc 相关错误再吐一点方便排
  echo "[*] 最近 dtc 相关文件:"
  ls -la scripts/dtc 2>/dev/null | head || true
  ls -la "$OUT/scripts/dtc" 2>/dev/null | head || true
  exit $RC
fi

echo "[+] 编译完成"
find "$OUT/arch/${ARCH}/boot" -maxdepth 1 -type f \( -name 'Image*' -o -name 'Image.gz*' \) -ls || \
find arch/${ARCH}/boot -maxdepth 1 -type f -name 'Image*' -ls
