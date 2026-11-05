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
# Symbols are only for debugging; stripping halves both binaries.
strip -x "$app/Contents/MacOS/SizeBerg" build/sizeberg

# Resources/AppIcon.png is the 1024 px master; iconutil wants every size in an .iconset folder.
iconset="build/AppIcon.iconset"
rm -rf "$iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
# pngquant keeps the icon looking the same at about a third of the size. Without it, or for an image it
# cannot shrink (exit status 98 or 99), the image stays as is.
if command -v pngquant >/dev/null; then
    for image in "$iconset"/*.png; do
        pngquant --force --skip-if-larger --quality 70-95 --ext .png "$image" || true
    done
fi
# iconutil would re-encode every image as full RGBA and undo pngquant, so the .icns is written here:
# a header, then each PNG with the type code macOS reads for its size.
python3 - "$iconset" "$app/Contents/Resources/AppIcon.icns" <<'PY'
import pathlib, struct, sys
folder, output = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
types = {
    "icon_16x16.png": b"icp4", "icon_16x16@2x.png": b"ic11", "icon_32x32.png": b"icp5",
    "icon_32x32@2x.png": b"ic12", "icon_128x128.png": b"ic07", "icon_128x128@2x.png": b"ic13",
    "icon_256x256.png": b"ic08", "icon_256x256@2x.png": b"ic14", "icon_512x512.png": b"ic09",
    "icon_512x512@2x.png": b"ic10",
}
entries = b"".join(code + struct.pack(">I", 8 + len(data)) + data
                   for name, code in types.items() for data in [(folder / name).read_bytes()])
output.write_bytes(b"icns" + struct.pack(">I", 8 + len(entries)) + entries)
PY
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
