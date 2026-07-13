#!/usr/bin/env bash
# SukiSU-Ultra v3.2.0 on Linux 4.9 (Huawei non-GKI) — full compatibility patch
# - Patches flat kernel layout for 4.9 API differences
# - Replaces SELinux + kernel_compat with KernelSU v0.9.5 4.9-safe sources
# - Adds drivers/ hook entries if missing
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
KDIR="${ROOT}/kernel"
KSU_DIR=""

# Locate KernelSU driver dir
if [ -d "$KDIR/KernelSU/kernel" ]; then
  KSU_DIR="$KDIR/KernelSU/kernel"
elif [ -L "$KDIR/drivers/kernelsu" ] || [ -d "$KDIR/drivers/kernelsu" ]; then
  KSU_DIR="$(readlink -f "$KDIR/drivers/kernelsu" 2>/dev/null || true)"
  [ -z "${KSU_DIR:-}" ] && KSU_DIR="$KDIR/drivers/kernelsu"
fi

if [ -z "${KSU_DIR:-}" ] || [ ! -d "$KSU_DIR" ]; then
  echo "[-] KernelSU driver dir not found, skip 4.9 patch"
  exit 0
fi

echo "[*] patch SukiSU for 4.9: $KSU_DIR"
export KSU_DIR

# === Python patcher: in-tree fixes for 4.9 API differences ===
cat > /tmp/_ksu49.py <<'PYEOF'
import os, re
from pathlib import Path

ksu = Path(os.environ["KSU_DIR"])
if not ksu.is_dir():
    raise SystemExit(f"missing {ksu}")

def read(p): return p.read_text(errors="ignore")
def write(p, t): p.write_text(t)

# 1) MODULE_IMPORT_NS is Linux 5.0+ only
for p in list(ksu.rglob("*.c")) + list(ksu.rglob("*.h")):
    t = read(p)
    if "MODULE_IMPORT_NS" not in t:
        continue
    if "KERNEL_VERSION(5, 0, 0)" in t or "KERNEL_VERSION(5,0,0)" in t:
        print(f"[=] already guarded: {p}")
        continue
    if "#include <linux/version.h>" not in t:
        if "#include <linux/module.h>" in t:
            t = t.replace("#include <linux/module.h>",
                "#include <linux/module.h>\n#include <linux/version.h>", 1)
        else:
            t = "#include <linux/version.h>\n" + t
    pat = re.compile(r"^[ \t]*MODULE_IMPORT_NS\([^;]*\);[ \t]*$", re.M)
    def wrap(m):
        return f"#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)\n{m.group(0)}\n#endif"
    nt, n = pat.subn(wrap, t)
    if n == 0:
        nt = t.replace(
            "MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);",
            "/* MODULE_IMPORT_NS removed for kernel < 5.0 */")
        if nt == t:
            print(f"[=] MODULE_IMPORT_NS present but pattern miss: {p}")
            continue
        n = 1
    write(p, nt)
    print(f"[+] MODULE_IMPORT_NS fixed in {p} ({n})")

# 2) compiler_types.h does not exist on 4.9
old_ct = "#include <linux/compiler_types.h>"
new_ct = "#include <linux/compiler.h> /* 4.9: no compiler_types.h */"
for p in list(ksu.rglob("*.c")) + list(ksu.rglob("*.h")):
    t = read(p)
    if old_ct in t:
        write(p, t.replace(old_ct, new_ct))
        print(f"[+] compiler_types.h -> compiler.h: {p}")

# 3) current_user_stack_pointer (4.10+) → current_stack_pointer
su = ksu / "sucompat.c"
if su.exists():
    t = read(su)
    nt = t
    nt = nt.replace("#include <linux/sched/task_stack.h>",
        "#include <linux/sched.h> /* 4.9: no task_stack.h */")
    if "current_user_stack_pointer" in nt and "KSU_4_9_STACK" not in nt:
        if "#include <linux/version.h>" not in nt:
            nt = "#include <linux/version.h>\n" + nt
        nt = ("/* KSU_4_9_STACK */\n"
              "#ifndef current_user_stack_pointer\n"
              "#define current_user_stack_pointer() current_stack_pointer\n"
              "#endif\n") + nt
    if nt != t:
        write(su, nt)
        print(f"[+] sucompat: current_user_stack_pointer fixed")

# 4) kernel_compat: sched/task.h guard
kc = ksu / "kernel_compat.c"
if kc.exists():
    t = read(kc)
    if "#include <linux/sched/task.h>" in t and "KERNEL_VERSION(4, 10, 0)" not in t:
        write(kc, t.replace("#include <linux/sched/task.h>",
            "#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 10, 0)\n"
            "#include <linux/sched/task.h>\n"
            "#else\n"
            "#include <linux/sched.h>\n"
            "#endif"))
        print("[+] kernel_compat.c: sched/task.h guarded")

# 5) throne_tracker: vfs_getattr (4.11+ uses 4-arg with STATX_UID)
# v3.2.0 has: err = vfs_getattr(&path, &stat, STATX_UID, AT_STATX_SYNC_AS_STAT);
# 4.9 only supports: vfs_getattr(&path, &stat) — no STATX, no flags
tt = ksu / "throne_tracker.c"
if tt.exists():
    t = read(tt)
    if "vfs_getattr" in t and "KSU_49_VFS_GETATTR" not in t:
        if "#include <linux/version.h>" not in t:
            t = "#include <linux/version.h>\n" + t
        # Replace the ENTIRE line (err = vfs_getattr(...);) to avoid splitting err= and ;
        old_line = "\terr = vfs_getattr(&path, &stat, STATX_UID, AT_STATX_SYNC_AS_STAT);"
        new_block_text = (
            "\terr = /* KSU_49_VFS_GETATTR */\n"
            "\t#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 11, 0)\n"
            "\tvfs_getattr(&path, &stat, STATX_UID, AT_STATX_SYNC_AS_STAT);\n"
            "\t#else\n"
            "\tvfs_getattr(&path, &stat);\n"
            "\t#endif"
        )
        nt = t.replace(old_line, new_block_text)
        if nt != t:
            write(tt, nt)
            print("[+] throne_tracker: vfs_getattr line replaced with version-guarded block")
        else:
            # Try without leading tab
            old_line2 = "\terr = vfs_getattr(&path, &stat, STATX_UID, AT_STATX_SYNC_AS_STAT);"
            print("[!] throne_tracker: exact line match failed, trying regex fallback")
            import re
            pat = re.compile(r'(\terr = )vfs_getattr\(&path, &stat, STATX_UID, AT_STATX_SYNC_AS_STAT\);')
            def repl_fn(m):
                return (m.group(1) + "/* KSU_49_VFS_GETATTR */\n"
                        "\t#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 11, 0)\n"
                        "\tvfs_getattr(&path, &stat, STATX_UID, AT_STATX_SYNC_AS_STAT);\n"
                        "\t#else\n"
                        "\tvfs_getattr(&path, &stat);\n"
                        "\t#endif")
            nt, n = pat.subn(repl_fn, t)
            if n:
                write(tt, nt)
                print(f"[+] throne_tracker: vfs_getattr regex-fallback fixed ({n})")
            else:
                print("[!] throne_tracker: all patterns failed")

# 6) core_hook: security_add_hooks 2-arg on <4.12
ch = ksu / "core_hook.c"
if ch.exists():
    t = read(ch)
    if "security_add_hooks" in t and "KERNEL_VERSION(4, 12, 0)" not in t:
        if "#include <linux/version.h>" not in t:
            t = "#include <linux/version.h>\n" + t
        pat = re.compile(r'security_add_hooks\(([^,]+),\s*([^,]+),\s*[^)]+\);')
        def rh(m):
            return (f"#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 12, 0)\n"
                    f"\tsecurity_add_hooks({m.group(1)}, {m.group(2)}, \"ksu\");\n"
                    f"#else\n"
                    f"\tsecurity_add_hooks({m.group(1)}, {m.group(2)});\n"
                    f"#endif")
        nt, n = pat.subn(rh, t)
        if n:
            write(ch, nt)
            print(f"[+] core_hook: security_add_hooks 2/3-arg fixed ({n})")

# 7) throne_comm: proc_ops on <5.6
tr = ksu / "throne_comm.c"
if tr.exists():
    t = read(tr)
    if "proc_ops" in t and "file_operations" not in t:
        if "#include <linux/version.h>" not in t:
            t = "#include <linux/version.h>\n" + t
        nt = t.replace("struct proc_ops", "struct file_operations")
        nt = nt.replace(".proc_open", ".open")
        nt = nt.replace(".proc_read", ".read")
        nt = nt.replace(".proc_write", ".write")
        nt = nt.replace(".proc_lseek", ".llseek")
        nt = nt.replace(".proc_release", ".release")
        if nt != t:
            write(tr, nt)
            print("[+] throne_comm: proc_ops -> file_operations")

# 8) pmalloc.c: set_memory_ro/rw may not exist on 4.9
pmc = ksu.parent.parent / "mm" / "hisi" / "pmalloc.c"
if pmc.exists():
    t = read(pmc)
    if "set_memory_ro" in t and "KSU_4_9_SETMEM" not in t:
        if "#include <linux/version.h>" not in t:
            t = "#include <linux/version.h>\n" + t
        # Add compat stubs before first function
        stub = """
/* KSU_4_9_SETMEM: set_memory_ro/rw compat for kernel < 4.12 */
#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 12, 0)
#include <asm/cacheflush.h>
#ifndef set_memory_ro
static inline int set_memory_ro(unsigned long addr, int numpages) { return 0; }
static inline int set_memory_rw(unsigned long addr, int numpages) { return 0; }
#endif
#endif
"""
        # Insert after version.h include
        t = t.replace("#include <linux/version.h>",
                       "#include <linux/version.h>" + stub, 1)
        write(pmc, t)
        print(f"[+] pmalloc.c: set_memory_ro/rw compat added")

print("[+] python 4.9 fixes done")
PYEOF

python3 /tmp/_ksu49.py

# === Replace SELinux sources with KernelSU v0.9.5 (4.9-safe) ===
SELINUX_DIR="$KSU_DIR/selinux"
if [ -d "$SELINUX_DIR" ]; then
  BASE_URL="https://raw.githubusercontent.com/tiann/KernelSU/v0.9.5/kernel/selinux"
  echo "[*] restore KernelSU v0.9.5 SELinux for Linux 4.9"
  for f in sepolicy.c rules.c selinux.c selinux.h; do
    tmp="$(mktemp)"
    if curl -fsSL "$BASE_URL/$f" -o "$tmp"; then
      mv "$tmp" "$SELINUX_DIR/$f"
      echo "[+] selinux/$f <- KernelSU v0.9.5"
    else
      rm -f "$tmp"
      echo "[-] failed to fetch selinux/$f, skip"
    fi
  done
else
  echo "[-] no selinux dir under $KSU_DIR"
fi

# === sucompat: selinux_inode (5.1+ only) → i_security ===
SUC="$KSU_DIR/sucompat.c"
if [ -f "$SUC" ]; then
  echo "[*] patch sucompat.c: selinux_inode -> i_security for <5.1"
  python3 - <<'PY2'
from pathlib import Path
import os, re
su = Path(os.environ["KSU_DIR"]) / "sucompat.c"
t = su.read_text(errors="ignore")
if "selinux_inode" not in t:
    print("[=] no selinux_inode in sucompat.c")
else:
    if "KERNEL_VERSION(5, 1, 0)" in t:
        print("[=] already guarded")
    else:
        if "#include <linux/version.h>" not in t:
            t = "#include <linux/version.h>\n" + t
        pat = re.compile(r'([ \t]*)struct inode_security_struct \*([^=]+)= selinux_inode\(([^)]+)\);')
        def repl(m):
            return (f"{m.group(1)}#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 1, 0)\n"
                    f"{m.group(1)}struct inode_security_struct *{m.group(2)}= selinux_inode({m.group(3)});\n"
                    f"{m.group(1)}#else\n"
                    f"{m.group(1)}struct inode_security_struct *{m.group(2)}=\n"
                    f"{m.group(1)}\t(struct inode_security_struct *){m.group(3)}->i_security;\n"
                    f"{m.group(1)}#endif")
        nt, n = pat.subn(repl, t)
        if n:
            su.write_text(nt)
            print(f"[+] selinux_inode -> i_security ({n})")
PY2
fi

# === Replace kernel_compat from v0.9.5 + inject Suki helpers ===
BASE_KSU="https://raw.githubusercontent.com/tiann/KernelSU/v0.9.5/kernel"
for f in kernel_compat.c kernel_compat.h; do
  tmp="$(mktemp)"
  if curl -fsSL "$BASE_KSU/$f" -o "$tmp"; then
    mv "$tmp" "$KSU_DIR/$f"
    echo "[+] $f <- KernelSU v0.9.5"
  else
    rm -f "$tmp"
    echo "[-] failed to fetch $f"
  fi
done

# Re-add Suki helpers missing from 0.9.5
python3 - <<'PY3'
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
\tconst struct list_head *pos;
\tsize_t count = 0;
\tif (!head)
\t\treturn 0;
\tlist_for_each(pos, head)
\t\tcount++;
\treturn count;
}
#endif

/*
 * 4.9 has no copy_from_user_nofault; use plain copy_from_user.
 */
static inline long ksu_copy_from_user_retry(void *to,
\t\tconst void __user *from, unsigned long count)
{
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 3, 0)
\tlong ret = copy_from_user_nofault(to, from, count);
\tif (likely(!ret))
\t\treturn ret;
#endif
\treturn copy_from_user(to, from, count);
}
"""
    idx = t.rfind("#endif")
    if idx < 0:
        raise SystemExit("kernel_compat.h: no final endif")
    h.write_text(t[:idx] + inject + "\n" + t[idx:])
    print("[+] kernel_compat.h: list_count_nodes + ksu_copy_from_user_retry injected")
PY3

# === Ensure drivers hook exists ===
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


# === 8b) core_hook.c: fix C99 for-loop ===
CK="$KSU_DIR/core_hook.c"
if [ -f "$CK" ]; then
  echo "[*] patch core_hook.c: C99 for-loops"
  python3 - <<'PYCK'
import os, re
from pathlib import Path
ck = Path(os.environ["KSU_DIR"]) / "core_hook.c"
t = ck.read_text(errors="ignore")
pat = re.compile(r"for \((\w+) (\w+) = (\d+);")
def fix_for(m):
    typ, var, init = m.group(1), m.group(2), m.group(3)
    return f"{typ} {var};\n    for ({var} = {init};"
nt, n = pat.subn(fix_for, t)
if n:
    ck.write_text(nt)
    print(f"[+] core_hook.c: C99 for-loops fixed ({n})")
else:
    print("[=] core_hook.c: no C99 for-loops found")
PYCK
fi

# === 8c) kernel_compat: ensure ksu_strncpy_from_user_nofault exists ===
KCH="$KSU_DIR/kernel_compat.c"
if [ -f "$KCH" ]; then
  if ! grep -q "ksu_strncpy_from_user_nofault" "$KCH"; then
    echo "[*] Adding ksu_strncpy_from_user_nofault to kernel_compat.c"
    cat >> "$KCH" <<'COMPATFN'

/*
 * 4.9 has no strncpy_from_user_nofault; use plain strncpy_from_user.
 */
long ksu_strncpy_from_user_nofault(char *dst, const void __user *unsafe_addr,
                                   unsigned long count)
{
    long ret;
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 3, 0)
    ret = strncpy_from_user_nofault(dst, unsafe_addr, count);
    if (likely(!ret))
        return ret;
#else
    ret = strncpy_from_user(dst, unsafe_addr, count);
    if (ret >= 0 && ret < count)
        dst[ret] = '\0';
#endif
    return ret;
}
COMPATFN
    echo "[+] kernel_compat.c: ksu_strncpy_from_user_nofault added"
  fi
fi

# === 8d) sucompat.c: ensure ksu_strncpy_from_user_nofault is declared ===
SUCH="$KSU_DIR/kernel_compat.h"
if [ -f "$SUCH" ] && ! grep -q "ksu_strncpy_from_user_nofault" "$SUCH"; then
  echo "extern long ksu_strncpy_from_user_nofault(char *dst, const void __user *unsafe_addr, unsigned long count);" >> "$SUCH"
  echo "[+] kernel_compat.h: ksu_strncpy_from_user_nofault declared"
fi

# === 9) super_access.c: 4.9 compat (security member, C99 for-loops) ===
SAC="$KSU_DIR/kpm/super_access.c"
if [ -f "$SAC" ]; then
  echo "[*] patch kpm/super_access.c for 4.9"
  python3 - <<'PYSAC'
import os, re
from pathlib import Path
sac = Path(os.environ["KSU_DIR"]) / "kpm" / "super_access.c"
if not sac.exists():
    print("[!] super_access.c not found")
    raise SystemExit()
t = sac.read_text(errors="ignore")

# 1) Guard task_struct.security — doesn't exist on 4.9
if "KSU_49_NO_SEC" not in t:
    t = t.replace(
        "    DEFINE_MEMBER(task_struct, security)",
        "#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 10, 0)\n"
        "    DEFINE_MEMBER(task_struct, security)\n"
        "#endif /* KSU_49_NO_SEC */"
    )
    print("[+] super_access.c: security member guarded")

# 2) Also guard thread_pid — added in 4.19
if "KSU_49_NO_TPID" not in t:
    t = t.replace(
        "    DEFINE_MEMBER(task_struct, thread_pid)",
        "#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 19, 0)\n"
        "    DEFINE_MEMBER(task_struct, thread_pid)\n"
        "#endif /* KSU_49_NO_TPID */"
    )
    print("[+] super_access.c: thread_pid member guarded")

# 3) Fix C99 for-loop declarations: "for (size_t i = ..." -> declare before loop
pat = re.compile(r"for \((\w+) (\w+) = (\d+);")
def fix_for(m):
    typ, var, init = m.group(1), m.group(2), m.group(3)
    return f"{typ} {var};\n    for ({var} = {init};"
nt, n = pat.subn(fix_for, t)
if n:
    t = nt
    print(f"[+] super_access.c: C99 for-loops fixed ({n})")
else:
    print("[=] no C99 for-loops found")

sac.write_text(t)
PYSAC
fi


# === 10) path_umount compat: added in 4.18, 4.9 uses do_umount() ===
echo "[*] Adding path_umount compat for 4.9"
python3 - <<'PYUMOUNT'
import os
from pathlib import Path
ksu = Path(os.environ["KSU_DIR"])

# Add path_umount to kernel_compat.h
h = ksu / "kernel_compat.h"
t = h.read_text(errors="ignore")
if "path_umount" not in t:
    inject = """
/* path_umount compat for kernel < 4.18 */
#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 18, 0)
int path_umount(struct path *path, int flags);
#endif
"""
    idx = t.rfind("#endif")
    if idx < 0:
        idx = len(t)
    t = t[:idx] + inject + t[idx:]
    h.write_text(t)
    print("[+] kernel_compat.h: path_umount declaration added")

# Add path_umount impl to kernel_compat.c
c = ksu / "kernel_compat.c"
t = c.read_text(errors="ignore")
if "path_umount" not in t:
    impl = """

/* path_umount compat for kernel < 4.18 */
#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 18, 0)
int path_umount(struct path *path, int flags)
{
	return do_umount(path->mnt, flags);
}
#endif
"""
    t = t + impl
    c.write_text(t)
    print("[+] kernel_compat.c: path_umount implementation added")
PYUMOUNT

echo "[+] 4.9 SukiSU compatibility patch done"

