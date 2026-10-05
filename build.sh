#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

version="${APP_VERSION:-$(cat VERSION)}"
if [[ ! "$version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)(-[A-Za-z0-9.-]+)?$ ]]; then
    echo "Invalid app version: $version" >&2
    exit 1
fi
short_version="${BASH_REMATCH[1]}"
build_number="${BUILD_NUMBER:-1}"
if [[ ! "$build_number" =~ ^[0-9]+$ ]]; then echo 'BUILD_NUMBER must be numeric.' >&2; exit 1; fi
architecture="$(uname -m)"
case "$architecture" in arm64|x86_64) ;; *) echo "Unsupported architecture: $architecture" >&2; exit 1 ;; esac
app_path="dist/Andermic Photo Importer.app"
mkdir -p build dist
./scripts/build-metadata-helper.sh
helper="build/metadata-helper/$architecture/MetadataHelper"
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"

xcrun swiftc -swift-version 5 -O -target "${architecture}-apple-macosx13.0" \
    -module-cache-path build/module-cache \
    Source/Core/*.swift Source/App/*.swift \
    -o "$app_path/Contents/MacOS/PhotoImport"

iconset="build/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" Assets/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    /usr/bin/sips -z "$doubled" "$doubled" Assets/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$iconset" -o "$app_path/Contents/Resources/AppIcon.icns"
cat > "$app_path/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PhotoImport</string>
<key>CFBundleIdentifier</key><string>net.andermic.photoimporter</string>
<key>CFBundleName</key><string>Andermic Photo Importer</string>
<key>CFBundleDisplayName</key><string>Andermic Photo Importer</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${short_version}</string>
<key>CFBundleVersion</key><string>${build_number}</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSRemovableVolumesUsageDescription</key><string>Read camera cards and copy originals into your chosen photo folders.</string>
<key>NSNetworkVolumesUsageDescription</key><string>Copy and verify photos in your chosen network photo folder.</string>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$app_path/Contents/Info.plist"
cp LICENSE "$app_path/Contents/Resources/LICENSE.txt"
cp THIRD_PARTY.md "$app_path/Contents/Resources/THIRD_PARTY.md"
# The self-contained metadata reader: pinned Perl runtime, ExifTool, and their licenses.
/usr/bin/ditto "$helper" "$app_path/Contents/Resources/MetadataHelper"
/usr/bin/xattr -cr "$app_path"
identity="${SIGNING_IDENTITY:--}"
sign() {
    if [[ "$identity" == '-' ]]; then
        /usr/bin/codesign --force --sign - "$@"
    else
        /usr/bin/codesign --force --options runtime --timestamp --sign "$identity" "$@"
    fi
}
# Sign nested code inside-out: the Perl interpreter and its compiled extension modules, then the app.
while IFS= read -r -d '' binary; do sign "$binary"; done < <(find "$app_path/Contents/Resources/MetadataHelper" -type f \( -name perl -o -name '*.bundle' \) -print0)
sign "$app_path"
/usr/bin/codesign --verify --deep --strict "$app_path"
echo "Built Andermic Photo Importer $version ($architecture)."
