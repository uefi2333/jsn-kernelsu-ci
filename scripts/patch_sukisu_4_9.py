#!/usr/bin/env python3
"""SukiSU-Ultra v3.x -> Linux 4.9 (Huawei non-GKI) compatibility."""
from __future__ import annotations
import os, re, sys
from pathlib import Path

def find_ksu(root: Path) -> Path | None:
    cands = [
        root / "kernel" / "KernelSU" / "kernel",
        root / "kernel" / "drivers" / "kernelsu",
    ]
    link = root / "kernel" / "drivers" / "kernelsu"
    if link.exists():
        try:
            cands.insert(0, link.resolve())
        except Exception:
            pass
    for c in cands:
        if c.is_dir() and (c / "ksu.c").exists():
            return c
    return None

def write_if_changed(p: Path, text: str, tag: str) -> bool:
    old = p.read_text(errors="ignore") if p.exists() else None
    if old == text:
        print(f"[=] {tag}: unchanged {p}")
        return False
    p.write_text(text)
    print(f"[+] {tag}: {p}")
    return True

def patch_module_import_ns(ksu: Path) -> None:
    for p in list(ksu.rglob("*.c")) + list(ksu.rglob("*.h")):
        t = p.read_text(errors="ignore")
        if "MODULE_IMPORT_NS" not in t:
            continue
        if "KERNEL_VERSION(5, 0, 0)" in t or "MODULE_IMPORT_NS removed" in t:
            print(f"[=] MODULE_IMPORT_NS already handled: {p}")
            continue
        if "#include <linux/version.h>" not in t and p.suffix == ".c":
            if "#include <linux/module.h>" in t:
                t = t.replace("#include <linux/module.h>",
                              "#include <linux/module.h>\n#include <linux/version.h>", 1)
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
                print(f"[=] MODULE_IMPORT_NS pattern miss: {p}")
                continue
        p.write_text(nt)
        print(f"[+] MODULE_IMPORT_NS fixed: {p}")

def patch_compiler_types(ksu: Path) -> None:
    old = "#include <linux/compiler_types.h>"
    new = "#include <linux/compiler.h> /* 4.9: no compiler_types.h */"
    for p in list(ksu.rglob("*.c")) + list(ksu.rglob("*.h")):
        t = p.read_text(errors="ignore")
        if old not in t:
            continue
        p.write_text(t.replace(old, new))
        print(f"[+] compiler_types -> compiler.h: {p}")

def patch_sucompat(ksu: Path) -> None:
    p = ksu / "sucompat.c"
    if not p.exists():
        return
    t = p.read_text(errors="ignore")
    if "JSN_4_9_TASK_STACK" in t:
        print("[=] sucompat already patched")
        return
    # replace modern task_stack include
    t2 = t.replace(
        "#include <linux/sched/task_stack.h>",
        """/* JSN_4_9_TASK_STACK */
#include <linux/version.h>
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 11, 0)
#include <linux/sched/task_stack.h>
#else
#include <linux/sched.h>
#include <asm/processor.h>
#include <asm/ptrace.h>
#ifndef current_user_stack_pointer
#define current_user_stack_pointer() user_stack_pointer(task_pt_regs(current))
#endif
#endif
""",
    )
    if t2 == t:
        # still try insert after version.h
        if "task_stack.h" in t:
            print("[!] sucompat: include present but replace failed")
        else:
            print("[=] sucompat: no task_stack include?")
    p.write_text(t2)
    print("[+] sucompat task_stack/current_user_stack_pointer for 4.9")

def patch_throne_tracker(ksu: Path) -> None:
    p = ksu / "throne_tracker.c"
    if not p.exists():
        return
    t = p.read_text(errors="ignore")
    if "JSN_4_9_VFS_GETATTR" in t:
        print("[=] throne_tracker already patched")
        return
    # Replace modern 4-arg vfs_getattr with versioned block
    old = "err = vfs_getattr(&path, &stat, STATX_UID, AT_STATX_SYNC_AS_STAT);"
    new = """/* JSN_4_9_VFS_GETATTR */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 11, 0)
	err = vfs_getattr(&path, &stat, STATX_UID, AT_STATX_SYNC_AS_STAT);
#else
	err = vfs_getattr(&path, &stat);
#endif"""
    if old not in t:
        # more flexible
        pat = re.compile(r"err\s*=\s*vfs_getattr\s*\(\s*&path\s*,\s*&stat\s*,\s*STATX_UID\s*,\s*AT_STATX_SYNC_AS_STAT\s*\)\s*;")
        t2, n = pat.subn(new, t)
        if n == 0:
            print("[!] throne_tracker: vfs_getattr pattern not found")
            # dump nearby lines
            for i, ln in enumerate(t.splitlines(), 1):
                if "vfs_getattr" in ln:
                    print(f"  {i}:{ln}")
            return
        t = t2
    else:
        t = t.replace(old, new)
    p.write_text(t)
    print("[+] throne_tracker vfs_getattr 2-arg for 4.9")

def patch_kernel_compat_h(ksu: Path) -> None:
    p = ksu / "kernel_compat.h"
    if not p.exists():
        return
    t = p.read_text(errors="ignore")
    if "JSN_4_9_COPY_NOFAULT" in t:
        print("[=] kernel_compat.h already patched")
        return
    # copy_from_user_nofault is 5.x+; provide fallback
    needle = "static long ksu_copy_from_user_retry(void *to, \n\t\tconst void __user *from, unsigned long count)\n{\n\tlong ret = copy_from_user_nofault(to, from, count);"
    # simpler: replace call
    if "copy_from_user_nofault" in t and "JSN_4_9_COPY_NOFAULT" not in t:
        t = t.replace(
            "long ret = copy_from_user_nofault(to, from, count);",
            """/* JSN_4_9_COPY_NOFAULT */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 8, 0)
	long ret = copy_from_user_nofault(to, from, count);
#else
	long ret = copy_from_user(to, from, count);
#endif""",
        )
        p.write_text(t)
        print("[+] kernel_compat.h copy_from_user_nofault fallback")
    else:
        print("[=] kernel_compat.h no copy_from_user_nofault or already ok")

def patch_kernel_compat_c(ksu: Path) -> None:
    p = ksu / "kernel_compat.c"
    if not p.exists():
        return
    t = p.read_text(errors="ignore")
    if "JSN_4_9_COMPAT_C" in t:
        print("[=] kernel_compat.c already patched")
        return
    # sched/task.h is 4.11+
    t = t.replace(
        "#include <linux/sched/task.h>",
        """/* JSN_4_9_COMPAT_C */
#include <linux/version.h>
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 11, 0)
#include <linux/sched/task.h>
#else
#include <linux/sched.h>
#endif
""",
    )
    # strncpy_from_user_nofault is modern
    old_fn = """long ksu_strncpy_from_user_nofault(char *dst, const void __user *unsafe_addr,
				   long count)
{
	return strncpy_from_user_nofault(dst, unsafe_addr, count);
}"""
    new_fn = """long ksu_strncpy_from_user_nofault(char *dst, const void __user *unsafe_addr,
				   long count)
{
	/* JSN_4_9_COMPAT_C */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 8, 0)
	return strncpy_from_user_nofault(dst, unsafe_addr, count);
#elif LINUX_VERSION_CODE >= KERNEL_VERSION(5, 3, 0)
	return strncpy_from_unsafe_user(dst, unsafe_addr, count);
#else
	return strncpy_from_user(dst, (const char __user *)unsafe_addr, count);
#endif
}"""
    if old_fn in t:
        t = t.replace(old_fn, new_fn)
    else:
        # loose replace body
        t = re.sub(
            r"long ksu_strncpy_from_user_nofault\(char \*dst, const void __user \*unsafe_addr,\s*long count\)\s*\{\s*return strncpy_from_user_nofault\(dst, unsafe_addr, count\);\s*\}",
            new_fn,
            t,
            count=1,
            flags=re.S,
        )
    # kernel_read / kernel_write API: pre-4.14 used different signatures
    # 4.9: int kernel_read(struct file *file, loff_t offset, char *addr, unsigned long count)
    # new: ssize_t kernel_read(struct file *file, void *buf, size_t count, loff_t *pos)
    old_read = """ssize_t ksu_kernel_read_compat(struct file *p, void *buf, size_t count,
			       loff_t *pos)
{
	return kernel_read(p, buf, count, pos);
}"""
    new_read = """ssize_t ksu_kernel_read_compat(struct file *p, void *buf, size_t count,
			       loff_t *pos)
{
	/* JSN_4_9_COMPAT_C */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 14, 0)
	return kernel_read(p, buf, count, pos);
#else
	{
		ssize_t ret = kernel_read(p, *pos, (char *)buf, count);
		if (ret > 0)
			*pos += ret;
		return ret;
	}
#endif
}"""
    old_write = """ssize_t ksu_kernel_write_compat(struct file *p, const void *buf, size_t count,
				loff_t *pos)
{
	return kernel_write(p, buf, count, pos);
}"""
    new_write = """ssize_t ksu_kernel_write_compat(struct file *p, const void *buf, size_t count,
				loff_t *pos)
{
	/* JSN_4_9_COMPAT_C */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 14, 0)
	return kernel_write(p, buf, count, pos);
#else
	{
		ssize_t ret = kernel_write(p, buf, count, *pos);
		if (ret > 0)
			*pos += ret;
		return ret;
	}
#endif
}"""
    if old_read in t:
        t = t.replace(old_read, new_read)
    else:
        t = re.sub(
            r"ssize_t ksu_kernel_read_compat\(struct file \*p, void \*buf, size_t count,\s*loff_t \*pos\)\s*\{\s*return kernel_read\(p, buf, count, pos\);\s*\}",
            new_read,
            t,
            count=1,
            flags=re.S,
        )
    if old_write in t:
        t = t.replace(old_write, new_write)
    else:
        t = re.sub(
            r"ssize_t ksu_kernel_write_compat\(struct file \*p, const void \*buf, size_t count,\s*loff_t \*pos\)\s*\{\s*return kernel_write\(p, buf, count, pos\);\s*\}",
            new_write,
            t,
            count=1,
            flags=re.S,
        )
    p.write_text(t)
    print("[+] kernel_compat.c 4.9 sched/read/write/strncpy")

def ensure_drivers_kconfig(root: Path) -> None:
    kdir = root / "kernel"
    mk = kdir / "drivers" / "Makefile"
    if mk.exists() and "kernelsu" not in mk.read_text(errors="ignore"):
        with mk.open("a") as f:
            f.write("\nobj-$(CONFIG_KSU) += kernelsu/\n")
        print("[+] drivers/Makefile += kernelsu")
    kc = kdir / "drivers" / "Kconfig"
    if kc.exists():
        t = kc.read_text(errors="ignore")
        if "drivers/kernelsu/Kconfig" not in t:
            if re.search(r"^endmenu", t, re.M):
                t = re.sub(r"^endmenu", 'source "drivers/kernelsu/Kconfig"\nendmenu', t, count=1, flags=re.M)
            else:
                t += '\nsource "drivers/kernelsu/Kconfig"\n'
            kc.write_text(t)
            print("[+] drivers/Kconfig += kernelsu")

def main() -> int:
    root = Path(os.environ.get("GITHUB_WORKSPACE") or Path.cwd())
    # if run from builder repo with kernel sibling
    if not (root / "kernel").exists() and (root / ".." / "kernel").exists():
        root = (root / "..").resolve()
    ksu = find_ksu(root)
    if not ksu:
        # also try KSU_DIR env
        if os.environ.get("KSU_DIR"):
            ksu = Path(os.environ["KSU_DIR"])
    if not ksu or not ksu.is_dir():
        print("[-] KernelSU driver dir not found, skip 4.9 patch")
        return 0
    print(f"[*] patch SukiSU for 4.9: {ksu}")
    patch_module_import_ns(ksu)
    patch_compiler_types(ksu)
    patch_sucompat(ksu)
    patch_throne_tracker(ksu)
    patch_kernel_compat_h(ksu)
    patch_kernel_compat_c(ksu)
    ensure_drivers_kconfig(root)
    print("[+] 4.9 SukiSU compatibility patch done")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
