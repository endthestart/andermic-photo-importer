# Product specification

## Purpose

Import new originals from a mounted camera card or selected folder into a configurable ordinary directory tree, safely and with minimal user input. Support a streamlined workflow into DxO without becoming a RAW editor or proprietary photo catalog.

## Required behavior

1. Native GUI with source, event, destination, folder presets/custom template, scan preview, cancellation, and import action.
2. Detect mounted local removable camera volumes containing DCIM. Probe independently in the background so unrelated volumes cannot block the UI. Integrated removable card readers are eligible.
3. Read the standard original capture date through macOS ImageIO without decoding pixels. Use separately installed ExifTool for unsupported containers or missing standard dates, with user ExifTool configuration disabled. Prefer original capture dates, then embedded creation dates. Require an explicit fallback for missing dates.
4. Organize each file using its own calendar date and the chosen event/template. Validate folder components and source/destination separation.
5. Import only supported new media originals, matching duplicates by SHA-256 contents across the selected root. Preserve filename collisions by adding a digest suffix.
6. Preserve original bytes and file timestamps. Stage, flush, read back, verify, exclusively publish, and verify final destinations. Never overwrite or delete originals.
7. Serialize this utility's imports into the same root with an OS file lock. Keep completed copies on interruption; allow repeat scans to resume safely.
8. Optional DxO folder-open request and optional eject only after successful final verification. Ejection must not target the destination volume or an ordinary source directory.
9. Local JSON settings and per-import JSON reports. No login, telemetry, cloud connection, or persistent catalog.

## Scan performance and verification

Preview groups destination files by size and bounded SHA-256 samples of their beginning, middle, and end (at most 96 KiB per file). Sample groups are built once per relevant size during the scan. Samples only eliminate different files; potential matches require complete SHA-256 confirmation. Renamed duplicates remain detectable. New originals are fully hashed during copying rather than during preview, with file identity, size, modification and change times checked against the preview and across copying. Import-time duplicate checks and staged/final copy verification remain mandatory. No persistent hash cache is introduced.

Scanning still enumerates the destination tree. Repeat scans containing many true duplicates still read full matching files, and unsupported metadata still requires ExifTool. These limits require measurement on real cards and libraries before making performance claims.

## Scope boundaries

No RAW development, color profiles, lens correction engine, cloud synchronization, photo catalog, source-sidecar migration, automatic rejection/deletion, or culling state in this release. These require separate product decisions. Same-byte RAW/JPEG pairs are unusual; different-byte pairs are both retained.

## Known qualification gaps

Whole-file hashes change with embedded metadata edits. There are no genuine-camera compatibility fixtures yet. Real destination-volume copies, ejection, DxO folder selection, early supported macOS versions, and worst-case large-library performance need further qualification. Source sidecars are counted as unsupported; embedded JPEG/DNG metadata is part of the preserved original bytes.
