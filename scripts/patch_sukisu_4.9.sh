#!/usr/bin/env bash
# SukiSU / KernelSU on Linux 4.9 (Huawei non-GKI) compatibility fixes
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
KDIR="${ROOT}/kernel"
KSU_DIR=""

if [ -d "$KDIR/KernelSU/kernel" ]; then
  KSU_DIR="$KDIR/KernelSU/kernel"
elif [ -d "$KDIR/drivers/kernelsu" ]; then
  # may be symlink
  KSU_DIR="$(readlink -f "$KDIR/drivers/kernelsu" 2>/dev/null || true)"
  if [ -z "$KSU_DIR" ] || [ ! -d "$KSU_DIR" ]; then
    KSU_DIR="$KDIR/drivers/kernelsu"
  fi
fi

if [ -z "$KSU_DIR" ] || [ ! -d "$KSU_DIR" ]; then
  echo "[-] 找不到 KernelSU 驱动目录，跳过 4.9 补丁"
  exit 0
fi

echo "[*] patch SukiSU for 4.9: $KSU_DIR"

# --- 1) MODULE_IMPORT_NS：5.4+ 才有，4.9 必须去掉或加版本守卫 ---
if [ -f "$KSU_DIR/ksu.c" ]; then
  if grep -q 'MODULE_IMPORT_NS' "$KSU_DIR/ksu.c"; then
    # 若没有版本守卫则包一层
    if ! grep -q 'KERNEL_VERSION(5, 0, 0)' "$KSU_DIR/ksu.c"; then
      python3 - <<'PY'
from pathlib import Path
import re, os
p = Path(os.environ.get("KSU_DIR") or "")
# path passed via env below
PY
      KSU_DIR="$KSU_DIR" python3 - <<'PY'
from pathlib import Path
import os, re
p = Path(os.environ["KSU_DIR"]) / "ksu.c"
t = p.read_text(errors="ignore")
# ensure version.h included
if "#include <linux/version.h>" not in t:
    t = t.replace("#include <linux/module.h>", "#include <linux/module.h>\n#include <linux/version.h>")
# wrap bare MODULE_IMPORT_NS
pat = re.compile(r'^[ \t]*MODULE_IMPORT_NS\([^;]*\);[ \t]*$', re.M)
def wrap(m):
    line = m.group(0)
    return (
        "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)\n"
        f"{line}\n"
        "#endif"
    )
nt, n = pat.subn(wrap, t)
if n:
    p.write_text(nt)
    print(f"[+] wrapped MODULE_IMPORT_NS in ksu.c ({n})")
else:
    # fallback: comment out
    nt = t.replace(
        "MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);",
        "/* MODULE_IMPORT_NS removed for <5.0 */"
    )
    if nt != t:
        p.write_text(nt)
        print("[+] commented MODULE_IMPORT_NS in ksu.c")
    else:
        print("[=] MODULE_IMPORT_NS already guarded or absent pattern")
PY
    else:
      echo "[=] ksu.c 已有 KERNEL_VERSION 守卫"
  fi
fi

# 其它文件也可能有 MODULE_IMPORT_NS
while IFS= read -r -d '' f; do
  if grep -q 'MODULE_IMPORT_NS' "$f" && ! grep -q 'KERNEL_VERSION(5, 0, 0)' "$f"; then
    sed -i 's/^[ \t]*MODULE_IMPORT_NS([^;]*);/\/\* MODULE_IMPORT_NS disabled for 4.9 *\//' "$f" || true
    echo "[+] stripped MODULE_IMPORT_NS in $f"
  fi
done < <(find "$KSU_DIR" -type f \( -name '*.c' -o -name '*.h' \) -print0 2>/dev/null)

# --- 2) linux/compiler_types.h：4.9 没有，改为 compiler.h ---
while IFS= read -r -d '' f; do
  if grep -q 'linux/compiler_types.h' "$f"; then
    sed -i 's|#include <linux/compiler_types.h>|#include <linux/compiler.h> /* 4.9: no compiler_types.h */|g' "$f"
    echo "[+] compiler_types.h -> compiler.h : $f"
  fi
done < <(find "$KSU_DIR" -type f \( -name '*.c' -o -name '*.h' \) -print0 2>/dev/null)

# --- 3) 常见：random_sleep / copy_from_user_nofault / strscpy 等由 SukiSU kernel_compat 处理；
#     这里只补 4.9 明确炸的 include / macro ---

# --- 4) 确保 drivers/Makefile / Kconfig 已挂上 ---
if [ -f "$KDIR/drivers/Makefile" ] && ! grep -q 'kernelsu' "$KDIR/drivers/Makefile"; then
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$KDIR/drivers/Makefile"
  echo "[+] drivers/Makefile += kernelsu"
fi
if [ -f "$KDIR/drivers/Kconfig" ] && ! grep -q 'drivers/kernelsu/Kconfig' "$KDIR/drivers/Kconfig"; then
  # 插在 endmenu 前
  if grep -q '^endmenu' "$KDIR/drivers/Kconfig"; then
    sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' "$KDIR/drivers/Kconfig"
  else
    echo 'source "drivers/kernelsu/Kconfig"' >> "$KDIR/drivers/Kconfig"
  fi
  echo "[+] drivers/Kconfig += kernelsu"
fi

echo "[+] 4.9 SukiSU compatibility patch done"
