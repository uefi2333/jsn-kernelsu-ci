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

if [ -d "$ROOT/builder/scripts" ]; then
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

# 3) sucompat: task_stack.h is 4.10+
su = ksu / "sucompat.c"
if su.exists():
    t = read(su)
    nt = t
    nt = nt.replace(
        "#include <linux/sched/task_stack.h>",
        "#include <linux/sched.h> /* 4.9: no task_stack.h */",
    )
    # current_user_stack_pointer may be missing on some 4.9 trees
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
        print(f"[+] task_stack / current_user_stack_pointer fixed: {su}")

# 4) kernel_compat sched/task.h
kc = ksu / "kernel_compat.c"
if kc.exists():
    t = read(kc)
    if "#include <linux/sched/task.h>" in t and "KERNEL_VERSION(4, 10, 0)" not in t:
        nt = t.replace(
            "#include <linux/sched/task.h>",
            "#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 10, 0)\n"
            "#include <linux/sched/task.h>\n"
            "#else\n"
            "#include <linux/sched.h>\n"
            "#endif",
        )
        if "#include <linux/version.h>" not in nt:
            nt = "#include <linux/version.h>\n" + nt
        write(kc, nt)
        print(f"[+] sched/task.h fixed: {kc}")

# 5) throne_tracker: vfs_getattr / STATX for 4.9
tt = ksu / "throne_tracker.c"
if tt.exists():
    t = read(tt)
    if "vfs_getattr" in t and "KERNEL_VERSION(4, 11, 0)" not in t:
        # crude but effective: wrap STATX_* blocks for pre-4.11
        nt = t
        if "#include <linux/version.h>" not in nt:
            nt = "#include <linux/version.h>\n" + nt
        # Replace common 4-arg getattr pattern if present without guard
        nt2 = re.sub(
            r"vfs_getattr\(([^,]+),\s*([^,]+),\s*STATX_[^,]*,\s*AT_STATX_[^)]*\)",
            r"vfs_getattr(\1, \2)",
            nt,
        )
        if nt2 != nt:
            write(tt, nt2)
            print(f"[+] vfs_getattr 4.9 fixed: {tt}")
        else:
            print(f"[=] vfs_getattr pattern not matched: {tt}")

# 6) core_hook: security_add_hooks 2-arg on 4.9
ch = ksu / "core_hook.c"
if ch.exists():
    t = read(ch)
    if "security_add_hooks" in t and "KERNEL_VERSION(4, 12, 0)" not in t:
        nt = t
        if "#include <linux/version.h>" not in nt:
            nt = "#include <linux/version.h>\n" + nt
        # security_add_hooks(hooks, ARRAY_SIZE(hooks), "ksu") -> 2-arg on <4.12
        pat = re.compile(
            r"security_add_hooks\(([^,]+),\s*([^,]+),\s*[^)]+\);"
        )
        def repl(m):
            return (
                "#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 12, 0)\n"
                f"\tsecurity_add_hooks({m.group(1)}, {m.group(2)}, \"ksu\");\n"
                "#else\n"
                f"\tsecurity_add_hooks({m.group(1)}, {m.group(2)});\n"
                "#endif"
            )
        nt2, n = pat.subn(repl, nt)
        if n:
            write(ch, nt2)
            print(f"[+] security_add_hooks 2/3-arg fixed: {ch} ({n})")
        else:
            print(f"[=] security_add_hooks pattern miss: {ch}")

# 7) throne_comm: proc_ops -> file_operations on <5.6
tc = ksu / "throne_comm.c"
if tc.exists():
    t = read(tc)
    if "proc_ops" in t and "file_operations" not in t:
        nt = t
        if "#include <linux/version.h>" not in nt:
            nt = "#include <linux/version.h>\n" + nt
        nt = nt.replace("struct proc_ops", "struct file_operations")
        nt = nt.replace(".proc_open", ".open")
        nt = nt.replace(".proc_read", ".read")
        nt = nt.replace(".proc_write", ".write")
        nt = nt.replace(".proc_lseek", ".llseek")
        nt = nt.replace(".proc_release", ".release")
        write(tc, nt)
        print(f"[+] proc_ops -> file_operations fixed: {tc}")

# 8) kernel_read/write arg order for <4.14 (best-effort line fix)
if kc.exists():
    t = read(kc)
    if "kernel_read" in t and "KERNEL_VERSION(4, 14, 0)" not in t:
        # leave to full file restore below if needed
        pass

print("[+] python 4.9 fixes applied")
PY

python3 "$PATCH_PY"

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

# 5) sucompat: selinux_inode is 5.1+ only
python3 - <<'PY'
from pathlib import Path
import os
p = Path(os.environ["KSU_DIR"]) / "sucompat.c"
t = p.read_text(errors="ignore")
old = "\tstruct inode_security_struct *sec = selinux_inode(inode);"
new = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 1, 0)
\tstruct inode_security_struct *sec = selinux_inode(inode);
#else
\tstruct inode_security_struct *sec =
\t\t(struct inode_security_struct *)inode->i_security;
#endif"""
if "inode->i_security" in t and "selinux_inode(inode)" not in t:
    print("[=] sucompat already uses i_security path")
elif old in t:
    if "#include <linux/version.h>" not in t:
        t = "#include <linux/version.h>\n" + t
    p.write_text(t.replace(old, new))
    print("[+] sucompat: selinux_inode -> i_security for <5.1")
elif "selinux_inode(inode)" in t:
    if "#include <linux/version.h>" not in t:
        t = "#include <linux/version.h>\n" + t
    t = t.replace(old if old in t else "struct inode_security_struct *sec = selinux_inode(inode);", new)
    p.write_text(t)
    print("[+] sucompat: selinux_inode patched (loose)")
else:
    print("[=] no selinux_inode in sucompat")
PY

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
