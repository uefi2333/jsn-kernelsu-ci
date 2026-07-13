#!/usr/bin/env bash
# SukiSU / KernelSU on Linux 4.9 (Huawei non-GKI) compatibility fixes
# Updated for SukiSU-Ultra "builtin" branch (subdirectory layout)
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
KDIR="${ROOT}/kernel"
KSU_DIR=""

# Detect KernelSU driver directory (both old flat and new subdirectory layouts)
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

# Detect layout: new SukiSU-Ultra has feature/ subdirectory, old has flat sucompat.c
if [ -d "$KSU_DIR/feature" ]; then
  echo "[*] Detected new SukiSU-Ultra subdirectory layout"
  NEW_LAYOUT=true
else
  echo "[*] Detected legacy flat layout"
  NEW_LAYOUT=false
fi

# Run Python patcher for both layouts
if [ "$ROOT/builder/scripts" ] && [ -d "$ROOT/builder/scripts" ]; then
  PATCH_PY="$ROOT/builder/scripts/_patch_sukisu_4_9.py"
elif [ -d "$ROOT/scripts" ]; then
  PATCH_PY="$ROOT/scripts/_patch_sukisu_4_9.py"
else
  PATCH_PY="/tmp/_patch_sukisu_4_9.py"
fi
mkdir -p "$(dirname "$PATCH_PY")"

cat > "$PATCH_PY" <<'PY'
from pathlib import Path
import os, re

ksu = Path(os.environ["KSU_DIR"])
new_layout = os.environ.get("NEW_LAYOUT", "false") == "true"
if not ksu.is_dir():
    raise SystemExit(f"missing {ksu}")

def read(p: Path) -> str:
    return p.read_text(errors="ignore")

def write(p: Path, t: str):
    p.write_text(t)

# 1) MODULE_IMPORT_NS is Linux 5.0+ only (recursive search, both layouts)
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

# 2) compiler_types.h does not exist on 4.9 (recursive search)
old_ct = "#include <linux/compiler_types.h>"
new_ct = "#include <linux/compiler.h> /* 4.9: no compiler_types.h */"
for p in list(ksu.rglob("*.c")) + list(ksu.rglob("*.h")):
    t = read(p)
    if old_ct not in t:
        continue
    write(p, t.replace(old_ct, new_ct))
    print(f"[+] compiler_types.h -> compiler.h : {p}")

# 3) current_user_stack_pointer may be missing on 4.9
# New layout: feature/sucompat.c, old layout: sucompat.c
su_candidates = [ksu / "feature" / "sucompat.c", ksu / "sucompat.c"]
su = None
for c in su_candidates:
    if c.exists():
        su = c
        break

if su:
    t = read(su)
    nt = t
    # task_stack.h compat (4.10+)
    nt = nt.replace(
        "#include <linux/sched/task_stack.h>",
        "#include <linux/sched.h> /* 4.9: no task_stack.h */",
    )
    # current_user_stack_pointer compat
    if "current_user_stack_pointer" in nt and "KSU_4_9_STACK" not in nt:
        if "#include <linux/version.h>" not in nt:
            nt = "#include <linux/version.h>\n" + nt
        nt = (
            "/* KSU_4_9_STACK */\n"
            "#ifndef current_user_stack_pointer\n"
            "#define current_user_stack_pointer() current_stack_pointer\n"
            "#endif\n"
        ) + nt
    if nt != t:
        write(su, nt)
        print(f"[+] sucompat: current_user_stack_pointer fixed: {su}")
    else:
        print(f"[=] sucompat: no changes needed: {su}")

# 4) kernel_compat sched/task.h (recursive search)
for p in list(ksu.rglob("kernel_compat*.c")) + list(ksu.rglob("kernel_compat*.h")):
    t = read(p)
    if "#include <linux/sched/task.h>" in t and "KERNEL_VERSION(4, 10, 0)" not in t:
        nt = t.replace(
            "#include <linux/sched/task.h>",
            "#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 10, 0)\n"
            "#include <linux/sched/task.h>\n"
            "#else\n"
            "#include <linux/sched.h>\n"
            "#endif",
        )
        if "#include <linux/version.h>" not in t:
            nt = "#include <linux/version.h>\n" + nt
        write(p, nt)
        print(f"[+] sched/task.h fixed: {p}")

# 5) selinux_inode is 5.1+ only - patch in file_wrapper.c and sucompat.c
for p in list(ksu.rglob("*.c")):
    t = read(p)
    if "selinux_inode" not in t:
        continue
    # Check if already guarded
    if "KERNEL_VERSION(5, 1, 0)" in t:
        print(f"[=] selinux_inode already guarded: {p}")
        continue
    if "#include <linux/version.h>" not in t:
        t = "#include <linux/version.h>\n" + t
    pat = re.compile(r"([ \t]*)struct inode_security_struct \*([^=]+)= selinux_inode\(([^)]+)\);")
    def repl_sel(m):
        return (
            f"{m.group(1)}#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 1, 0)\n"
            f"{m.group(1)}struct inode_security_struct *{m.group(2)}= selinux_inode({m.group(3)});\n"
            f"{m.group(1)}#else\n"
            f"{m.group(1)}struct inode_security_struct *{m.group(2)}=\n"
            f"{m.group(1)}\t(struct inode_security_struct *){m.group(3)}->i_security;\n"
            f"{m.group(1)}#endif"
        )
    nt, n = pat.subn(repl_sel, t)
    if n:
        write(p, nt)
        print(f"[+] selinux_inode -> i_security for <5.1: {p} ({n})")
    else:
        print(f"[=] selinux_inode pattern not matched: {p}")

# 6) security_add_hooks: 2-arg on <4.12 (recursive search)
for p in list(ksu.rglob("*.c")):
    t = read(p)
    if "security_add_hooks" not in t:
        continue
    if "KERNEL_VERSION(4, 12, 0)" in t or "KERNEL_VERSION(4,12,0)" in t:
        print(f"[=] security_add_hooks already guarded: {p}")
        continue
    if "#include <linux/version.h>" not in t:
        t = "#include <linux/version.h>\n" + t
    pat = re.compile(
        r"security_add_hooks\(([^,]+),\s*([^,]+),\s*[^)]+\);"
    )
    def repl_hooks(m):
        return (
            "#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 12, 0)\n"
            f"\tsecurity_add_hooks({m.group(1)}, {m.group(2)}, \"ksu\");\n"
            "#else\n"
            f"\tsecurity_add_hooks({m.group(1)}, {m.group(2)});\n"
            "#endif"
        )
    nt, n = pat.subn(repl_hooks, t)
    if n:
        write(p, nt)
        print(f"[+] security_add_hooks 2/3-arg fixed: {p} ({n})")

# 7) proc_ops -> file_operations on <5.6 (recursive search)
for p in list(ksu.rglob("*.c")):
    t = read(p)
    if "proc_ops" not in t:
        continue
    if "file_operations" in t:
        print(f"[=] already has file_operations: {p}")
        continue
    if "#include <linux/version.h>" not in t:
        t = "#include <linux/version.h>\n" + t
    nt = t.replace("struct proc_ops", "struct file_operations")
    nt = nt.replace(".proc_open", ".open")
    nt = nt.replace(".proc_read", ".read")
    nt = nt.replace(".proc_write", ".write")
    nt = nt.replace(".proc_lseek", ".llseek")
    nt = nt.replace(".proc_release", ".release")
    if nt != t:
        write(p, nt)
        print(f"[+] proc_ops -> file_operations fixed: {p}")

print("[+] python 4.9 fixes applied")
PY

NEW_LAYOUT="false"
if [ -d "$KSU_DIR/feature" ]; then
  NEW_LAYOUT="true"
fi
export NEW_LAYOUT

python3 "$PATCH_PY"

# For new layout: skip v0.9.5 SELinux/kernel_compat replacement (already handled upstream)
if [ "$NEW_LAYOUT" = "true" ]; then
  echo "[*] New layout detected, skipping v0.9.5 source replacement (handled upstream)"

  # Ensure drivers hook exists
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

  echo "[+] 4.9 SukiSU compatibility patch done (new layout)"
  exit 0
fi

# === Legacy layout patches below ===

# 4) SukiSU v3.2.0 dropped pre-5.x SELinux compat; restore KernelSU v0.9.5 selinux tree
SELINUX_DIR="$KSU_DIR/selinux"
if [ -d "$SELINUX_DIR" ]; then
  BASE_URL="https://raw.githubusercontent.com/tiann/KernelSU/v0.9.5/kernel/selinux"
  echo "[*] restore KernelSU v0.9.5 SELinux sources for Linux 4.9"
  for f in sepolicy.c rules.c selinux.c selinux.h; do
    tmp="$(mktemp)"
    if curl -fsSL "$BASE_URL/$f" -o "$tmp"; then
      mv "$tmp" "$SELINUX_DIR/$f"
      echo "[+] selinux/$f <- KernelSU v0.9.5"
    else
      rm -f "$tmp"
      echo "[-] failed to fetch selinux/$f"
      exit 1
    fi
  done
else
  echo "[-] no selinux dir under $KSU_DIR"
  exit 1
fi

# 5) sucompat: selinux_inode is 5.1+ only (handled by Python patcher above)

# 6) kernel_compat from KernelSU v0.9.5 (4.9-safe nofault + HISI keyring)
BASE_KSU="https://raw.githubusercontent.com/tiann/KernelSU/v0.9.5/kernel"
for f in kernel_compat.c kernel_compat.h; do
  tmp="$(mktemp)"
  curl -fsSL "$BASE_KSU/$f" -o "$tmp"
  mv "$tmp" "$KSU_DIR/$f"
  echo "[+] $f <- KernelSU v0.9.5"
done

# re-add Suki helpers that 0.9.5 lacks: list_count_nodes + ksu_copy_from_user_retry
python3 - <<'PY'
from pathlib import Path
import os
h = Path(os.environ["KSU_DIR"]) / "kernel_compat.h"
t = h.read_text(errors="ignore")
if "ksu_copy_from_user_retry" in t:
    print("[=] kernel_compat.h already has ksu_copy_from_user_retry")
else:
    inject = """
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 6, 0)
static inline __maybe_unused size_t list_count_nodes(const struct list_head *head)
{
	const struct list_head *pos;
	size_t count = 0;

	if (!head)
		return 0;
	list_for_each(pos, head)
		count++;
	return count;
}
#endif

/*
 * 4.9 has no copy_from_user_nofault; use plain copy_from_user.
 * Signature matches copy_from_user: 0 = success.
 */
static inline long ksu_copy_from_user_retry(void *to,
		const void __user *from, unsigned long count)
{
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 3, 0)
	long ret = copy_from_user_nofault(to, from, count);
	if (likely(!ret))
		return ret;
#endif
	return copy_from_user(to, from, count);
}
"""
    idx = t.rfind("#endif")
    if idx < 0:
        raise SystemExit("kernel_compat.h: no final endif")
    h.write_text(t[:idx] + inject + "\n" + t[idx:])
    print("[+] kernel_compat.h: list_count_nodes + ksu_copy_from_user_retry")
PY

# ensure drivers hook exists
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
