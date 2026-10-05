# Product specification

Status: first-public-release scope accepted on 2026-10-04 after twelve discovery questions. This specification distinguishes desired behavior from the shipped development alpha. The interview changed documentation only; implementation has not started.

## Product and audience

Andermic Photo Importer is a simple, no-frills, highly configurable utility for anyone on Mac who wants to import photo/video originals into ordinary folders. Use the existing native macOS foundation. Linux is a possible later platform, not a first-release requirement. Grow import configuration in layers using established photography workflows as references. RAW processing, lens/color correction, cloud synchronization, and a managed photo library remain outside the scope.

## First public release

1. **Destination and organization.** Default new installations to the user's Pictures directory and `{YYYY}/{MM}/{DD}`, for example `~/Pictures/2026/10/04/`. Let users change the root and folder preset/template, and remember their choices. Preserve existing configured destinations/templates on upgrade. Organize each file by its own camera-recorded capture day; multi-date imports require no event name. Keep event-based layouts optional.
2. **Single-window interface.** Use an Apple Photos-inspired central thumbnail grid with individual selection, selection counts, date/file-type filters, and separate selected/all-new import actions. Select new files by default. Combine this with familiar side panels, visible common settings, saved import presets, and expandable advanced sections. Do not use a wizard or expose unimplemented backlog settings as working features.
3. **Related files.** Select/import RAW+JPEG pairs and matching sidecars as one photo group by default, preserving every file byte-for-byte. Match within a source directory so reused names across directories are not conflated. Verify physical files individually and distinguish photo-group counts from file counts. Initial sidecar coverage, ambiguous pairing, inherited dates, and group-level filename collisions require detailed implementation rules.
4. **Sources and card insertion.** Support mounted camera cards and user-selected folders. While the app runs, default to showing the import window and automatically scanning a newly detected card for a preview. Users can choose quiet card availability indication and manual open/scan instead. Neither mode automatically copies files or disrupts an ongoing operation. Login/startup behavior is not decided by this scope.
5. **New-file detection.** Start with simple source-versus-destination comparison and existing lightweight import reports. Preserve meaningful content-confirmed duplicate detection across the selected destination root, including renamed files. Distinguish duplicate contents from filename collisions. Advanced persistent history, selectable detection methods, and complex missing/offline/edited-copy recovery come later.
6. **Safe copies and interruptions.** Preserve source originals and destination bytes; keep original filenames by default. Stage, flush, read back, verify, exclusively publish, and verify final destinations. Never overwrite an existing file. Keep completed verified copies after cancellation/failure, clean up the current staging file, report progress/errors, and let the user rescan to resume. Related-file collision handling must retain usable associations without overwriting files.
7. **Dates and previews.** Read the standard original-capture date through a bounded ImageIO header read without decoding image pixels, with complete metadata-helper fallback for unsupported containers or other date fields. Keep the camera's calendar day. Missing dates require an explicit fallback rather than silent invention. Thumbnail availability must not determine whether an original can be copied safely.
8. **Completion.** Keep optional editor handoff and safe card ejection after successful verification; the app must work without DxO installed. Only genuinely eligible source volumes may be ejected. Preserve the card on failure. General Finder/chosen-app completion actions from the initial review remain a design recommendation, not a settled integration contract.
9. **Self-contained installation.** Bundle the required metadata helper/runtime, expose open-source notices and applicable component licensing, and require no separate ExifTool/Homebrew installation for normal use. Public packages require Developer ID signing, notarization, clean-machine testing, and qualified supported macOS versions/architectures.
10. **Local independence.** No login, telemetry, app cloud service, or proprietary photo library. Store settings and reports locally; photos remain usable independently of the app. No source deletion in the first public release.

## Accepted advanced features — later updates

These are approved product directions, not prerequisites for the first public release. Their implementation order has not been selected.

- **Local history and detection options.** Remember imports and offer more than one detection strategy, including content hashes. History does not prove that a verified destination currently exists. Define missing/offline/edited-copy and explicit reimport behavior before adding recovery automation. Storage format and cache invalidation remain undecided.
- **Filename templates.** Preserve filenames by default; optionally rename destination copies using dates, camera information, sequence numbers, and custom text. Keep group members consistently named, preview the result, and never overwrite. Token coverage, sequence persistence, and group collision rules remain to be specified.
- **Second copy.** Offer an optional second verified copy to another drive/folder in advanced settings. When enabled, every included file at both destinations must verify before offering source deletion. Preserve successful copies and report each destination's result if the other fails. A second import copy is not automatically a complete backup strategy.
- **Delete after import.** Offer optional source cleanup only after the complete intended import verifies, followed by a final batch confirmation showing the source card and file count. If a second copy is enabled, both copies must verify. Deletion scope, eligibility of verified duplicates, option persistence, identity rechecks, cancellation/failure behavior, and cleanup/ejection ordering require a dedicated contract and tests. No current files may be deleted under these design notes.

## Current alpha behavior and limitations

The alpha uses `/Volumes/Photography/Photo Container` and `{YYYY}/{MM}-{DD} - {event}` as defaults, a table preview, and a separately installed ExifTool. It imports supported media originals but not source sidecars, has no selectable photo groups or per-file import selection, uses original filenames with collision suffixes, and copies to one destination. It detects mounted local removable DCIM volumes, keeps settings/reports in the prototype's `Photo Import` Application Support directory, offers DxO handoff and verified ejection, and never deletes sources. These facts must remain accurate in setup/release descriptions until implementation changes.

The scanner groups destination files by size and SHA-256 samples of their beginning, middle, and end (up to 96 KiB per file). Sample equality is only a candidate test: possible duplicates require full SHA-256 confirmation. New files are fully hashed during copying instead of preview. Source identity, size, modification/change times, staged readback, and final destination verification protect the import. Directory enumeration and duplicate-heavy full reads remain performance costs; no persistent hash cache exists yet.

Whole-file hashes change with embedded metadata edits. Genuine-camera compatibility, real destination-volume copies, physical ejection/editor handoff, earlier supported macOS versions, and worst-case large-library performance remain to be qualified. Read [validation](VALIDATION.md) for actual test evidence; do not equate synthetic containers with real RAW compatibility.

## Decision references

- [Discovery answers and remaining recommendations](DESIGN-DISCOVERY.md).
- [Core-first release decision](decisions/0003-core-first-public-release.md).
- [Roadmap and public-release qualification](ROADMAP.md).
- [Import history and metadata packaging research](research/import-history-and-metadata-packaging.md).
