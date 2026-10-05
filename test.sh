#!/bin/bash
# Synthetic safety tests. Metadata fallback runs through the same pinned helper the app bundles,
# never an installed ExifTool.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
./scripts/build-metadata-helper.sh
helper="$(pwd)/build/metadata-helper/$(uname -m)/MetadataHelper"
xcrun swiftc -swift-version 5 -module-cache-path build/module-cache Source/Core/*.swift Tests/main.swift -o build/ImportTests
env -i HOME="$HOME" PATH=/usr/bin:/bin TMPDIR="${TMPDIR:-/tmp}" build/ImportTests "$(pwd)/build/test-fixtures" "$helper"
