#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

product=AgentInteraction
dist_dir="$project_dir/dist"
destination="$dist_dir/$product.app"
lock_dir="$dist_dir/.package-lock"

swift build -c release --product "$product"
bin_dir="$(swift build -c release --show-bin-path)"
mkdir -p "$dist_dir"
if ! mkdir "$lock_dir"; then
    printf '无法取得打包锁：%s\n' "$lock_dir" >&2
    exit 1
fi

staging_dir=""
previous_bundle=""
cleanup() {
    if [[ -n "$previous_bundle" && ! -e "$destination" && ! -L "$destination" ]]; then
        if [[ -e "$previous_bundle" || -L "$previous_bundle" ]]; then
            mv "$previous_bundle" "$destination" || {
                printf '原应用保留在：%s\n' "$previous_bundle" >&2
                rmdir "$lock_dir"
                return 1
            }
        fi
    fi
    if [[ -n "$staging_dir" ]]; then
        find "$staging_dir" -depth -delete
    fi
    rmdir "$lock_dir"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

staging_dir="$(mktemp -d "$dist_dir/.package.XXXXXX")"
bundle="$staging_dir/$product.app"
mkdir -p "$bundle/Contents/MacOS"
install -m 755 "$bin_dir/$product" "$bundle/Contents/MacOS/$product"

cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>多 Agent 协作台</string>
    <key>CFBundleExecutable</key>
    <string>AgentInteraction</string>
    <key>CFBundleIdentifier</key>
    <string>com.cyrix.agent-interaction</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>多 Agent 协作台</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSMultipleInstancesProhibited</key>
    <true/>
</dict>
</plist>
PLIST

plutil -lint "$bundle/Contents/Info.plist"
codesign --force --sign - "$bundle"
codesign --verify --strict "$bundle"

if [[ -e "$destination" || -L "$destination" ]]; then
    previous_bundle="$staging_dir/previous.app"
    mv "$destination" "$previous_bundle"
fi
mv "$bundle" "$destination"
printf '已打包：%s\n' "$destination"
