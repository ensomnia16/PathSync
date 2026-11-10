#!/bin/zsh
set -euo pipefail

source_dir="${0:A:h}"
output_dir="${1:-$source_dir/.build}"
app="$output_dir/路径同步.app"
swift_flags=()
if [[ "${PATHSYNC_UI_PREVIEW:-0}" == 1 ]]; then
    app="$output_dir/PathSync Preview.app"
    swift_flags=(-D PATHSYNC_UI_PREVIEW)
fi

if [[ -e "$app" ]]; then
    print -u2 "目标已存在：$app。请选择新的输出目录。"
    exit 1
fi

architecture="$(uname -m)"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
module_cache="$output_dir/ModuleCache"
mkdir -p "$module_cache"
info="$app/Contents/Info.plist"
cp "$source_dir/Info.plist" "$info"
if [[ "${PATHSYNC_UI_PREVIEW:-0}" == 1 ]]; then
    plutil -replace CFBundleIdentifier -string com.ensom.ResearchSync.UIPreview "$info"
    plutil -replace CFBundleName -string 'PathSync Preview' "$info"
    plutil -replace CFBundleDisplayName -string 'PathSync Preview' "$info"
    plutil -remove CFBundleURLTypes "$info"
fi
cp "$source_dir/sync_tree.py" "$app/Contents/Resources/sync_tree.py"
cp "$source_dir/sync_merge.py" "$app/Contents/Resources/sync_merge.py"
cp "$source_dir/authbroker/THIRD_PARTY_NOTICES.txt" "$app/Contents/Resources/THIRD_PARTY_NOTICES.txt"
cp "$source_dir/authbroker/RCLONE-LICENSE" "$app/Contents/Resources/RCLONE-LICENSE"
cp "$source_dir/graph_index.py" "$app/Contents/Resources/graph_index.py"
cp "$source_dir/mac_packages.py" "$source_dir/sync_cancel.py" "$app/Contents/Resources/"
clang -target "$architecture-apple-macosx13.0" -O3 -Wno-deprecated-declarations -dynamiclib "$source_dir/QuickXorHash.c" -o "$app/Contents/Resources/QuickXorHash.dylib"
if [[ "${PATHSYNC_UI_PREVIEW:-0}" != 1 ]]; then
    cp "$source_dir/pathsync_cli.py" "$app/Contents/Resources/"
    cp "$source_dir/tools/install-agent-cli.py" "$source_dir/docs/agent-instructions.md" "$app/Contents/Resources/"
    (cd "$source_dir/authbroker" && go build -trimpath -ldflags='-s -w' -o "$app/Contents/Resources/OneDriveOAuth" .)
    if [[ "${PATHSYNC_SIGNING_MODE:-stable}" == stable ]]; then
        trusted_helper="${PATHSYNC_AUTH_HELPER:-/Applications/路径同步.app/Contents/Resources/OneDriveAuth}"
        cp "$trusted_helper" "$app/Contents/Resources/OneDriveAuth"
        swiftc -target "$architecture-apple-macosx13.0" -O "$source_dir/OneDriveAuthGate.swift" -o "$app/Contents/Resources/OneDriveAuthGate"
    else
        swiftc -target "$architecture-apple-macosx13.0" -O "$source_dir/OneDriveAuth.swift" -o "$app/Contents/Resources/OneDriveAuth"
    fi
fi
cp "$source_dir/cloud_only.py" "$app/Contents/Resources/cloud_only.py"
cp "$source_dir/storage_analysis.py" "$app/Contents/Resources/storage_analysis.py"
cp -R "$source_dir/en.lproj" "$source_dir/zh-Hans.lproj" "$app/Contents/Resources/"
if [[ "${PATHSYNC_UI_PREVIEW:-0}" == 1 ]]; then
    for lang in en zh-Hans; do
        name='PathSync Preview'
        if [[ "$lang" == zh-Hans ]]; then name='路径同步试跑版'; fi
        printf '"CFBundleDisplayName" = "%s";\n"CFBundleName" = "%s";\n' "$name" "$name" \
            > "$app/Contents/Resources/$lang.lproj/InfoPlist.strings"
    done
fi

sdk_version=$(xcrun --sdk macosx --show-sdk-version)
if [[ "${sdk_version%%.*}" -ge 26 ]] && xcrun --find actool >/dev/null 2>&1; then
    xcrun actool --compile "$app/Contents/Resources" --platform macosx \
        --minimum-deployment-target 13.0 --app-icon PathSync \
        --output-partial-info-plist "$output_dir/IconInfo.plist" "$source_dir/PathSync.icon"
    icon_name=$(plutil -extract CFBundleIconName raw "$output_dir/IconInfo.plist")
    plutil -insert CFBundleIconName -string "$icon_name" "$info"
    icon_file=$(plutil -extract CFBundleIconFile raw "$output_dir/IconInfo.plist")
    plutil -replace CFBundleIconFile -string "$icon_file" "$info"
elif [[ "${PATHSYNC_UI_PREVIEW:-0}" == 1 ]]; then
    print -u2 "构建界面试跑版需要 Xcode 26 或更新版本。"
    exit 1
else
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
fi

swiftc "${swift_flags[@]}" -module-cache-path "$module_cache" -target "$architecture-apple-macosx13.0" -parse-as-library -O \
    -o "$app/Contents/MacOS/PathSync" "$source_dir/OneDriveConnection.swift" "$source_dir/ResearchSync.swift" "$source_dir/SyncHistory.swift" "$source_dir/SyncPreview.swift" "$source_dir/Shortcuts.swift" "$source_dir/ApplicationIdentity.swift" "$source_dir/CodeSigningIdentity.swift" "$source_dir/CloudOnlyStorage.swift" "$source_dir/StorageAnalysisView.swift" "$source_dir/MenuBarState.swift" "$source_dir/MenuBarController.swift" "$source_dir/HistoryPage.swift" "$source_dir/SyncUI.swift" "$source_dir/NativeUI.swift" "$source_dir/SyncDetailsView.swift" "$source_dir/SyncProgress.swift" "$source_dir/SyncNotifications.swift" "$source_dir/UpdateChecker.swift" "$source_dir/UpdateInstaller.swift" "$source_dir/OneDriveRules.swift" "$source_dir/LatexDiff.swift" "$source_dir/CodexSummary.swift"
if [[ "${PATHSYNC_UI_PREVIEW:-0}" == 1 ]]; then
    /usr/bin/codesign --force --sign - "$app/Contents/Resources/QuickXorHash.dylib"
    /usr/bin/codesign --force --sign - "$app"
else
    cat "$source_dir/CodeSigningIdentity.swift" "$source_dir/UpdateApply.swift" > "$output_dir/UpdateApplyMain.swift"
    swiftc -module-cache-path "$module_cache" -target "$architecture-apple-macosx13.0" -O \
        -o "$app/Contents/Resources/UpdateApply" "$output_dir/UpdateApplyMain.swift"
    ln -s PathSync "$app/Contents/MacOS/ResearchSync"
    case "${PATHSYNC_SIGNING_MODE:-stable}" in
        stable) /usr/bin/python3 "$source_dir/tools/sign-app.py" "$app" ;;
        adhoc) /usr/bin/python3 "$source_dir/tools/sign-app.py" --adhoc "$app" ;;
        *) print -u2 "PATHSYNC_SIGNING_MODE must be stable or adhoc"; exit 1 ;;
    esac
fi
codesign --verify --deep --strict "$app"
print "$app"
