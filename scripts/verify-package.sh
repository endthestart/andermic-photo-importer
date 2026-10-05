#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/metadata-helper.lock
version="${APP_VERSION:-$(cat VERSION)}"
architecture="$(uname -m)"
package="Andermic-Photo-Importer-${version}-${architecture}.zip"
verification="build/archive-verification"
rm -rf "$verification"
mkdir -p "$verification"
(cd dist && /usr/bin/shasum -a 256 --check "$package.sha256")
/usr/bin/ditto -x -k "dist/$package" "$verification"
app="$(pwd)/$verification/Andermic Photo Importer.app"
/usr/bin/codesign --verify --deep --strict "$app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" = net.andermic.photoimporter
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" = "${version%%-*}"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$app/Contents/Info.plist")" = true
test -s "$app/Contents/Resources/AppIcon.icns"
cmp LICENSE "$app/Contents/Resources/LICENSE.txt"
cmp THIRD_PARTY.md "$app/Contents/Resources/THIRD_PARTY.md"
test "$(xcrun lipo -archs "$app/Contents/MacOS/PhotoImport")" = "$architecture"

# Bundled metadata helper: pinned versions, licenses, architecture, signatures, and system-only linkage.
helper="$app/Contents/Resources/MetadataHelper"
for license in Perl-Artistic-License.txt Perl-GNU-GPL-1.txt Perl-README.txt ExifTool-README.txt; do test -s "$helper/licenses/$license"; done
/usr/bin/python3 - "$helper/manifest.json" "$architecture" "$PERL_VERSION" "$PERL_SHA256" "$EXIFTOOL_VERSION" "$EXIFTOOL_SHA256" <<'PY'
import json, sys
manifest, arch, perl, perl_sha, exiftool, exiftool_sha = sys.argv[1:]
data = json.load(open(manifest))
assert data['architecture'] == arch, data['architecture']
found = {c['name']: (c['version'], c['sha256']) for c in data['components']}
assert found == {'Perl': (perl, perl_sha), 'ExifTool': (exiftool, exiftool_sha)}, found
PY
binaries=0
while IFS= read -r -d '' binary; do
    binaries=$((binaries + 1))
    test "$(xcrun lipo -archs "$binary")" = "$architecture"
    /usr/bin/codesign --verify --strict "$binary"
    if /usr/bin/otool -L "$binary" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/Library/)'; then
        echo "Non-system dependency in $binary" >&2; exit 1
    fi
done < <(find "$helper" -type f \( -name perl -o -name '*.bundle' \) -print0)
(( binaries > 1 ))

# With no PATH, HOME, or Perl environment, the packaged app must read a date that only
# ExifTool provides, using the interpreter and library inside the extracted bundle.
inc="$(env -i "$helper/perl/bin/perl" -e 'print join("\n", $^X, @INC)')"
while IFS= read -r entry; do [[ "$entry" == "$helper/"* ]] || { echo "Helper path outside bundle: $entry" >&2; exit 1; }; done <<<"$inc"
output="$(env -i PATH=/nonexistent "$app/Contents/MacOS/PhotoImport" --verify-metadata-helper "$(pwd)/Tests/Fixtures/create-date-only.jpg")"
echo "$output"
grep -qx "perl=$helper/perl/bin/perl" <<<"$output"
grep -q "version=$EXIFTOOL_VERSION\$" <<<"$output"
grep -qx 'date=2023-03-04 origin=ExifIFD:CreateDate' <<<"$output"
echo "Verified archive signature, architecture, icon, version, checksum, and the bundled metadata helper ($binaries signed binaries)."
