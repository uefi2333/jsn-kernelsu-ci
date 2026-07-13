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
export KSU_DIR

# Write python patcher to a file to avoid shell quoting hell
PATCH_PY="$ROOT/builder/scripts/_patch_sukisu_4_9.py"
if [ ! -d "$(dirname "$PATCH_PY")" ]; then
  PATCH_PY="$ROOT/scripts/_patch_sukisu_4_9.py"
fi
mkdir -p "$(dirname "$PATCH_PY")"

cat > "$PATCH_PY" <<'PY'
from pathlib import Path
import os, re

ksu = Path(os.environ["KSU_DIR"])
if not ksu.is_dir():
    raise SystemExit(f"missing {ksu}")

def read(p: Path) -> str:
    return p.read_text(errors="ignore")

def write(p: Path, t: str):
    p.write_text(t)

# 1) MODULE_IMPORT_NS is Linux 5.0+ only
for p in list(ksu.rglob("*.c")) + list(ksu.rglob("*.h")):
    t = read(p)
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
    write(p, nt)
    print(f"[+] MODULE_IMPORT_NS fixed in {p} ({n})")

# 2) compiler_types.h does not exist on 4.9
old = "#include <linux/compiler_types.h>"
new = "#include <linux/compiler.h> /* 4.9: no compiler_types.h */"
for p in list(ksu.rglob("*.c")) + list(ksu.rglob("*.h")):
    t = read(p)
    if old not in t:
        continue
    write(p, t.replace(old, new))
    print(f"[+] compiler_types.h -> compiler.h : {p}")

# 3) task_stack.h / current_user_stack_pointer (4.9 has neither)
# On arm64 4.9, user SP is in current_pt_regs()->sp (asm/ptrace.h / linux/ptrace.h)
for p in list(ksu.rglob("*.c")) + list(ksu.rglob("*.h")):
    t = read(p)
    if "linux/sched/task_stack.h" not in t and "current_user_stack_pointer" not in t:
        continue
    orig = t
    # replace include
    t = t.replace(
        "#include <linux/sched/task_stack.h>",
        "#include <linux/version.h>\n"
        "#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 9, 0) && LINUX_VERSION_CODE < KERNEL_VERSION(4, 10, 0)\n"
        "#include <linux/ptrace.h>\n"
        "#include <asm/ptrace.h>\n"
        "#ifndef current_user_stack_pointer\n"
        "#define current_user_stack_pointer() ((unsigned long)current_pt_regs()->sp)\n"
        "#endif\n"
        "#else\n"
        "#include <linux/sched/task_stack.h>\n"
        "#endif",
    )
    # if include already gone but symbol remains, inject helper once near top
    if "current_user_stack_pointer" in t and "current_pt_regs()->sp" not in t and "linux/sched/task_stack.h" not in orig:
        inject = (
            "#include <linux/version.h>\n"
            "#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 10, 0)\n"
            "#include <linux/ptrace.h>\n"
            "#include <asm/ptrace.h>\n"
            "#ifndef current_user_stack_pointer\n"
            "#define current_user_stack_pointer() ((unsigned long)current_pt_regs()->sp)\n"
            "#endif\n"
            "#endif\n"
        )
        if "#include <linux/version.h>" in t:
            t = t.replace("#include <linux/version.h>", "#include <linux/version.h>\n" + inject, 1)
        else:
            t = inject + t
    if t != orig:
        write(p, t)
        print(f"[+] task_stack / current_user_stack_pointer fixed: {p}")

# 4) sched/task.h may also be missing on 4.9
for p in list(ksu.rglob("*.c")) + list(ksu.rglob("*.h")):
    t = read(p)
    if "linux/sched/task.h" not in t:
        continue
    nt = t.replace(
        "#include <linux/sched/task.h>",
        "#include <linux/version.h>\n"
        "#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 11, 0)\n"
        "#include <linux/sched/task.h>\n"
        "#else\n"
        "#include <linux/sched.h>\n"
        "#endif",
    )
    if nt != t:
        write(p, nt)
        print(f"[+] sched/task.h fixed: {p}")

# 5) vfs_getattr 4-arg / STATX_* is 4.11+; 4.9 is 2-arg
for p in list(ksu.rglob("*.c")) + list(ksu.rglob("*.h")):
    t = read(p)
    if "vfs_getattr(" not in t:
        continue
    # only touch 4-arg form with STATX
    if "STATX_UID" not in t and "AT_STATX_SYNC_AS_STAT" not in t:
        # still may have 4-arg without macros
        if re.search(r"vfs_getattr\([^;]+,[^;]+,[^;]+,[^;]+\)", t) is None:
            continue
    orig = t
    # ensure version.h
    if "#include <linux/version.h>" not in t:
        if "#include <linux/fs.h>" in t:
            t = t.replace("#include <linux/fs.h>", "#include <linux/fs.h>\n#include <linux/version.h>", 1)
        else:
            t = "#include <linux/version.h>\n" + t

    # replace common exact line used by throne_tracker
    t = t.replace(
        "err = vfs_getattr(&path, &stat, STATX_UID, AT_STATX_SYNC_AS_STAT);",
        "#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 11, 0)\n"
        "\terr = vfs_getattr(&path, &stat, STATX_UID, AT_STATX_SYNC_AS_STAT);\n"
        "#else\n"
        "\terr = vfs_getattr(&path, &stat);\n"
        "#endif",
    )
    # generic: vfs_getattr(a, b, c, d) -> guarded 2-arg for <4.11 if still present
    def repl_vg(m):
        full = m.group(0)
        if "LINUX_VERSION_CODE" in full:
            return full
        args = m.group(1)
        parts = [a.strip() for a in args.split(",")]
        if len(parts) < 4:
            return full
        a, b = parts[0], parts[1]
        return (
            "({ LINUX_VERSION_CODE >= KERNEL_VERSION(4, 11, 0) ? "
            f"vfs_getattr({args}) : vfs_getattr({a}, {b}); })"
        )

    # only apply generic if STATX still present after exact replace
    if "STATX_UID" in t or "AT_STATX_SYNC_AS_STAT" in t:
        t2, n = re.subn(
            r"vfs_getattr\(([^;]*STATX[^;]*)\)",
            lambda m: (
                f"vfs_getattr({m.group(1).split(',')[0].strip()}, {m.group(1).split(',')[1].strip()})"
                if False else m.group(0)
            ),
            t,
        )
        # safer explicit fallback for remaining STATX calls
        t = re.sub(
            r"([ \t]*)([a-zA-Z_][\w\s\*]*=\s*)?vfs_getattr\(([^;]+),\s*([^;]+),\s*STATX_[A-Z_]+,\s*AT_STATX_[A-Z_]+\);",
            lambda m: (
                f"{m.group(1)}#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 11, 0)\n"
                f"{m.group(1)}{m.group(2) or ''}vfs_getattr({m.group(3)}, {m.group(4)}, STATX_UID, AT_STATX_SYNC_AS_STAT);\n"
                f"{m.group(1)}#else\n"
                f"{m.group(1)}{m.group(2) or ''}vfs_getattr({m.group(3)}, {m.group(4)});\n"
                f"{m.group(1)}#endif"
            ),
            t,
        )
    if t != orig:
        write(p, t)
        print(f"[+] vfs_getattr 4.9 fixed: {p}")

# 6) copy_from_user_nofault may be missing; map to probe_kernel_read style if needed later
# leave for next failure if any

print("[+] python 4.9 fixes applied")
PY

python3 "$PATCH_PY"

# 7) ensure drivers hook exists
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
