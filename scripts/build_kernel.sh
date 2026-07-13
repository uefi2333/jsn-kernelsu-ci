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
DEFCONFIG="${DEFCONFIG:-JSN_kirin710_defconfig}"
USE_CCACHE="${USE_CCACHE:-0}"

CROSS_COMPILE="${CROSS_COMPILE#ccache }"
CROSS_COMPILE="${CROSS_COMPILE// /}"

if ! command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1 && [ ! -x "${CROSS_COMPILE}gcc" ]; then
  echo "[-] CROSS_COMPILE gcc 不存在: ${CROSS_COMPILE}gcc"
  exit 1
fi
echo "[*] compiler: $("${CROSS_COMPILE}gcc" --version | head -n1)"

if [ "$USE_CCACHE" = "1" ] && command -v ccache >/dev/null 2>&1; then
  export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
  TARGET_CC="ccache ${CROSS_COMPILE}gcc"
else
  TARGET_CC="${CROSS_COMPILE}gcc"
fi

# dtc yylloc 兼容
fix_yylloc() {
  for f in     scripts/dtc/dtc-lexer.l     scripts/dtc/dtc-lexer.lex.c     scripts/dtc/dtc-lexer.lex.c_shipped     scripts/dtc/dtc-parser.tab.c     scripts/dtc/dtc-parser.tab.c_shipped
  do
    [ -f "$f" ] && sed -i -E 's/^YYLTYPE[[:space:]]+yylloc;/extern YYLTYPE yylloc;/' "$f" || true
    [ -f "$f" ] && sed -i -E 's/^YYLTYPE[[:space:]]+yylloc[[:space:]]*=/extern YYLTYPE yylloc; \/* patched *\//;' "$f" || true
  done
}
fix_yylloc

rm -rf include/config 2>/dev/null || true

export HOSTCC="${HOSTCC:-gcc}"
export HOSTCXX="${HOSTCXX:-g++}"
export HOSTCFLAGS="${HOSTCFLAGS:--fcommon -Wno-error}"
export HOSTCXXFLAGS="${HOSTCXXFLAGS:--fcommon -Wno-error}"
export HOSTLDFLAGS="${HOSTLDFLAGS:--Wl,--allow-multiple-definition}"

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
elif ls arch/${ARCH}/configs/*"${DEFCONFIG}"* >/dev/null 2>&1; then
  DEFCONFIG_FILE=$(ls arch/${ARCH}/configs/*"${DEFCONFIG}"* | head -n1)
  make "${MAKE_COMMON[@]}" "$(basename "$DEFCONFIG_FILE")"
else
  echo "[-] defconfig 不存在: $DEFCONFIG"
  ls "arch/${ARCH}/configs" | head
  exit 1
fi

CFG="$OUT/.config"
if [ -f "$CFG" ]; then
  scripts/config --file "$CFG" --enable KSU || true

  if [ "${KSU_HOOK:-builtin}" = "kprobe" ]; then
    scripts/config --file "$CFG" --enable KPROBES --enable KPROBE_EVENTS --enable MODULES || true
  elif [ "${KSU_HOOK:-builtin}" = "manual" ]; then
    scripts/config --file "$CFG" --disable KPROBES --disable KPROBE_EVENTS || true
  else
    # builtin 模式: 保持默认（SUSFS inline hooks 替代 kprobe/manual）
    scripts/config --file "$CFG" --disable KPROBES --disable KPROBE_EVENTS || true
  fi

  # ===== SUSFS v2.0.0 全功能配置 =====
  if [ "${ENABLE_SUSFS:-false}" = "true" ]; then
    echo "[*] 启用 SUSFS v2.0.0 全功能配置"
    scripts/config --file "$CFG" --enable KSU_SUSFS || true
    scripts/config --file "$CFG" --enable KSU_SUSFS_SUS_PATH || true
    scripts/config --file "$CFG" --enable KSU_SUSFS_OPEN_REDIRECT || true
    scripts/config --file "$CFG" --enable KSU_SUSFS_SUS_MOUNT || true
    scripts/config --file "$CFG" --enable KSU_SUSFS_SUS_OVERLAYFS || true
    scripts/config --file "$CFG" --enable KSU_SUSFS_SUS_MAP || true
    scripts/config --file "$CFG" --enable KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG || true
    scripts/config --file "$CFG" --enable KSU_SUSFS_SUS_KSTAT || true
    scripts/config --file "$CFG" --enable KSU_SUSFS_SPOOF_UNAME || true
    scripts/config --file "$CFG" --enable KSU_SUSFS_ENABLE_LOG || true
    scripts/config --file "$CFG" --enable KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS || true
    echo "[+] SUSFS 全功能已启用"
  fi

  # ===== KPM (Kernel Patch Module) =====
  if [ "${ENABLE_KPM:-false}" = "true" ]; then
    echo "[*] 启用 KPM (CONFIG_KPM=y)"
    scripts/config --file "$CFG" --enable KPM || true
  fi

  # stack-protector 探测
  if ! ${CROSS_COMPILE}gcc -fstack-protector-strong -E -x c /dev/null -o /dev/null 2>/dev/null; then
    scripts/config --file "$CFG" --disable CC_STACKPROTECTOR_STRONG || true
    scripts/config --file "$CFG" --enable CC_STACKPROTECTOR_REGULAR || true
  fi

  make "${MAKE_COMMON[@]}" olddefconfig
fi

fix_yylloc
rm -f "$OUT"/scripts/dtc/dtc "$OUT"/scripts/dtc/*.o "$OUT"/scripts/dtc/dtc-lexer.lex.c "$OUT"/scripts/dtc/dtc-parser.tab.c 2>/dev/null || true

echo "[*] building Image (jobs=$JOBS)"
set +e
make "${MAKE_COMMON[@]}" -j"$JOBS" Image.gz
RC=$?
if [ $RC -ne 0 ]; then
  echo "[*] Image.gz 失败，试 Image.gz-dtb"
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
  exit $RC
fi

echo "[+] 编译完成"
find "$OUT/arch/${ARCH}/boot" -maxdepth 1 -type f \( -name 'Image*' \) -ls || find arch/${ARCH}/boot -maxdepth 1 -type f -name 'Image*' -ls
