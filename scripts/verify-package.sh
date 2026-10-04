#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="${APP_VERSION:-$(cat VERSION)}"
architecture="$(uname -m)"
package="Andermic-Photo-Importer-${version}-${architecture}.zip"
verification="build/archive-verification"
rm -rf "$verification"
mkdir -p "$verification"
(cd dist && /usr/bin/shasum -a 256 --check "$package.sha256")
/usr/bin/ditto -x -k "dist/$package" "$verification"
app="$verification/Andermic Photo Importer.app"
/usr/bin/codesign --verify --deep --strict "$app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" = net.andermic.photoimporter
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = "${version%%-*}"
test -s "$app/Contents/Resources/AppIcon.icns"
test "$(xcrun lipo -archs "$app/Contents/MacOS/PhotoImport")" = "$architecture"
echo "Verified archive signature, architecture, icon, version, and checksum."
