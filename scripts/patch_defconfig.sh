#!/usr/bin/env bash
# 给 defconfig 写入 KernelSU / kprobe 开关
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
KDIR="${ROOT}/kernel"
CFG_NAME="${DEFCONFIG:-merge_kirin710_defconfig}"
HOOK="${KSU_HOOK:-manual}"
SELINUX="${SELINUX_MODE:-enforcing}"

cd "$KDIR"

# 找 defconfig
CANDIDATES=(
  "arch/arm64/configs/${CFG_NAME}"
  "arch/arm64/configs/vendor/${CFG_NAME}"
  "arch/${ARCH:-arm64}/configs/${CFG_NAME}"
)

CFG=""
for c in "${CANDIDATES[@]}"; do
  if [ -f "$c" ]; then CFG="$c"; break; fi
done

if [ -z "$CFG" ]; then
  echo "[!] 找不到 $CFG_NAME，arch/arm64/configs 列表："
  ls arch/arm64/configs || true
  # 兜底：挑第一个含 kirin/jsn/merge 的
  CFG=$(find arch/arm64/configs -type f -name '*kirin*' -o -name '*jsn*' -o -name '*merge*' 2>/dev/null | head -n1 || true)
  if [ -z "${CFG:-}" ]; then
    echo "[-] 无可用 defconfig，请改 config.env 的 DEFCONFIG"
    exit 1
  fi
  echo "[*] 自动选用 $CFG"
fi

echo "[*] patch defconfig: $CFG (hook=$HOOK)"

# 去重后追加
strip_keys() {
  local f="$1"; shift
  local tmp
  tmp=$(mktemp)
  grep -v -E "^#? ?CONFIG_($*|KSU|KPROBES|HAVE_KPROBES|KPROBE_EVENTS|MODULES)=" "$f" > "$tmp" || true
  # 上面通配在 grep -E 里不成立，逐个删
  tmp2=$(mktemp)
  grep -v -E '^#? ?CONFIG_(KSU|KPROBES|HAVE_KPROBES|KPROBE_EVENTS)=' "$f" > "$tmp2" || cp "$f" "$tmp2"
  mv "$tmp2" "$f"
}

strip_keys "$CFG"

{
  echo ""
  echo "# ===== KernelSU CI ====="
  echo "CONFIG_KSU=y"
  if [ "$HOOK" = "kprobe" ]; then
    echo "CONFIG_KPROBES=y"
    echo "CONFIG_HAVE_KPROBES=y"
    echo "CONFIG_KPROBE_EVENTS=y"
    echo "CONFIG_MODULES=y"
  else
    # manual hook：必须关 KPROBES，否则音量减误触安全模式
    echo "# CONFIG_KPROBES is not set"
    echo "# CONFIG_KPROBE_EVENTS is not set"
  fi
  if [ "$SELINUX" = "permissive" ]; then
    echo "CONFIG_SECURITY_SELINUX_DEVELOP=y"
    # 运行时仍取决于内核 cmdline；这里仅保证 develop 可切
  fi
} >> "$CFG"

echo "[+] defconfig 已更新"
grep -E 'CONFIG_KSU|CONFIG_KPROBE' "$CFG" || true
