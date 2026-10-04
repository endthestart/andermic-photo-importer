#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="${APP_VERSION:-$(cat VERSION)}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$ ]]; then echo 'Invalid package version.' >&2; exit 1; fi
architecture="$(uname -m)"
app_path="dist/Andermic Photo Importer.app"
test -x "$app_path/Contents/MacOS/PhotoImport"
/usr/bin/codesign --verify --deep --strict "$app_path"
package="Andermic-Photo-Importer-${version}-${architecture}.zip"
package_path="dist/$package"
rm -f "$package_path"
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$app_path" "$package_path"
(cd dist && /usr/bin/shasum -a 256 "$package" > "$package.sha256")
echo "Packaged $package_path"
