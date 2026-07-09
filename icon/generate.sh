#!/bin/zsh
# Regenerates AppIcon.icns from source-1024.png:
# squircle-masks the art, then renders every icon size.
set -euo pipefail
cd "$(dirname "$0")"

swift mask.swift source-1024.png masked-1024.png

rm -rf AppIcon.iconset
mkdir AppIcon.iconset
for size in 16 32 128 256 512; do
  sips -z $size $size masked-1024.png --out "AppIcon.iconset/icon_${size}x${size}.png" > /dev/null
  double=$((size * 2))
  sips -z $double $double masked-1024.png --out "AppIcon.iconset/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil -c icns AppIcon.iconset
rm -rf AppIcon.iconset

echo "Generated icon/AppIcon.icns"
