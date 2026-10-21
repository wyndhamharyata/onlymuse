#!/bin/sh
# Makes app/AppIcon.icns from design/app-icon.svg, drawn by WebKit at each size macOS asks for.
set -eu
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swiftc -O tools/render-icon.swift -o "$work/render"
"$work/render" design/app-icon.svg "$work/1024.png" 1024

iconset="$work/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
	magick "$work/1024.png" -resize "${size}x${size}" "$iconset/icon_${size}x${size}.png"
	magick "$work/1024.png" -resize "$((size * 2))x$((size * 2))" "$iconset/icon_${size}x${size}@2x.png"
done

iconutil -c icns "$iconset" -o app/AppIcon.icns
echo "made app/AppIcon.icns"
