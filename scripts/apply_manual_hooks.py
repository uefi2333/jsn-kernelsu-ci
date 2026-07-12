#!/usr/bin/env python3
"""
给非 GKI / 华为内核打 KernelSU manual hooks。
幂等：已含 ksu_handle_ 则跳过对应文件。
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

MARK = "/* >>> KernelSU manual hook >>> */"


def already(text: str) -> bool:
    return "ksu_handle_" in text or "CONFIG_KSU" in text and "ksu_handle" in text


def inject_after(content: str, anchor_regex: str, snippet: str, flags=re.M) -> tuple[str, bool]:
    if MARK in content and snippet.strip()[:40] in content:
        return content, False
    m = re.search(anchor_regex, content, flags)
    if not m:
        return content, False
    pos = m.end()
    return content[:pos] + "\n" + snippet + content[pos:], True


def patch_exec(path: Path) -> bool:
    t = path.read_text(errors="ignore")
    if "ksu_handle_execveat" in t:
        print(f"[=] skip {path}")
        return False
    decl = f"""
{MARK}
#ifdef CONFIG_KSU
extern bool ksu_execveat_hook __read_mostly;
extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,
                               void *envp, int *flags);
extern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,
                                        void *argv, void *envp, int *flags);
#endif
"""
    call = """
#ifdef CONFIG_KSU
        if (unlikely(ksu_execveat_hook))
                ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);
        else
                ksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp, &flags);
#endif
"""
    # 声明插在 do_execveat_common 前
    t2, ok1 = inject_after(
        t,
        r"(static\s+int\s+do_execveat_common\s*\([^;]*\)\s*\{)",
        "",  # 先找函数体
    )
    # 更稳：在函数定义前插声明
    m = re.search(r"static\s+int\s+do_execveat_common\s*\(", t)
    if not m:
        # 老内核可能是 do_execve
        m = re.search(r"static\s+int\s+do_execve\s*\(", t)
        if not m:
            print(f"[!] exec.c: 找不到 do_execveat_common/do_execve")
            return False
        # 简易 sucompat-only
        t = t[: m.start()] + decl + t[m.start() :]
        # 在函数开头大括号后插
        m2 = re.search(r"static\s+int\s+do_execve\s*\([^)]*\)\s*\{", t)
        if m2:
            t = t[: m2.end()] + call.replace("execveat", "execveat") + t[m2.end() :]
        path.write_text(t)
        print(f"[+] patched {path} (legacy do_execve)")
        return True

    t = t[: m.start()] + decl + t[m.start() :]
    m2 = re.search(r"static\s+int\s+do_execveat_common\s*\([^;{]*\)\s*\{", t)
    if not m2:
        # 跨行参数
        m2 = re.search(r"static\s+int\s+do_execveat_common[\s\S]*?\)\s*\{", t)
    if m2:
        t = t[: m2.end()] + call + t[m2.end() :]
        path.write_text(t)
        print(f"[+] patched {path}")
        return True
    print(f"[!] exec.c: 找到声明点但插入 call 失败")
    return False


def patch_open(path: Path) -> bool:
    t = path.read_text(errors="ignore")
    if "ksu_handle_faccessat" in t:
        print(f"[=] skip {path}")
        return False
    decl = f"""
{MARK}
#ifdef CONFIG_KSU
extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode, int *flags);
#endif
"""
    call = """
#ifdef CONFIG_KSU
        ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
#endif
"""
    # 优先 do_faccessat
    m = re.search(r"\blong\s+do_faccessat\s*\(|\bdo_faccessat\s*\(", t)
    if not m:
        m = re.search(r"SYSCALL_DEFINE3\s*\(\s*faccessat", t)
    if not m:
        print(f"[!] open.c: 找不到 faccessat")
        return False
    # 声明插函数前
    t = t[: m.start()] + decl + t[m.start() :]
    # call 插函数体开头
    m2 = re.search(r"(do_faccessat\s*\([\s\S]*?\)\s*\{|SYSCALL_DEFINE3\s*\(\s*faccessat[\s\S]*?\)\s*\{)", t)
    if not m2:
        print(f"[!] open.c: 无法定位函数体")
        return False
    t = t[: m2.end()] + call + t[m2.end() :]
    path.write_text(t)
    print(f"[+] patched {path}")
    return True


def patch_read_write(path: Path) -> bool:
    t = path.read_text(errors="ignore")
    if "ksu_handle_vfs_read" in t:
        print(f"[=] skip {path}")
        return False
    decl = f"""
{MARK}
#ifdef CONFIG_KSU
extern bool ksu_vfs_read_hook __read_mostly;
extern int ksu_handle_vfs_read(struct file **file_ptr, char __user **buf_ptr,
                               size_t *count_ptr, loff_t **pos);
#endif
"""
    call = """
#ifdef CONFIG_KSU
        if (unlikely(ksu_vfs_read_hook))
                ksu_handle_vfs_read(&file, &buf, &count, &pos);
#endif
"""
    m = re.search(r"\bssize_t\s+vfs_read\s*\(", t)
    if not m:
        print(f"[!] read_write.c: 找不到 vfs_read")
        return False
    t = t[: m.start()] + decl + t[m.start() :]
    m2 = re.search(r"ssize_t\s+vfs_read\s*\([\s\S]*?\)\s*\{", t)
    if not m2:
        print(f"[!] read_write.c: 无法定位函数体")
        return False
    t = t[: m2.end()] + call + t[m2.end() :]
    path.write_text(t)
    print(f"[+] patched {path}")
    return True


def patch_stat(path: Path) -> bool:
    t = path.read_text(errors="ignore")
    if "ksu_handle_stat" in t:
        print(f"[=] skip {path}")
        return False
    decl = f"""
{MARK}
#ifdef CONFIG_KSU
extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
#endif
"""
    call = """
#ifdef CONFIG_KSU
        ksu_handle_stat(&dfd, &filename, &flags);
#endif
"""
    # vfs_statx 或 vfs_fstatat
    m = re.search(r"\bint\s+vfs_statx\s*\(|\bint\s+vfs_fstatat\s*\(", t)
    if not m:
        print(f"[!] stat.c: 找不到 vfs_statx/vfs_fstatat")
        return False
    t = t[: m.start()] + decl + t[m.start() :]
    m2 = re.search(r"int\s+vfs_statx\s*\([\s\S]*?\)\s*\{|int\s+vfs_fstatat\s*\([\s\S]*?\)\s*\{", t)
    if not m2:
        print(f"[!] stat.c: 无法定位函数体")
        return False
    # flags 变量名可能是 flag
    body_call = call
    fn = m2.group(0)
    if "vfs_fstatat" in fn and "flag)" in fn or "int flag" in t[m2.start() : m2.end() + 80]:
        body_call = call.replace("&flags", "&flag")
    t = t[: m2.end()] + body_call + t[m2.end() :]
    path.write_text(t)
    print(f"[+] patched {path}")
    return True


def patch_input(path: Path) -> bool:
    t = path.read_text(errors="ignore")
    if "ksu_handle_input_handle_event" in t:
        print(f"[=] skip {path}")
        return False
    decl = f"""
{MARK}
#ifdef CONFIG_KSU
extern bool ksu_input_hook __read_mostly;
extern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);
#endif
"""
    call = """
#ifdef CONFIG_KSU
        if (unlikely(ksu_input_hook))
                ksu_handle_input_handle_event(&type, &code, &value);
#endif
"""
    m = re.search(r"static\s+void\s+input_handle_event\s*\(", t)
    if not m:
        print(f"[!] input.c: 找不到 input_handle_event")
        return False
    t = t[: m.start()] + decl + t[m.start() :]
    m2 = re.search(r"static\s+void\s+input_handle_event\s*\([\s\S]*?\)\s*\{", t)
    if not m2:
        print(f"[!] input.c: 无法定位函数体")
        return False
    t = t[: m2.end()] + call + t[m2.end() :]
    path.write_text(t)
    print(f"[+] patched {path}")
    return True


def patch_devpts(path: Path) -> bool:
    if not path.exists():
        print(f"[=] no {path}")
        return False
    t = path.read_text(errors="ignore")
    if "ksu_handle_devpts" in t:
        print(f"[=] skip {path}")
        return False
    decl = f"""
{MARK}
#ifdef CONFIG_KSU
extern int ksu_handle_devpts(struct inode *);
#endif
"""
    call = """
#ifdef CONFIG_KSU
        ksu_handle_devpts(dentry->d_inode);
#endif
"""
    m = re.search(r"\bvoid\s*\*\s*devpts_get_priv\s*\(", t)
    if not m:
        print(f"[!] devpts: 找不到 devpts_get_priv")
        return False
    t = t[: m.start()] + decl + t[m.start() :]
    m2 = re.search(r"void\s*\*\s*devpts_get_priv\s*\([\s\S]*?\)\s*\{", t)
    if not m2:
        return False
    t = t[: m2.end()] + call + t[m2.end() :]
    path.write_text(t)
    print(f"[+] patched {path}")
    return True


def patch_path_umount(path: Path) -> bool:
    """内核 < 5.9 需要 path_umount backport，模块 umount 才正常。"""
    t = path.read_text(errors="ignore")
    if re.search(r"\bpath_umount\s*\(", t):
        print(f"[=] path_umount 已存在 {path}")
        return False
    frag = r'''
/* >>> KernelSU path_umount backport >>> */
static int can_umount(const struct path *path, int flags)
{
        struct mount *mnt = real_mount(path->mnt);

        if (flags & ~(MNT_FORCE | MNT_DETACH | MNT_EXPIRE | UMOUNT_NOFOLLOW))
                return -EINVAL;
        if (!may_mount())
                return -EPERM;
        if (path->dentry != path->mnt->mnt_root)
                return -EINVAL;
        if (!check_mnt(mnt))
                return -EINVAL;
        if (mnt->mnt.mnt_flags & MNT_LOCKED)
                return -EINVAL;
        if (flags & MNT_FORCE && !capable(CAP_SYS_ADMIN))
                return -EPERM;
        return 0;
}

int path_umount(struct path *path, int flags)
{
        struct mount *mnt = real_mount(path->mnt);
        int ret;

        ret = can_umount(path, flags);
        if (!ret)
                ret = do_umount(mnt, flags);
        dput(path->dentry);
        mntput_no_expire(mnt);
        return ret;
}
'''
    # 插在 SYSCALL umount 相关之前；找不到就文件末尾前
    m = re.search(r"SYSCALL_DEFINE2\s*\(\s*umount", t)
    if m:
        t = t[: m.start()] + frag + "\n" + t[m.start() :]
    else:
        t = t + "\n" + frag
    path.write_text(t)
    print(f"[+] path_umount backport -> {path}")
    return True


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: apply_manual_hooks.py <kernel_root>")
        return 2
    root = Path(sys.argv[1])
    files = {
        "exec": root / "fs/exec.c",
        "open": root / "fs/open.c",
        "rw": root / "fs/read_write.c",
        "stat": root / "fs/stat.c",
        "input": root / "drivers/input/input.c",
        "devpts": root / "fs/devpts/inode.c",
        "ns": root / "fs/namespace.c",
    }
    for k, p in files.items():
        if k == "ns":
            continue
        if not p.exists():
            print(f"[!] missing {p}")
            continue
    ok = 0
    ok += patch_exec(files["exec"])
    ok += patch_open(files["open"])
    ok += patch_read_write(files["rw"])
    ok += patch_stat(files["stat"])
    ok += patch_input(files["input"])
    ok += patch_devpts(files["devpts"])
    if files["ns"].exists():
        ok += patch_path_umount(files["ns"])
    print(f"[*] done, patches applied/changed: {ok}")
    # exec/open/rw/stat 至少一个成功才算可用
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
