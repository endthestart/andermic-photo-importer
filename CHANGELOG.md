# Changelog

## 0.1.0-alpha.2 — source preview (2026-10-05)

Initial public MIT-licensed source preview. Build locally on Apple silicon or Intel; no prebuilt app downloads or Apple notarization are included.

- Native thumbnail grid, new-photo selection, date/type filters, and selected/all-new imports.
- Configurable destination, date/event folder templates, and saved presets.
- Card detection and folder sources; scanning previews without automatically copying.
- RAW/JPEG/sidecar grouping, content-confirmed duplicates, verified copies, safe collisions, interruption reports, and retry.
- Self-contained, pinned Perl/ExifTool metadata reader with notices.
- Optional editor handoff and card ejection after successful verification.
- Fixes for changed/missing sidecars, root-level placements, later-placement failure/cancellation reporting, undated sidecar imports, and standard menu routing.

Validation: 118 synthetic safety checks plus build/package verification; both architectures run in hosted CI. Earlier GUI exercises used synthetic media. Real-camera workflows, older macOS versions, clean-machine installation, and signed app distribution remain unqualified; see [docs/VALIDATION.md](docs/VALIDATION.md).
