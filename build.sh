#!/bin/bash
# Builds the CLI and a double-clickable SizeBerg.app into ./build.
set -euo pipefail
cd "$(dirname "$0")"

# The macOS 27 SDK turns @State into a macro whose plugin ships only with Xcode 27, not with the
# command line tools. The macOS 26 SDK has every Liquid Glass API used here; macOS 27 restyles them at run time.
SDKROOT="$(xcode-select -p)/SDKs/MacOSX26.sdk"
if [ ! -d "$SDKROOT" ]; then
    echo "Needs the macOS 26 SDK at $SDKROOT (from the command line tools)." >&2
    exit 1
fi
export SDKROOT

swift build -c release

app="build/SizeBerg.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/SizeBergApp "$app/Contents/MacOS/SizeBerg"
cp .build/release/sizeberg build/sizeberg

# Resources/AppIcon.png is the 1024 px master; iconutil wants every size in an .iconset folder.
iconset="build/AppIcon.iconset"
rm -rf "$iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$iconset"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>SizeBerg</string>
    <key>CFBundleDisplayName</key>
    <string>SizeBerg</string>
    <key>CFBundleIdentifier</key>
    <string>local.sizeberg</string>
    <key>CFBundleExecutable</key>
    <string>SizeBerg</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$app" >/dev/null
echo "Built $app and build/sizeberg"
