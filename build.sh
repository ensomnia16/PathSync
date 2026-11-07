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
module_cache="$output_dir/ModuleCache"
mkdir -p "$module_cache"
cp "$source_dir/Info.plist" "$app/Contents/Info.plist"
cp "$source_dir/sync_tree.py" "$app/Contents/Resources/sync_tree.py"
cp "$source_dir/sync_merge.py" "$app/Contents/Resources/sync_merge.py"
cp "$source_dir/cloud_only.py" "$app/Contents/Resources/cloud_only.py"
cp -R "$source_dir/en.lproj" "$source_dir/zh-Hans.lproj" "$app/Contents/Resources/"

iconset="$output_dir/PathSync.iconset"
mkdir -p "$iconset"
legacy_icon="$output_dir/PathSync-legacy.png"
swift -module-cache-path "$module_cache" "$source_dir/tools/package-legacy-icon.swift" "$source_dir/PathSyncIcon.png" "$legacy_icon"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$legacy_icon" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$legacy_icon" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/PathSyncDrawerCompact.icns"

architecture="$(uname -m)"
swiftc -module-cache-path "$module_cache" -target "$architecture-apple-macosx13.0" -parse-as-library -O \
    -o "$app/Contents/MacOS/PathSync" "$source_dir/ResearchSync.swift" "$source_dir/SyncHistory.swift" "$source_dir/SyncPreview.swift" "$source_dir/Shortcuts.swift" "$source_dir/ApplicationIdentity.swift" "$source_dir/CloudOnlyStorage.swift" "$source_dir/MenuBarState.swift" "$source_dir/MenuBarController.swift" "$source_dir/HistoryPage.swift" "$source_dir/SyncUI.swift" "$source_dir/NativeUI.swift" "$source_dir/SyncNotifications.swift" "$source_dir/UpdateChecker.swift" "$source_dir/UpdateInstaller.swift" "$source_dir/OneDriveRules.swift" "$source_dir/LatexDiff.swift" "$source_dir/CodexSummary.swift"
swiftc -module-cache-path "$module_cache" -target "$architecture-apple-macosx13.0" -O \
    -o "$app/Contents/Resources/UpdateApply" "$source_dir/UpdateApply.swift"
ln -s PathSync "$app/Contents/MacOS/ResearchSync"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
print "$app"
