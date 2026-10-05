# Product design discovery

Status: complete. All twelve questions were answered on 2026-10-04. Accepted decisions are recorded below; remaining review recommendations and engineering details are identified separately. This interview changed documentation only.

The owner requested a review of personal assumptions, followed by at most twelve questions, asked one at a time, to settle app design, features, and functionality. Record each answer here and carry accepted decisions into the specification and relevant ADRs. Preserve previously accepted safety requirements unless explicitly reconsidered.

## Personal assumptions to generalize

| Current assumption | Proposed treatment |
| --- | --- |
| Default destination is `/Volumes/Photography/Photo Container`. | Accepted: use the user's Pictures directory by default and remember changes. Preserve existing configured destinations. |
| The default folder layout is `{YYYY}/{MM}-{DD} - {event}`. | Accepted: default to `{YYYY}/{MM}/{DD}`. Keep other layouts and optional event naming as presets/custom configuration. |
| Event-based copy workflow and soccer placeholder dominate instructions. | Accepted: multi-date imports use year/month/day without a shared event label. Event naming is optional. |
| The completion action, settings fields, detection, and messages specifically target DxO PhotoLab. | General completion choices: no action, reveal in Finder, or open in a selected compatible application. DxO can remain a supported integration. |
| The app always remains running in the menu bar and foregrounds itself when a camera card mounts. | Accepted: automatic show/preview scanning is the default while running; users can choose quiet indication instead. Login/startup behavior remains unspecified. |
| No persistent catalog also currently means no persistent performance cache. | Accepted direction: local import history and selectable detection approaches. Start with simple source/destination comparison; do not add complex recovery behavior before it is needed. |
| Scope and qualification prose centers the owner's destination volume, cameras, and editor. | Define general supported-source, storage, format, and application requirements. Keep historical validation statements accurate rather than rewriting test history. |

## Implementation cleanup candidates

- Accepted packaging goal: ship the metadata dependency inside the app and expose open-source notices; ordinary users should not install ExifTool or Homebrew separately. The runtime/bundling implementation remains to be qualified.
- Choose a stable app-specific settings location and migrate the prototype's `Photo Import` settings if needed.
- The fixed calendar day used to validate a template is sample data, not an import-date default. Keep actual capture dates independent of that example.

## Requirements and identity to retain

Andermic branding, repository ownership, bundle identity, and an eventual Andermic domain are product identity rather than personal import preferences. Keep safe copies, source preservation by default, no overwrites, meaningful duplicate confirmation, transparent errors, and verified completion as core behavior. The requested future source-cleanup option requires a separate deletion contract; it does not alter the current alpha's source-preservation behavior. macOS is the primary target. Linux is a possible future target raised by the owner, not yet a committed release platform.

## Decision log

### Question 1 — audience (answered 2026-10-04)

The owner chose A: anyone on Mac who wants a simple, no-frills, highly configurable photo importer. Linux is a possible future target. Expand import configuration in layers, learning from Lightroom, ON1, and Capture One, while keeping RAW processing outside the product scope.

Additional decisions and research requests in the same answer:

- Default destination: the platform's user Pictures directory (`~/Pictures/` on a typical Mac), changeable and remembered. Do not replace an existing user's selected destination on upgrade.
- A shared event name does not fit a card containing unrelated photos across dates. Support date organization without an event; keep event-based naming as an optional workflow. The default date format has not been chosen.
- Investigate previously imported workflows and recovery cases in established and open-source importers before selecting an import-history strategy.
- Aim for a self-contained application with bundled metadata tools and visible open-source licensing. ExifTool bundling is feasible in principle; its Perl runtime, component notices, architecture support, and clean-machine behavior require implementation qualification.

These are specification decisions and requested work. The released alpha's runtime defaults and external ExifTool dependency have not yet changed.

### Question 2 — import history and detection (answered 2026-10-04)

The owner chose yes: the app may keep local records of what it imports and offer more than one detection approach, including duplicate/content-hash detection. Keep the initial scope simple: compare the selected source/card against the selected destination and lightly track import activity. The current behavior already meets the owner's immediate workflow because they normally clear the card after each import. Sophisticated recovery/history behavior is a future design option, not a requirement to implement now.

The owner explicitly requested notes only during this discovery step. Do not implement history, new detection modes, or source deletion as part of recording these decisions.

Additional requested future feature: an optional “delete after import” action, eligible only after all files intended for the import have been confirmed imported and verified. The owner emphasized concern about data loss. The deletion contract, confirmation behavior, persistence of the option, and treatment of already-existing verified duplicates remain unsettled.

Proposed safeguards, not yet an approved implementation contract:

- Off by default and explicitly enabled by the user.
- Only source files in the import's verified selection are eligible; do not format a card or remove unrelated/unsupported files or sidecars.
- Verify actual destination copies rather than relying on history, preview classifications, or a successful copy-call result. The current alpha already performs copy readback and final destination verification.
- Any import failure, missing/uncertain copy, cancellation, source change, or unavailable destination blocks cleanup for the batch.
- Resolve cleanup before optional ejection; identify the exact source device/files again before removing anything.
- Record deletion outcomes separately, including partial cleanup failures. Successful copying and successful source cleanup are different results.

### Question 3 — deletion confirmation (answered 2026-10-04)

The owner chose A: when “delete after import” is enabled, successful verification must be followed by a final confirmation showing the source card and the number of files to delete. Deletion does not proceed automatically solely because the option was enabled before import. Other deletion safeguards and option persistence remain under design; this answer authorizes a design requirement, not deletion of any current files.

### Question 4 — release platforms (answered 2026-10-04)

The owner chose A: macOS first, using the existing native app as the foundation. Linux remains a possible future platform, not a requirement for the first public release. No cross-platform rewrite is requested during this discovery work.

### Question 5 — default folder layout (answered 2026-10-04)

The owner chose B: year/month/day (`{YYYY}/{MM}/{DD}`), for example `~/Pictures/2026/10/04/`. Organize each photo by its own recorded capture date; no event name is required for this default. Retain other date layouts, optional event layouts, and custom templates. Preserve existing users' chosen templates on upgrade.

### Question 6 — configuration presentation (answered 2026-10-04)

The owner chose a mix of A and B and explicitly rejected C: a simple single-window importer with familiar Lightroom-style side panels, saved import presets, visible common settings, and expandable advanced sections. Avoid a step-by-step wizard. The detailed arrangement and selection controls remain to be designed; this answer does not require every advanced setting to be permanently visible.

### Question 7 — import selection and visual reference (answered 2026-10-04)

The owner answered yes to selecting a subset of new files and emphasized that they really like the Apple Photos import screen. Retain the proposed default selection of all new files, individual selection, and date/file-type filters. Use Apple Photos as the primary reference for the central import preview: a thumbnail grid, visible selection counts/status, and clear selected-versus-all-new import actions. Keep the configurable side panels and expandable advanced sections accepted in question 6; do not introduce a wizard or a managed photo library.

Apple documents “Import [number] Selected” and “Import All New Photos” for storage/card imports in its [Photos import guide](https://support.apple.com/en-ie/guide/photos/phtae4e05c67/mac). That is the action pattern to adapt; our exact selection defaults, duplicate classifications, and configuration remain governed by this app's decisions. This is a UI design direction, not an implemented thumbnail-grid change.

### Question 8 — related-file grouping (answered 2026-10-04)

The owner chose A: RAW+JPEG pairs and matching sidecars are selected/imported together as one photo group by default, preserving each original file byte-for-byte. Grouping is a selection/organization concept, not a conversion or merge. Associate files within the same source directory so reused basenames on different cards or in different folders do not accidentally become one group. The supported sidecar types and ambiguous pairing rules remain to be specified.

Any future source cleanup must verify every included group member individually. Display both photo-group and physical-file counts where needed, including deletion confirmation. The current alpha does not yet import source sidecars or group selections; retain that limitation in descriptions of existing builds.

### Question 9 — second import copy (answered 2026-10-04)

The owner chose A: support an optional second copy to another drive or folder as an advanced import option. Verify both destination copies. When enabled, both must succeed before the app offers source deletion; an unavailable destination, missing group member, failed copy, or failed verification prevents cleanup. Preserve successful copies if the other destination fails and report each destination's outcome distinctly. A second copy is not automatically a complete backup strategy.

The current alpha copies only to the primary destination. This answer records the desired feature and verification requirement; it does not schedule implementation during discovery.

### Question 10 — import-time renaming (answered 2026-10-04)

The owner chose A: preserve camera filenames by default and support optional naming templates using dates, camera information, sequence numbers, or custom text. Renaming applies to destination copies, preserving source filenames and original bytes. Keep related RAW/JPEG/sidecar files consistently named so grouping survives import. Show proposed names before import and retain no-overwrite collision handling. Token coverage, sequence persistence, and group-level collision rules require implementation specification; they are not yet available in the alpha.

### Question 11 — card-insertion behavior (answered 2026-10-04)

The owner chose A with an explicit configuration requirement: default to showing the import window and automatically scanning for a preview, but offer B (quiet card availability indication, user opens/scans on request) as a user-selectable option. Both modes apply while the app is running; neither starts copying automatically. Keep ongoing operations undisturbed when another card appears. App startup/login behavior is not decided by this answer.

### Question 12 — first public release scope (answered 2026-10-04)

The owner chose A: deliver a polished core importer first. The first public release focuses on Apple Photos-style selection, configurable folders, reliable verified copying, and a self-contained installation. Advanced persistent history/detection choices, template-based filename renaming, second-copy support, and source deletion are approved product directions for later updates, not first-release blockers.

Keep the core decisions from earlier answers: macOS first, Pictures/year/month/day defaults, optional event naming, saved import presets, related-file grouping, configurable card-insertion behavior, and explicit user-triggered copying. Source deletion remains absent from the first public release. The interview is complete; do not ask additional discovery questions under this twelve-question sequence.

## Consolidated outcome

[Product specification](SPEC.md), [release roadmap](ROADMAP.md), and [ADR-0003](decisions/0003-core-first-public-release.md) distinguish the current alpha, the first public release target, and later advanced features. No runtime or packaging changes were made during this interview. Implementation begins only under a subsequent implementation request; the owner's notes-only instruction remains in effect.

Research: [import history and metadata packaging](research/import-history-and-metadata-packaging.md).
