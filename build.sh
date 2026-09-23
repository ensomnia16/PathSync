#!/bin/zsh
set -euo pipefail

source_dir="${0:A:h}"
output_dir="${1:-$source_dir/.build}"
app="$output_dir/路径同步.app"

if [[ -e "$app" ]]; then
    print -u2 "目标已存在：$app。请选择新的输出目录。"
    exit 1
fi

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$source_dir/Info.plist" "$app/Contents/Info.plist"
cp "$source_dir/sync_tree.py" "$app/Contents/Resources/sync_tree.py"
cp "$source_dir/sync_merge.py" "$app/Contents/Resources/sync_merge.py"
cp -R "$source_dir/en.lproj" "$source_dir/zh-Hans.lproj" "$app/Contents/Resources/"

iconset="$output_dir/PathSync.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$source_dir/PathSyncIcon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$source_dir/PathSyncIcon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/ResearchSync.icns"

architecture="$(uname -m)"
swiftc -target "$architecture-apple-macosx13.0" -parse-as-library -O \
    -o "$app/Contents/MacOS/ResearchSync" "$source_dir/ResearchSync.swift" "$source_dir/SyncUI.swift" "$source_dir/NativeUI.swift"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
print "$app"
