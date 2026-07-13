#!/usr/bin/env bash
set -euo pipefail

ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
OUT="${ROOT}/out"
KBOOT="${ROOT}/kernel/out/arch/arm64/boot"
ALT="${ROOT}/kernel/arch/arm64/boot"
mkdir -p "$OUT" "$OUT/release"

# 找 AnyKernel3
AK="${ROOT}/AnyKernel3"
if [ ! -d "$AK" ]; then
  git clone --depth=1 https://github.com/osm0sis/AnyKernel3 "$AK"
  rm -rf "$AK/.git"
fi

if [ -f "${ROOT}/builder/anykernel/anykernel.sh" ]; then
  cp -f "${ROOT}/builder/anykernel/anykernel.sh" "$AK/anykernel.sh"
fi

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
if [[ "$(basename "$pick")" != Image && "$(basename "$pick")" != Image.gz-dtb ]]; then
  cp -v "$pick" "$AK/Image" || true
fi

# 华为常见：fastboot flash kernel kernel.img
# 优先使用未压缩 Image 作为 kernel.img；没有则用挑中的产物
KERNEL_IMG_SRC=""
for c in "$KBOOT/Image" "$ALT/Image" "$pick"; do
  if [ -f "$c" ]; then KERNEL_IMG_SRC="$c"; break; fi
done
cp -v "$KERNEL_IMG_SRC" "$OUT/release/kernel.img"
# 同步放一份到 out 根，方便 workflow 收集
cp -v "$OUT/release/kernel.img" "$OUT/kernel.img"
# 额外保留原始 Image*
cp -v "$pick" "$OUT/release/$(basename "$pick")" || true
if [ -f "$KBOOT/Image.gz" ]; then cp -v "$KBOOT/Image.gz" "$OUT/release/Image.gz"; fi
if [ -f "$KBOOT/Image" ]; then cp -v "$KBOOT/Image" "$OUT/release/Image"; fi

STAMP=$(date +%Y%m%d)
FLAVOR="${KSU_FLAVOR:-sukisu}"
ZIP_NAME="AnyKernel3-JSN-${FLAVOR}-${STAMP}.zip"

pushd "$AK" >/dev/null
zip -r9 "${OUT}/${ZIP_NAME}" . -x "*.git*" -x "README*" -x "LICENSE*"
cp -v "${OUT}/${ZIP_NAME}" "$OUT/release/"
popd >/dev/null

ls -lh "$OUT"/AnyKernel3-JSN-*.zip "$OUT/kernel.img" "$OUT/release" || true
echo "[+] AnyKernel3 + kernel.img 打包完成"
