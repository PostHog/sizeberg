#!/bin/bash
# Builds SizeBerg.app, with the CLI inside it, into ./build, and a copy of the CLI as build/sizeberg.
# SIGN_IDENTITY set to a Developer ID Application identity signs for release with the hardened runtime;
# without it the build is ad-hoc signed, which is enough to run it on this Mac.
set -euo pipefail
cd "$(dirname "$0")"

# The macOS 27 SDK turns @State into a macro whose plugin ships with Xcode 27 but not with the
# command line tools. So with the command line tools, build against their macOS 26 SDK: it has every
# Liquid Glass API used here, and macOS 27 restyles them at run time. Xcode brings the plugin itself.
clt_sdk="$(xcode-select -p)/SDKs/MacOSX26.sdk"
if [ -d "$clt_sdk" ]; then
    export SDKROOT="$clt_sdk"
elif [ "$(xcode-select -p)" = "/Library/Developer/CommandLineTools" ]; then
    echo "Needs the macOS 26 SDK at $clt_sdk (from the command line tools), or Xcode." >&2
    exit 1
fi

version="$(cat VERSION)"
build_number="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
bundle_id="com.posthog.sizeberg"

swift build -c release

app="build/SizeBerg.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp .build/release/SizeBergApp "$app/Contents/MacOS/SizeBerg"
# The CLI ships inside the app, so one download has both; Homebrew links it onto the PATH.
# Contents/MacOS would clash: sizeberg and SizeBerg are the same name on a case-insensitive volume.
cp .build/release/sizeberg "$app/Contents/Helpers/sizeberg"
# Symbols are only for debugging; stripping halves both binaries.
strip -x "$app/Contents/MacOS/SizeBerg" "$app/Contents/Helpers/sizeberg"

# Sparkle, the updater. SwiftPM links it from next to the binary; in the bundle it sits in Frameworks.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
mkdir -p "$app/Contents/Frameworks"
ditto .build/release/Sparkle.framework "$sparkle"
install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/SizeBerg"
# The XPC services are for sandboxed apps only, and SizeBerg reads the whole workspace, so it is not
# sandboxed. Headers are for compiling. The app is arm64 only, so the Intel half of each binary goes too.
rm -rf "$sparkle"/{Headers,PrivateHeaders,Modules,XPCServices} "$sparkle"/Versions/B/{Headers,PrivateHeaders,Modules,XPCServices}
for binary in "$sparkle/Versions/B/Sparkle" "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app/Contents/MacOS/Updater"; do
    lipo -thin arm64 "$binary" -output "$binary"
done

# Resources/AppIcon.png is the 1024 px master; the .icns holds it at every size macOS asks for.
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

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>SizeBerg</string>
    <key>CFBundleDisplayName</key>
    <string>SizeBerg</string>
    <key>CFBundleIdentifier</key>
    <string>${bundle_id}</string>
    <key>CFBundleExecutable</key>
    <string>SizeBerg</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleShortVersionString</key>
    <string>${version}</string>
    <key>CFBundleVersion</key>
    <string>${build_number}</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 PostHog Inc. MIT License.</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>SUFeedURL</key>
    <string>https://github.com/PostHog/sizeberg/releases/latest/download/appcast.xml</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
</dict>
</plist>
PLIST
# The public half of the key that signs updates. Without it Sparkle installs nothing, so a build
# without the file, like a local one, does not update itself.
if [ -s Resources/sparkle-public-key.txt ]; then
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $(cat Resources/sparkle-public-key.txt)" "$app/Contents/Info.plist"
fi

# Inside out: every nested piece first, then the app, whose signature seals theirs.
# The hardened runtime, which notarization requires, loads only frameworks of the same team. An ad-hoc
# signature has no team, so local builds go without it.
identity="${SIGN_IDENTITY:--}"
options=(--force --sign "$identity")
if [ "$identity" != "-" ]; then
    options+=(--options runtime --timestamp)
fi
codesign "${options[@]}" "$sparkle/Versions/B/Autoupdate"
codesign "${options[@]}" "$sparkle/Versions/B/Updater.app"
codesign "${options[@]}" "$sparkle"
codesign "${options[@]}" --identifier "${bundle_id}.cli" "$app/Contents/Helpers/sizeberg"
codesign "${options[@]}" "$app"
cp "$app/Contents/Helpers/sizeberg" build/sizeberg
echo "Built $app ${version} (${build_number}) and build/sizeberg"
