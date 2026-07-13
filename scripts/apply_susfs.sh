#!/usr/bin/env bash
# 应用 SUSFS v2.0.0 + KPM backport 补丁（4.9 内核专用）
# 来源: https://github.com/xixiaobei-bei/KernelSU_on_Huawei
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
KDIR="${ROOT}/kernel"
PATCH_DIR="${ROOT}/builder/patches"

SUSFS_PATCH="susfs_4.9_kpm.patch"

if [ "${ENABLE_SUSFS:-false}" != "true" ]; then
  echo "[*] ENABLE_SUSFS=false, 跳过 SUSFS 补丁"
  exit 0
fi

if [ ! -f "$PATCH_DIR/$SUSFS_PATCH" ]; then
  echo "[-] SUSFS 补丁不存在: $PATCH_DIR/$SUSFS_PATCH"
  exit 1
fi

cd "$KDIR"

echo "[*] Applying SUSFS v2.0.0 + KPM backport patch (4.9)..."
echo "    补丁来源: xixiaobei-bei/KernelSU_on_Huawei"

# 先尝试干净应用
if git apply --check "$PATCH_DIR/$SUSFS_PATCH" 2>/dev/null; then
  git apply "$PATCH_DIR/$SUSFS_PATCH"
  echo "[+] SUSFS 补丁干净应用成功"
else
  echo "[*] 干净应用失败，尝试 --reject 模式"
  set +e
  git apply --reject "$PATCH_DIR/$SUSFS_PATCH" 2>&1 | tee /tmp/susfs_apply.log
  APPLY_RC=$?
  set -e

  if [ $APPLY_RC -ne 0 ]; then
    REJ_COUNT=$(find . -name "*.rej" 2>/dev/null | wc -l)
    if [ "$REJ_COUNT" -gt 0 ]; then
      echo "[!] 有 $REJ_COUNT 个 hunk 失败"
      find . -name "*.rej" -print
    fi
  fi
fi

# 验证关键文件
MISSING=0
for f in fs/susfs.c include/linux/susfs.h include/linux/susfs_def.h; do
  if [ ! -f "$f" ]; then
    echo "[-] 关键文件缺失: $f"
    MISSING=1
  fi
done

if [ $MISSING -eq 1 ]; then
  echo "[-] SUSFS 补丁不完整"
  exit 1
fi

echo "[+] SUSFS 补丁应用完成"
echo "    fs/susfs.c:        $(wc -l < fs/susfs.c) lines"
echo "    include/linux/susfs.h: $(wc -l < include/linux/susfs.h) lines"
