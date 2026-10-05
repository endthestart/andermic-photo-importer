# ADR-0003: General-purpose macOS importer with a core-first release

Status: accepted on 2026-10-04 through the twelve-question design interview; implemented on 2026-10-04 (see ADR-0004 and ADR-0005).

## Context

The prototype works for the owner's immediate card-clearing workflow, but personal defaults and a DxO-oriented interface need generalization. The owner wants a simple, no-frills application for Mac photographers that gains configurable import features in layers. They explicitly requested notes during discovery and chose a polished core release before advanced features.

## Decision

- Target macOS first using the current native foundation; Linux is a possible later platform.
- Default new users to their Pictures directory and year/month/day organization without an event name. Preserve existing choices on upgrade; keep other date/event layouts and custom templates.
- Use an Apple Photos-inspired selection grid and selected/all-new actions, with familiar side panels, visible common settings, saved presets, and expandable advanced sections. No wizard.
- Select/import related RAW/JPEG/sidecar files together by default, preserving all original bytes and verifying physical files individually.
- Make card-insertion behavior configurable while running: show/scan automatically by default, or quietly indicate availability. Copying always requires an import action.
- Keep first-release duplicate recognition as simple source/destination comparison with current reports and verified copies. No managed photo library is required.
- Ship a self-contained metadata helper/runtime and visible component licensing rather than requiring users to install ExifTool separately. The bundle/runtime implementation and licensing artifacts must be qualified before public distribution.
- Defer advanced persistent history/detection choices, filename templates, second-copy support, and source deletion to later updates.
- For the future deletion feature, successful verification is followed by a final confirmation showing source card and file count. When a second copy is enabled, both copies must verify before cleanup is offered. The remaining deletion contract is unresolved; no current-file deletion is authorized by the interview.

## Relationship to existing decisions

This updates the planned product scope of ADR-0001. The current alpha still uses separately installed ExifTool, personal defaults, a table preview, and source preservation. ADR-0002's bounded preview reads and verified-copy protections remain the baseline; persistent history remains a future implementation decision. No current implementation facts or validation results are changed by this ADR.

## Consequences

The first public release has a bounded usability, interoperability, and packaging scope. Advanced features are retained in the roadmap without delaying that release. Code remains unchanged during discovery. Public distribution still requires source/license decisions, genuine-camera and clean-machine qualification, Developer ID signing, notarization, and owner-controlled publishing.

References: [specification](../SPEC.md), [roadmap](../ROADMAP.md), [all twelve answers](../DESIGN-DISCOVERY.md), and [metadata/import-history research](../research/import-history-and-metadata-packaging.md).
