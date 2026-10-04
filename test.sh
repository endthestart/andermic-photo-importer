#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
if [[ -n "${EXIFTOOL_PATH:-}" ]]; then
    tool="$EXIFTOOL_PATH"
else
    tool="$(command -v exiftool || true)"
    if [[ -z "$tool" ]]; then
        for candidate in /opt/homebrew/bin/exiftool /usr/local/bin/exiftool; do
            if [[ -x "$candidate" ]]; then tool="$candidate"; break; fi
        done
    fi
fi
if [[ ! -x "$tool" ]]; then echo 'Install ExifTool, or set EXIFTOOL_PATH to its executable.' >&2; exit 1; fi
xcrun swiftc -swift-version 5 -module-cache-path build/module-cache Source/ImportCore.swift Tests/main.swift -o build/ImportTests
build/ImportTests "$(pwd)/build/test-fixtures" "$tool"
