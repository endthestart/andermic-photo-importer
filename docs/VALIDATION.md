# Validation

## First-release implementation (2026-10-04)

Environment: Apple silicon Mac, macOS 27.2, Swift 6.4. Every fixture is synthetic. No personal photos were imported, and no real card was imported from, written to, or ejected. One incident: during the first GUI launch, a real Nikon card was already mounted, and the default show-and-scan behavior previewed it read-only (headers, samples, and thumbnails) before the synthetic folder replaced it as the source. Later runs used “only show availability”. Real-camera RAW files were not available as approved fixtures.

**Safety tests (`./test.sh`).** 89 checks pass, up from 39. All prototype checks remain. New coverage:

- the bundled helper's clean environment and pinned version;
- ExifTool fallback for a date that ImageIO's bounded read cannot see;
- refusal of a missing helper;
- RAW+JPEG, case-insensitive, video+THM, and full-filename sidecar grouping, plus orphan sidecars and reused names across directories;
- inherited companion dates and undated groups;
- multi-date year/month/day layouts without an event name, and structure changes without rereads;
- subset selection and byte equality of every group member;
- partial duplicates, and sidecar-only differences that are not selected by default;
- group-wide collision suffixes, including full-filename sidecars, with rescan recognition;
- cancellation mid-import with accurate outcomes and reports, rescan, and retry;
- prototype-settings migration that leaves the old file untouched, new-user defaults, persisted presets and card behavior, and preservation of an unreadable settings file;
- a case-insensitive overlap check, and undated duplicates within one source refused before any copy (both added after an independent review).

**Packaging (`./build.sh`, `./scripts/package.sh`, `./scripts/verify-package.sh`).** Perl 5.44.0 and ExifTool 13.59 build from checksum-verified upstream archives in about 1 minute 45 seconds. The app is about 60 MB; the arm64 ZIP is about 19 MB. Verification extracts the ZIP and checks:

- signatures of the app and all 49 nested binaries;
- that each nested binary is arm64 and links only to `/usr/lib` and `/System/Library`;
- that the manifest matches the lock file and all license files are present;
- that Perl's `@INC` stays inside the bundle;
- that `env -i PATH=/nonexistent … PhotoImport --verify-metadata-helper` reads `ExifIFD:CreateDate` through the packaged interpreter.

This shows the packaged app uses its own runtime without PATH, Homebrew, or the system Perl. It is not a clean-machine test: the system Perl and Homebrew ExifTool were still present on the disk, just unused.

**GUI exercise (`./scripts/ui-exercise.sh`).** A test-only build drives the real window controls: buttons, tiles, popups, and alert buttons, with isolated settings. Card-insertion behavior was set to “only show availability” so a mounted real card was never selected. Physical mouse input was not used, because this session had no assistive access. On a 26-photo, 39-file synthetic card covering three days, with RAW+JPEG pairs, XMP sidecars, a video+THM pair, an orphan sidecar, an undated photo, a renamed duplicate, and a name collision in the destination:

- 23 of 26 photos were preselected; 2 undated photos were excluded with an explanation.
- Deselecting 3 photos and importing 20 copied 32 files into three day folders.
- A rescan showed 21 photos as imported.
- Choosing a fallback date made the 2 undated photos importable.
- The collision gave `DSC_0003.JPG` and `DSC_0003.NEF` one shared suffix and left the existing file unchanged.
- On a 6 × 150 MB card, Stop during the import kept the copies verified before it (3 or 4 of 6, depending on timing), marked them imported, and offered the rest. **Import All New** completed them.
- Attaching a synthetic ExFAT disk image with `DCIM` triggered an automatic scan in show-and-scan mode. A fallback date chosen for the previous source was not carried over.
- After a fallback date was chosen for its 2 undated photos, the disk-image card was imported in full (39 files) and then ejected. The app does not eject while new photos remain on a card.

Afterwards, all 83 imported files matched a source original by SHA-256, and no staging files remained. Screenshots: [docs/screenshots](screenshots/).

**Scan measurements.** None of these are real-card benchmarks:

| Workload | Data | Results |
| --- | --- | --- |
| Synthetic, OS-cached files (12 × 16 MiB new originals, 12 same-size unrelated destination files) | 384 MiB | Groups listed after about 0.001 s; preview complete after about 0.007 s. Reads: 3.0 MiB headers, 2.25 MiB samples, 0 bytes fully hashed. |
| GUI scan of the 26-photo synthetic card | 1.2 MB | 0.2 s, including ExifTool fallback for 10 undated synthetic RAW/video files. |
| Rescan after importing the 6 × 150 MB card | 944 MB of photos | 1.0 s and 1.89 GB read: confirming duplicates requires full reads of both copies. |

Real-card throughput, ExifTool cost on genuine RAW files, and very large destinations remain unmeasured.

**Not yet qualified:** genuine camera metadata and grouping; real cards and destination volumes; physical ejection; DxO handoff; clean-machine installation; macOS versions earlier than 27.2; Intel beyond CI build/test/package; Developer ID signing; and notarization with nested Perl code.

## Review fixes (2026-10-05)

Three reproduced review findings were fixed on the same branch.

- **Changed sidecars.** The previous engine imported a changed sidecar alone as `DSC_0001__<hash>.xmp`. That name matched no photo, a rescan still reported the group as changed, and every repeat added another `-1`, `-2`… copy. The new regression test fails on the previous engine. Changed sidecars now arrive with a verified copy of their photo under one shared suffix; missing sidecars go beside the imported photo; rescans recognize both; and a repeat import copies nothing (ADR-0005).
- **Menus.** Copy, Paste, Cut, Select All, Close Window, Minimize, and Zoom were targeted at the app delegate, which implements none of them, so they never reached the text field or window. They now use the responder chain. The GUI exercise invokes the real menu items through AppKit's routing and checks where each lands: the field editor for editing commands, the window for Close and Minimize, the photo grid for Select All when a text field is not active. It also checks the result: text selected, copied, cut, and pasted (the clipboard is restored afterwards and never logged), the window minimized and restored, the window closed and reopened.
- **Undated sidecar-only imports.** These were blocked by a fallback-date requirement whose control was hidden. Sidecars of imported photos now go beside the photo and need no date. The fallback control is shown whenever any importable photo still needs a date.

Evidence on Apple silicon, macOS 27.2, synthetic fixtures only:

- `./test.sh`: 100 checks.
- Build, package, and package verification pass.
- The GUI exercise passes all 137 steps and byte-verifies 88 imported files. Its changed-sidecar step left the card's original sidecars unchanged in the destination and produced `DSC_0006__…{JPG,NEF,XMP}` and `MVI_0026__…{MOV,THM}`, including the undated video, with no fallback date.

## Placement fixes (2026-10-05)

Two independently reproduced cases were fixed:

- **Sidecars beside photos directly in the destination root.** These were refused as "outside the destination". The root itself is now a valid placement folder, while paths outside the root, look-alike sibling folders, and symlinked folders are still refused.
- **Staging failure in a later placement of the same group.** It skipped the code that records results, so sidecars already published were missing from the failure outcome and the report.

The new tests reproduce both on the previous engine. The root-level import was refused, and the staging failure reported 0 copies. They also cover:

- root-level missing and changed sidecars, including byte preservation, rescan recognition, and zero-copy repeats;
- a two-placement group whose second placement fails while staging and, separately, is cancelled after the first is published. Each case checks counts, outcomes, receipts, preserved bytes, the absence of staging files, and a retry that copies only the remaining sidecar.

`./test.sh` passes 118 checks. Build and package verification also pass.

## Prototype and foundation (earlier)

The initial prototype passed 32 synthetic safety checks and a full native GUI import/repeat scan on an Apple silicon Mac with macOS 27.2 and Homebrew ExifTool 13.55. The repository foundation passed 39 checks, including bounded preview reads, deliberate sample collisions, unsampled source changes, and large renamed duplicates. A mounted Nikon card was detected, but real photos were neither imported nor ejected.

Hosted build results are in [GitHub Actions](https://github.com/endthestart/andermic-photo-importer/actions). Both architectures must pass before a tagged build can create a draft release.

## Source preview preparation (2026-10-05)

The owner approved a MIT-licensed source-only preview and deferred Apple Developer Program enrollment (ADR-0006). The current local pipeline passes 118 synthetic safety checks, builds the arm64 app, packages it, and verifies the extracted bundle. Package verification now also compares the app’s MIT license and third-party summary against the repository files. Both workflow files parse as YAML and changed shell scripts pass syntax checks.

An inspection of 149 Git objects, including historical text blobs, found no candidate private-key, GitHub-token, API-key, or absolute-home-path matches. The main screenshot was visually checked and contains synthetic images. This bounded inspection is not a guarantee that every possible secret pattern is detected. No personal photo library, real-card import, or ejection was used for this preparation. Existing user settings were read for configuration presence and left unchanged.

The first local icon-generation attempt failed inside the execution sandbox. The normal build succeeded when run with macOS system access; no app code was changed for that environment restriction. Source previews do not claim to close the live qualification items above.
