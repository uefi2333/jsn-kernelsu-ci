#!/usr/bin/env bash
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
OUT="${ROOT}/out"
KBOOT="${ROOT}/kernel/out/arch/arm64/boot"
ALT="${ROOT}/kernel/arch/arm64/boot"
mkdir -p "$OUT"

# 找 AnyKernel3
AK="${ROOT}/AnyKernel3"
if [ ! -d "$AK" ]; then
  git clone --depth=1 https://github.com/osm0sis/AnyKernel3 "$AK"
  rm -rf "$AK/.git"
fi

# 用仓库自带 anykernel.sh 覆盖
if [ -f "${ROOT}/builder/anykernel/anykernel.sh" ]; then
  cp -f "${ROOT}/builder/anykernel/anykernel.sh" "$AK/anykernel.sh"
fi

# 清旧镜像
rm -f "$AK"/Image* "$AK"/*.gz "$AK"/*.dtb 2>/dev/null || true

pick=""
for c in \
  "$KBOOT/Image.gz-dtb" "$ALT/Image.gz-dtb" \
  "$KBOOT/Image.gz" "$ALT/Image.gz" \
  "$KBOOT/Image-dtb" "$ALT/Image-dtb" \
  "$KBOOT/Image" "$ALT/Image"
do
  if [ -f "$c" ]; then pick="$c"; break; fi
done

if [ -z "$pick" ]; then
  echo "[-] 找不到编译产物 Image*"
  find "${ROOT}/kernel" -name 'Image*' | head
  exit 1
fi

cp -v "$pick" "$AK/$(basename "$pick")"
# AnyKernel 习惯文件名 Image.gz-dtb 或 Image
if [[ "$(basename "$pick")" == Image ]]; then
  :
elif [[ "$(basename "$pick")" == Image.gz-dtb ]]; then
  :
else
  # 同时放一份 Image 兼容
  cp -v "$pick" "$AK/Image" || true
fi

pushd "$AK" >/dev/null
zip -r9 "${OUT}/AnyKernel3-JSN-${KSU_FLAVOR:-ksu}-$(date +%Y%m%d).zip" \
  . -x "*.git*" -x "README*" -x "LICENSE*"
popd >/dev/null

ls -lh "$OUT"/AnyKernel3-JSN-*.zip
echo "[+] AnyKernel3 打包完成"
