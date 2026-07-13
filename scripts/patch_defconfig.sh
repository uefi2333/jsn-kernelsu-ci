#!/usr/bin/env bash
# 给 defconfig 写入 KernelSU / SukiSU / kprobe 开关
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
KDIR="${ROOT}/kernel"
CFG_NAME="${DEFCONFIG:-JSN_kirin710_defconfig}"
HOOK="${KSU_HOOK:-manual}"
SELINUX="${SELINUX_MODE:-enforcing}"
FLAVOR="${KSU_FLAVOR:-sukisu}"

cd "$KDIR"

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
  CFG=$(find arch/arm64/configs -type f \( -name '*kirin*' -o -name '*jsn*' -o -name '*merge*' \) 2>/dev/null | head -n1 || true)
  if [ -z "${CFG:-}" ]; then
    echo "[-] 无可用 defconfig，请改 config.env 的 DEFCONFIG"
    exit 1
  fi
  echo "[*] 自动选用 $CFG"
fi

echo "[*] patch defconfig: $CFG (flavor=$FLAVOR hook=$HOOK)"

tmp2=$(mktemp)
grep -v -E '^#? ?CONFIG_(KSU|KSU_DEBUG|KSU_MANUAL_HOOK|KSU_KPROBES_HOOK|KSU_TRACEPOINT_HOOK|KSU_MANUAL_SU|KPM|KPROBES|HAVE_KPROBES|KPROBE_EVENTS|OVERLAY_FS)=' "$CFG" > "$tmp2" || cp "$CFG" "$tmp2"
mv "$tmp2" "$CFG"

{
  echo ""
  echo "# ===== SukiSU / KernelSU CI ====="
  echo "CONFIG_KSU=y"
  # Android 几乎都有；SukiSU v3 依赖 OVERLAY_FS
  echo "CONFIG_OVERLAY_FS=y"
  if [ "$HOOK" = "kprobe" ]; then
    echo "CONFIG_KPROBES=y"
    echo "CONFIG_HAVE_KPROBES=y"
    echo "CONFIG_KPROBE_EVENTS=y"
    echo "CONFIG_MODULES=y"
    echo "CONFIG_KSU_KPROBES_HOOK=y"
    echo "# CONFIG_KSU_MANUAL_HOOK is not set"
    echo "# CONFIG_KSU_TRACEPOINT_HOOK is not set"
  else
    # manual hook：关 KPROBES，开 MANUAL_HOOK（SukiSU v3.x）
    echo "# CONFIG_KPROBES is not set"
    echo "# CONFIG_KPROBE_EVENTS is not set"
    echo "CONFIG_KSU_MANUAL_HOOK=y"
    echo "# CONFIG_KSU_KPROBES_HOOK is not set"
    echo "# CONFIG_KSU_TRACEPOINT_HOOK is not set"
  fi
  # 4.9 稳定性优先，默认关 KPM
  echo "# CONFIG_KPM is not set"
  if [ "$SELINUX" = "permissive" ]; then
    echo "CONFIG_SECURITY_SELINUX_DEVELOP=y"
  fi
} >> "$CFG"

echo "[+] defconfig 已更新"
grep -E 'CONFIG_KSU|CONFIG_KPROBE|CONFIG_OVERLAY|CONFIG_KPM' "$CFG" || true
