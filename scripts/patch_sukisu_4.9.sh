#!/usr/bin/env bash
# SukiSU / KernelSU on Linux 4.9 (Huawei non-GKI) compatibility fixes
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
KDIR="${ROOT}/kernel"
KSU_DIR=""

if [ -d "$KDIR/KernelSU/kernel" ]; then
  KSU_DIR="$KDIR/KernelSU/kernel"
elif [ -L "$KDIR/drivers/kernelsu" ] || [ -d "$KDIR/drivers/kernelsu" ]; then
  KSU_DIR="$(readlink -f "$KDIR/drivers/kernelsu" 2>/dev/null || true)"
  if [ -z "${KSU_DIR:-}" ] || [ ! -d "$KSU_DIR" ]; then
    KSU_DIR="$KDIR/drivers/kernelsu"
  fi
fi

if [ -z "${KSU_DIR:-}" ] || [ ! -d "$KSU_DIR" ]; then
  echo "[-] KernelSU driver dir not found, skip 4.9 patch"
  exit 0
fi

echo "[*] patch SukiSU for 4.9: $KSU_DIR"

# 1) MODULE_IMPORT_NS is Linux 5.0+ only
export KSU_DIR
python3 <<'PY'
from pathlib import Path
import os, re

ksu = Path(os.environ["KSU_DIR"])
for p in list(ksu.rglob("*.c")) + list(ksu.rglob("*.h")):
    try:
        t = p.read_text(errors="ignore")
    except Exception:
        continue
    if "MODULE_IMPORT_NS" not in t:
        continue
    if "KERNEL_VERSION(5, 0, 0)" in t or "KERNEL_VERSION(5,0,0)" in t:
        print(f"[=] already guarded: {p}")
        continue
    if "#include <linux/version.h>" not in t and p.suffix == ".c":
        if "#include <linux/module.h>" in t:
            t = t.replace(
                "#include <linux/module.h>",
                "#include <linux/module.h>\n#include <linux/version.h>",
                1,
            )
        else:
            t = "#include <linux/version.h>\n" + t
    pat = re.compile(r"^[ \t]*MODULE_IMPORT_NS\([^;]*\);[ \t]*$", re.M)

    def wrap(m):
        return (
            "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)\n"
            f"{m.group(0)}\n"
            "#endif"
        )

    nt, n = pat.subn(wrap, t)
    if n == 0:
        nt = t.replace(
            "MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);",
            "/* MODULE_IMPORT_NS removed for kernel < 5.0 */",
        )
        if nt == t:
            print(f"[=] MODULE_IMPORT_NS present but pattern miss: {p}")
            continue
        n = 1
    p.write_text(nt)
    print(f"[+] MODULE_IMPORT_NS fixed in {p} ({n})")
PY

# 2) compiler_types.h does not exist on 4.9
python3 <<'PY'
from pathlib import Path
import os

ksu = Path(os.environ["KSU_DIR"])
old = "#include <linux/compiler_types.h>"
new = "#include <linux/compiler.h> /* 4.9: no compiler_types.h */"
for p in list(ksu.rglob("*.c")) + list(ksu.rglob("*.h")):
    try:
        t = p.read_text(errors="ignore")
    except Exception:
        continue
    if old not in t:
        continue
    p.write_text(t.replace(old, new))
    print(f"[+] compiler_types.h -> compiler.h : {p}")
PY

# 3) ensure drivers hook exists
if [ -f "$KDIR/drivers/Makefile" ] && ! grep -q 'kernelsu' "$KDIR/drivers/Makefile"; then
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$KDIR/drivers/Makefile"
  echo "[+] drivers/Makefile += kernelsu"
fi

if [ -f "$KDIR/drivers/Kconfig" ] && ! grep -q 'drivers/kernelsu/Kconfig' "$KDIR/drivers/Kconfig"; then
  if grep -q '^endmenu' "$KDIR/drivers/Kconfig"; then
    sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' "$KDIR/drivers/Kconfig"
  else
    echo 'source "drivers/kernelsu/Kconfig"' >> "$KDIR/drivers/Kconfig"
  fi
  echo "[+] drivers/Kconfig += kernelsu"
fi

echo "[+] 4.9 SukiSU compatibility patch done"
