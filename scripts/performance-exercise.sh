#!/bin/bash
# Synthetic streaming/thumbnail memory regressions. Never discovers physical
# cameras, uses personal photos, or writes to the configured photo destination.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(pwd)/build/performance-exercise"
mkdir -p "$root"
xcrun swiftc -swift-version 5 -O -module-cache-path build/module-cache \
    Source/Core/*.swift Source/App/PhotoGrid.swift Source/App/Theme.swift Tests/Performance/main.swift -o "$root/MemoryTests"
"$root/MemoryTests" make-thumbnail "$root"
: > "$root/results.jsonl"
for mode in digest paired-digest camera copy thumbnails cache; do
    "$root/MemoryTests" "$mode" "$root" | tee -a "$root/results.jsonl"
done
rm -f "$root/synthetic-4k.jpg"
echo 'Streaming, verified camera snapshots, staged copies, thumbnail/cache memory, and cancellation checks passed.'
