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

# 3) task_stack.h / current_user_stack_pointer (4.9 has neither)
for p in list(ksu.rglob("*.c")) + list(ksu.rglob("*.h")):
    t = read(p)
    if "linux/sched/task_stack.h" not in t and "current_user_stack_pointer" not in t:
        continue
    orig = t
    t = t.replace(
        "#include <linux/sched/task_stack.h>",
        "#include <linux/version.h>\n"
        "#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 11, 0)\n"
        "#include <linux/ptrace.h>\n"
        "#include <asm/ptrace.h>\n"
        "#ifndef current_user_stack_pointer\n"
        "#define current_user_stack_pointer() ((unsigned long)current_pt_regs()->sp)\n"
        "#endif\n"
        "#else\n"
        "#include <linux/sched/task_stack.h>\n"
        "#endif",
    )
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
    if "STATX_UID" not in t and "AT_STATX_SYNC_AS_STAT" not in t:
        continue
    orig = t
    if "#include <linux/version.h>" not in t:
        if "#include <linux/fs.h>" in t:
            t = t.replace("#include <linux/fs.h>", "#include <linux/fs.h>\n#include <linux/version.h>", 1)
        else:
            t = "#include <linux/version.h>\n" + t

    t = t.replace(
        "err = vfs_getattr(&path, &stat, STATX_UID, AT_STATX_SYNC_AS_STAT);",
        "#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 11, 0)\n"
        "\terr = vfs_getattr(&path, &stat, STATX_UID, AT_STATX_SYNC_AS_STAT);\n"
        "#else\n"
        "\terr = vfs_getattr(&path, &stat);\n"
        "#endif",
    )

    if "STATX_UID" in t or "AT_STATX_SYNC_AS_STAT" in t:
        t = re.sub(
            r"([ \t]*)(([a-zA-Z_][\w]*\s*=\s*)?)vfs_getattr\(([^,\n]+),\s*([^,\n]+),\s*STATX_[A-Z_]+,\s*AT_STATX_[A-Z_]+\);",
            lambda m: (
                f"{m.group(1)}#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 11, 0)\n"
                f"{m.group(1)}{m.group(2) or ''}vfs_getattr({m.group(4)}, {m.group(5)}, STATX_UID, AT_STATX_SYNC_AS_STAT);\n"
                f"{m.group(1)}#else\n"
                f"{m.group(1)}{m.group(2) or ''}vfs_getattr({m.group(4)}, {m.group(5)});\n"
                f"{m.group(1)}#endif"
            ),
            t,
        )

    if t != orig:
        write(p, t)
        print(f"[+] vfs_getattr 4.9 fixed: {p}")

# 6) security_add_hooks: 3-arg is 4.11+; 4.9 takes 2 args
for p in list(ksu.rglob("*.c")):
    t = read(p)
    if "security_add_hooks(" not in t:
        continue
    if "KERNEL_VERSION(4, 11, 0)" in t and "security_add_hooks" in t:
        # may already be version-gated; still check bare 3-arg call
        pass
    orig = t
    if "#include <linux/version.h>" not in t:
        t = "#include <linux/version.h>\n" + t
    # only patch the simple builtin call used by SukiSU v3.2.0
    pat = re.compile(
        r"^([ \t]*)security_add_hooks\(([^,\n]+),\s*([^,\n]+),\s*\"ksu\"\);\s*$",
        re.M,
    )
    def repl(m):
        ind, a, b = m.group(1), m.group(2), m.group(3)
        return (
            f"{ind}#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 11, 0)\n"
            f"{ind}security_add_hooks({a}, {b}, \"ksu\");\n"
            f"{ind}#else\n"
            f"{ind}security_add_hooks({a}, {b});\n"
            f"{ind}#endif"
        )
    nt, n = pat.subn(repl, t)
    if n:
        write(p, nt)
        print(f"[+] security_add_hooks 2/3-arg fixed: {p} ({n})")
    elif orig != t:
        write(p, t)

# 7) proc_ops is 5.6+; 4.9 uses file_operations
for p in list(ksu.rglob("*.c")):
    t = read(p)
    if "struct proc_ops" not in t and ".proc_open" not in t:
        continue
    if "KERNEL_VERSION(5, 6, 0)" in t and "file_operations" in t and "proc_ops" in t:
        print(f"[=] proc_ops already versioned: {p}")
        continue
    orig = t
    if "#include <linux/version.h>" not in t:
        if "#include <linux/proc_fs.h>" in t:
            t = t.replace("#include <linux/proc_fs.h>", "#include <linux/proc_fs.h>\n#include <linux/version.h>", 1)
        else:
            t = "#include <linux/version.h>\n" + t

    # Replace a typical uid_scanner_proc_ops block used by SukiSU throne_comm.c
    old_block = """static const struct proc_ops uid_scanner_proc_ops = {
    .proc_open = uid_scanner_open,
    .proc_read = seq_read,
	.proc_write = uid_scanner_write,
    .proc_lseek = seq_lseek,
    .proc_release = single_release,
};"""
    new_block = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 6, 0)
static const struct proc_ops uid_scanner_proc_ops = {
    .proc_open = uid_scanner_open,
    .proc_read = seq_read,
    .proc_write = uid_scanner_write,
    .proc_lseek = seq_lseek,
    .proc_release = single_release,
};
#else
static const struct file_operations uid_scanner_proc_ops = {
    .owner = THIS_MODULE,
    .open = uid_scanner_open,
    .read = seq_read,
    .write = uid_scanner_write,
    .llseek = seq_lseek,
    .release = single_release,
};
#endif"""
    if old_block in t:
        t = t.replace(old_block, new_block)
    else:
        # generic: wrap first proc_ops definition if present
        m = re.search(
            r"static const struct proc_ops\s+(\w+)\s*=\s*\{(.*?)\};",
            t,
            re.S,
        )
        if m:
            name = m.group(1)
            body = m.group(2)
            # map .proc_x = y to .x = y for file_operations
            fops_body = body
            fops_body = re.sub(r"\.proc_open\s*=", ".open =", fops_body)
            fops_body = re.sub(r"\.proc_read\s*=", ".read =", fops_body)
            fops_body = re.sub(r"\.proc_write\s*=", ".write =", fops_body)
            fops_body = re.sub(r"\.proc_lseek\s*=", ".llseek =", fops_body)
            fops_body = re.sub(r"\.proc_release\s*=", ".release =", fops_body)
            fops_body = re.sub(r"\.proc_ioctl\s*=", ".unlocked_ioctl =", fops_body)
            replacement = (
                f"#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 6, 0)\n"
                f"static const struct proc_ops {name} = {{{body}}};\n"
                f"#else\n"
                f"static const struct file_operations {name} = {{\n"
                f"    .owner = THIS_MODULE,{fops_body}}};\n"
                f"#endif"
            )
            t = t[: m.start()] + replacement + t[m.end() :]

    if t != orig:
        # ensure THIS_MODULE is available
        if "THIS_MODULE" in t and "#include <linux/module.h>" not in t:
            if "#include <linux/fs.h>" in t:
                t = t.replace("#include <linux/fs.h>", "#include <linux/fs.h>\n#include <linux/module.h>", 1)
            else:
                t = "#include <linux/module.h>\n" + t
        write(p, t)
        print(f"[+] proc_ops -> file_operations fixed: {p}")

# 8) kernel_read / kernel_write arg order changed at 4.14
kc = ksu / "kernel_compat.c"
if kc.is_file():
    t = read(kc)
    orig = t
    if "ksu_kernel_read_compat" in t and "KERNEL_VERSION(4, 14, 0)" not in t:
        if "#include <linux/version.h>" not in t:
            t = "#include <linux/version.h>\n" + t
        # replace thin wrappers
        t = re.sub(
            r"ssize_t ksu_kernel_read_compat\(struct file \*p, void \*buf, size_t count,\s*loff_t \*pos\)\s*\{\s*return kernel_read\(p, buf, count, pos\);\s*\}",
            "ssize_t ksu_kernel_read_compat(struct file *p, void *buf, size_t count,\n"
            "\t\t\t       loff_t *pos)\n"
            "{\n"
            "#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 14, 0)\n"
            "\treturn kernel_read(p, buf, count, pos);\n"
            "#else\n"
            "\tloff_t offset = pos ? *pos : 0;\n"
            "\tssize_t result = kernel_read(p, offset, (char *)buf, count);\n"
            "\tif (pos && result >= 0)\n"
            "\t\t*pos = offset + result;\n"
            "\treturn result;\n"
            "#endif\n"
            "}",
            t,
            flags=re.S,
        )
        t = re.sub(
            r"ssize_t ksu_kernel_write_compat\(struct file \*p, const void \*buf, size_t count,\s*loff_t \*pos\)\s*\{\s*return kernel_write\(p, buf, count, pos\);\s*\}",
            "ssize_t ksu_kernel_write_compat(struct file *p, const void *buf, size_t count,\n"
            "\t\t\t\tloff_t *pos)\n"
            "{\n"
            "#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 14, 0)\n"
            "\treturn kernel_write(p, buf, count, pos);\n"
            "#else\n"
            "\tloff_t offset = pos ? *pos : 0;\n"
            "\tssize_t result = kernel_write(p, buf, count, offset);\n"
            "\tif (pos && result >= 0)\n"
            "\t\t*pos = offset + result;\n"
            "\treturn result;\n"
            "#endif\n"
            "}",
            t,
            flags=re.S,
        )
        if t != orig:
            write(kc, t)
            print(f"[+] kernel_read/write 4.9 fixed: {kc}")
        else:
            # fallback: crude replace of return statements inside functions
            print(f"[=] kernel_compat regex miss, trying line-based fix")
            lines = orig.splitlines(True)
            out = []
            i = 0
            while i < len(lines):
                out.append(lines[i])
                if "return kernel_read(p, buf, count, pos);" in lines[i] and "ksu_kernel_read" in "".join(out[-8:]):
                    out[-1] = (
                        "#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 14, 0)\n"
                        "\treturn kernel_read(p, buf, count, pos);\n"
                        "#else\n"
                        "\tloff_t offset = pos ? *pos : 0;\n"
                        "\tssize_t result = kernel_read(p, offset, (char *)buf, count);\n"
                        "\tif (pos && result >= 0)\n"
                        "\t\t*pos = offset + result;\n"
                        "\treturn result;\n"
                        "#endif\n"
                    )
                if "return kernel_write(p, buf, count, pos);" in lines[i] and "ksu_kernel_write" in "".join(out[-8:]):
                    out[-1] = (
                        "#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 14, 0)\n"
                        "\treturn kernel_write(p, buf, count, pos);\n"
                        "#else\n"
                        "\tloff_t offset = pos ? *pos : 0;\n"
                        "\tssize_t result = kernel_write(p, buf, count, offset);\n"
                        "\tif (pos && result >= 0)\n"
                        "\t\t*pos = offset + result;\n"
                        "\treturn result;\n"
                        "#endif\n"
                    )
                i += 1
            nt = "".join(out)
            if nt != orig:
                if "#include <linux/version.h>" not in nt:
                    nt = "#include <linux/version.h>\n" + nt
                write(kc, nt)
                print(f"[+] kernel_read/write line-fixed: {kc}")

print("[+] python 4.9 fixes applied")
PY

python3 "$PATCH_PY"

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
