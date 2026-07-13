#!/usr/bin/env bash
# SukiSU / KernelSU on Linux 4.9 (Huawei non-GKI) compatibility fixes
# Avoid bash heredocs: Actions runners + CRLF historically break <<'PY'
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
export KSU_DIR

python3 -c '
from pathlib import Path
import os, re

ksu = Path(os.environ["KSU_DIR"])
if not ksu.is_dir():
    raise SystemExit(f"missing {ksu}")

def read(p: Path) -> str:
    return p.read_text(errors="ignore")

def write(p: Path, t: str):
    p.write_text(t)

# ---------- 1) MODULE_IMPORT_NS is Linux 5.0+ only ----------
for p in list(ksu.rglob("*.c")) + list(ksu.rglob("*.h")):
    try:
        t = read(p)
    except Exception:
        continue
    if "MODULE_IMPORT_NS" not in t:
        continue
    if "KERNEL_VERSION(5, 0, 0)" in t or "KERNEL_VERSION(5,0,0)" in t:
        print(f"[=] already guarded MODULE_IMPORT_NS: {p}")
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
    write(p, nt)
    print(f"[+] MODULE_IMPORT_NS fixed in {p} ({n})")

# ---------- 2) compiler_types.h does not exist on 4.9 ----------
old = "#include <linux/compiler_types.h>"
new = "#include <linux/compiler.h> /* 4.9: no compiler_types.h */"
for p in list(ksu.rglob("*.c")) + list(ksu.rglob("*.h")):
    try:
        t = read(p)
    except Exception:
        continue
    if old not in t:
        continue
    write(p, t.replace(old, new))
    print(f"[+] compiler_types.h -> compiler.h : {p}")

# ---------- 3) linux/sched/*.h split headers are 4.11+ ----------
# task_stack.h / task.h / signal.h / mm.h
SCHED_MAP = {
    "#include <linux/sched/task_stack.h>": """#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 11, 0)
#include <linux/sched/task_stack.h>
#else
#include <linux/sched.h>
/* arm64/4.9: current_user_stack_pointer lives with pt_regs */
#ifndef current_user_stack_pointer
#define current_user_stack_pointer() (current_pt_regs()->sp)
#endif
#endif
""",
    "#include <linux/sched/task.h>": """#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 11, 0)
#include <linux/sched/task.h>
#else
#include <linux/sched.h>
#endif
""",
    "#include <linux/sched/signal.h>": """#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 11, 0)
#include <linux/sched/signal.h>
#else
#include <linux/sched.h>
#endif
""",
    "#include <linux/sched/mm.h>": """#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 11, 0)
#include <linux/sched/mm.h>
#else
#include <linux/sched.h>
#include <linux/mm.h>
#endif
""",
}

for p in list(ksu.rglob("*.c")) + list(ksu.rglob("*.h")):
    try:
        t = read(p)
    except Exception:
        continue
    orig = t
    for old_inc, repl in SCHED_MAP.items():
        if old_inc in t and "LINUX_VERSION_CODE >= KERNEL_VERSION(4, 11, 0)" not in t.split(old_inc)[0][-80:]:
            # only replace bare include once
            if old_inc in t:
                t = t.replace(old_inc, repl, 1)
    if t != orig:
        if "#include <linux/version.h>" not in t and p.suffix == ".c":
            # ensure version.h present near top
            lines = t.splitlines(True)
            inserted = False
            for i, line in enumerate(lines[:40]):
                if line.startswith("#include"):
                    lines.insert(i, "#include <linux/version.h>\n")
                    inserted = True
                    break
            if not inserted:
                t = "#include <linux/version.h>\n" + t
            else:
                t = "".join(lines)
        write(p, t)
        print(f"[+] sched/* headers guarded: {p}")

# ---------- 4) vfs_getattr 4-arg (statx) is 4.11+; 4.9 is 2-arg ----------
# SukiSU: err = vfs_getattr(&path, &stat, STATX_UID, AT_STATX_SYNC_AS_STAT);
VG_PAT = re.compile(
    r"(\berr\s*=\s*)?vfs_getattr\s*\(\s*(&?[\w.>\\-]+)\s*,\s*(&?[\w.>\\-]+)\s*,\s*STATX_UID\s*,\s*AT_STATX_SYNC_AS_STAT\s*\)\s*;"
)

def vg_repl(m):
    assign = m.group(1) or ""
    path = m.group(2)
    stat = m.group(3)
    return (
        f"#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 11, 0)\n"
        f"\t{assign}vfs_getattr({path}, {stat}, STATX_UID, AT_STATX_SYNC_AS_STAT);\n"
        f"#else\n"
        f"\t{assign}vfs_getattr({path}, {stat});\n"
        f"#endif"
    )

for p in list(ksu.rglob("*.c")) + list(ksu.rglob("*.h")):
    try:
        t = read(p)
    except Exception:
        continue
    if "STATX_UID" not in t and "AT_STATX_SYNC_AS_STAT" not in t:
        continue
    # already guarded nearby?
    if "vfs_getattr(&path, &stat);" in t and "KERNEL_VERSION(4, 11, 0)" in t:
        print(f"[=] vfs_getattr already 4.9-safe: {p}")
        continue
    nt, n = VG_PAT.subn(vg_repl, t)
    if n == 0:
        # broader fallback: any 4-arg vfs_getattr with STATX
        nt2 = re.sub(
            r"vfs_getattr\s*\(\s*([^,]+),\s*([^,]+),\s*STATX_[A-Z_]+\s*,\s*AT_STATX_[A-Z_]+\s*\)",
            r"""({
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 11, 0)
	vfs_getattr(\1, \2, STATX_UID, AT_STATX_SYNC_AS_STAT)
#else
	vfs_getattr(\1, \2)
#endif
})""",
            t,
        )
        if nt2 != t:
            nt, n = nt2, 1
        else:
            print(f"[=] STATX present but pattern miss: {p}")
            # dump lines for debug
            for i, line in enumerate(t.splitlines(), 1):
                if "STATX" in line or "vfs_getattr" in line:
                    print(f"    {i}: {line}")
            continue
    if "#include <linux/version.h>" not in nt:
        nt = "#include <linux/version.h>\n" + nt
    write(p, nt)
    print(f"[+] vfs_getattr/statx fixed in {p} ({n})")

# ---------- 5) path_getattr alternative sometimes used ----------
# nothing else for now

print("[+] python 4.9 fixes applied")
'

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
