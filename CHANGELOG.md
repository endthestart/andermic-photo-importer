# Changelog

## Unreleased

- Renamed Corvus (SENEX Corvus). Settings move to `Application Support/Corvus/`; earlier settings are adopted once and left in place.
- SENEX family design shared with Pictor: dark appearance, star-blue accent, capsule status badges, errors titled by what failed, and a Corvus constellation icon. Third-Party Notices moved to the app menu.
- Starts in the menu bar by default, with an optional window on launch and a shortcut to Login Items. Closing the window keeps work running.
- USB camera import through Image Capture, with verified staging of originals.
- Bounded working memory for hashing, staging, copies, and thumbnails.
- Source and destination hashes on different devices are read together. Select All, Select All New, and Deselect All buttons.
- A 30-day preview verification cache makes repeat scans fast. Imports still verify every file in full; File > Full Verification bypasses the cache.
- Repeat previews reuse verified capture dates and cached checks for unselected previous imports; the destination is listed in one pass.
- Optionally treat copies from the camera's other card as already imported. USB camera previews read originals on demand, and abandoned camera snapshots are cleaned up at launch.

Validation: 207 synthetic safety checks, the synthetic memory exercise, and build/package verification.

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
