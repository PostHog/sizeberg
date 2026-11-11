#!/bin/bash
# Builds SizeBerg-<version>-mac-arm64.pkg from a built and notarized SizeBerg.app, for MDM installs.
# The package is not signed: an MDM installs it as root with installer(8), which does not check one.
# Usage: pkg/build-pkg.sh <path to SizeBerg.app> <version> <output folder>
set -euo pipefail
app="$1"
version="$2"
out="$3"
here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/root"
ditto "$app" "$work/root/SizeBerg.app"
pkgbuild --analyze --root "$work/root" "$work/components.plist"
# By default installer(8) puts an app where it finds one with the same bundle ID, such as a dev build in
# a source folder. SizeBerg must land in /Applications: its login item and the MDM policy look there.
plutil -replace 0.BundleIsRelocatable -bool NO "$work/components.plist"

pkg="$out/SizeBerg-${version}-mac-arm64.pkg"
pkgbuild \
    --root "$work/root" \
    --component-plist "$work/components.plist" \
    --install-location /Applications \
    --scripts "$here/scripts" \
    --identifier com.posthog.sizeberg.pkg \
    --version "$version" \
    "$pkg"
echo "Built $pkg"
