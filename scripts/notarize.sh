#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
profile="${NOTARY_PROFILE:?Set NOTARY_PROFILE to a stored notarytool Keychain profile name.}"
app_path="dist/Andermic Photo Importer.app"
test -d "$app_path"
details="$(/usr/bin/codesign -dvv "$app_path" 2>&1)"
if ! [[ "$details" == *'Authority=Developer ID Application:'* && "$details" == *'runtime'* ]]; then
    echo 'Build with a Developer ID Application SIGNING_IDENTITY and hardened runtime before notarizing.' >&2
    exit 1
fi
submission="build/notarization-upload.zip"
mkdir -p build
trap 'rm -f "$submission"' EXIT
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$app_path" "$submission"
xcrun notarytool submit "$submission" --keychain-profile "$profile" --wait
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
/usr/sbin/spctl --assess --type execute --verbose=2 "$app_path"
./scripts/package.sh
