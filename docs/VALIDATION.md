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

## Menu-bar lifecycle (2026-10-05)

On Apple silicon, macOS 27.2, using isolated settings and synthetic photos:

- `./test.sh`: 119 checks pass, including background-launch defaults, migration, and saved startup/card preferences.
- Build, package, and extracted-package verification pass. The archive declares `LSUIElement`; app and all 49 helper binaries verify.
- The GUI exercise passes background launch with no visible window, tray reopening, regular/accessory activation changes after close/reopen, minimization, a 26-photo scan while hidden, independent startup/card settings, and a separate notices window keeping normal app presence until it closes.
- A second process reads the saved foreground-launch preference, starts with its window visible, closes to the menu bar, and reopens successfully.
- Existing import, cancellation/retry, sidecar, and synthetic-card ejection exercises still pass. All 88 destination files match source originals by SHA-256; no staging files remain.

Earlier GUI runs were disturbed by desktop input, including changes to fixture text and a folder template. The test-only driver now performs text setup and editing-menu assertions together and ignores physical keystrokes only within the automated test app. The shipped app has neither this driver nor input filtering. The final full run passed. The clipboard is restored after the exercise.

No real photos or cards were imported, modified, or ejected for these checks. Login Items enrollment and a reboot/login test have not been performed; the app only opens macOS settings for user-managed enrollment. New-photo counts and richer status-icon progress remain deferred (ADR-0007).

## USB camera sources (2026-10-25)

On the current Apple silicon build host:

- `./test.sh`: 147 synthetic checks pass. USB-specific cases cover short reads, stream-hash readback, private snapshots, symlinked working roots, RAW/JPEG/sidecar grouping, reused names across slots, camera provenance in reports, duplicate reimports, changed snapshot bytes, cleanup, premature EOF, oversized responses, disconnect errors, cancellation, unsafe paths, and case-insensitive catalog collisions.
- `./build.sh`, `./scripts/package.sh`, and `./scripts/verify-package.sh` pass. The extracted package verifies the camera-import entitlement, bundled helper, and all 49 helper signatures. The app remains locally ad hoc signed.
- Production source typechecking for the x86_64 macOS 13 target passes. This is not a live Intel execution test.
- `./scripts/ui-exercise.sh` passes, including synthetic USB discovery without automatic scanning, a 27-group camera preview, existing duplicate recognition, one newly imported USB original, rescan, removal, and disabled ejection. All 89 imported physical files match synthetic originals by SHA-256. Existing grouping, changed-sidecar, cancellation/retry, mounted-card ejection, menu-bar/window lifecycle, and foreground relaunch checks pass.
- The synthetic camera screenshot was visually checked. No physical-camera discovery is enabled in the GUI fixture build.

Early GUI runs exposed that Foundation normalizes macOS temporary paths through the `/var` symlink, even after URL symlink resolution. USB staging now uses a private disposable user-cache folder, with an isolated fixture folder injected during tests. The core source-symlink refusal is unchanged. The final full GUI run passes.

Read-only system identity discovery confirms that the connected Nikon Z 8 is exposed by ImageCaptureCore as a USB camera rather than a mounted card. After the owner explicitly approved the one-NEF check, a bounded diagnostic read the same original twice into memory and obtained identical SHA-256 digests. No image was viewed, no real original was saved to disk or imported into a library, and no camera file was changed or deleted. The verified build was installed at /Applications/Andermic Photo Importer.app, with the previous app retained locally and the settings file checksum unchanged. The installed app lists Z 8 after removable-volume permission is granted. A full library import, physical disconnect recovery, both camera slots, and large videos remain unqualified. This remains an ad hoc signed local development build, not a public binary release.

The live installed-app check also exposed a macOS removable-volume permission prompt. The camera service withheld device discovery while that permission was pending. Local app copies have different hash-bound designated requirements, and the former GUI test app shared the production bundle identifier. The GUI fixture now uses a distinct test-only identifier and display name. The full GUI exercise passed again under that isolated identity, with all 89 imported files verified byte-for-byte. A normal quit/relaunch of the unchanged installed build retained the grant: the camera service reported removable-volume access granted, and Z 8 appeared in the source sidebar without a new grant. New ad hoc builds can still require a fresh permission grant because the signature changes; stable certificate signing remains a separate owner decision.

### Empty camera hierarchy correction

The first installed-camera check confirmed discovery and a raw transport read, but did not exercise the production catalog adapter. The owner's subsequent preview exposed that gap: the Z 8 returned an empty `contents` hierarchy even though `mediaFiles` contained its originals. The earlier synthetic camera fixture constructed staging entries directly and therefore missed this adapter failure.

The production adapter now combines both catalog views and passes their metadata through a shared catalog collector. It recovers parent folders from flat entries, keeps hierarchy-only sidecars, removes duplicate object entries, and rejects incomplete or cyclic parent relationships and converted filenames. The GUI fixture now uses an empty hierarchy and a populated flat media list through the same collector. `./test.sh` passes 153 checks, including this regression. A read-only live diagnostic compiled with the corrected production adapter found every exposed NEF once, without reading image payloads or saving originals. The updated build, extracted-package verification, and x86_64 macOS 13 typecheck pass. The full synthetic GUI exercise also passes with the empty-hierarchy fixture, verifying all 89 imported files byte-for-byte. The corrected build was installed with the preceding app retained locally and the settings checksum unchanged. Full real-camera preview/import remains unqualified.

## Bounded-memory performance round (2026-10-25)

After the owner reported system-memory exhaustion during USB preview, a synthetic probe reproduced memory proportional to total bytes processed. Explicit per-buffer autorelease pools reduced the same optimized synthetic transfer from about 1,036 MiB peak RSS to 13.7 MiB, and a 1 GiB repeated hash from about 1,035 MiB to 9.2 MiB. See [PERFORMANCE.md](PERFORMANCE.md) and [ADR-0009](decisions/0009-bounded-working-memory.md) for workload limits and the implementation decision.

- `./test.sh`: all 153 functional safety checks pass after the streaming/metadata lifetime changes.
- `./scripts/performance-exercise.sh`: digest, camera snapshots, staged copies, repeated synthetic 4K JPEG thumbnails, cache clearing, and cancelled-delivery checks pass. Every mode remains below the 256 MiB incremental resident-memory regression guard. The exercise is now included in the CI and source-release job definitions; remote CI execution has not been run in this session. The measurements are in local build artifacts; no personal photo is used by this script.
- `./scripts/ui-exercise.sh`: the real synthetic AppKit workflows pass with one thumbnail decoder, the smaller advisory cache budget, and RAW embedded-preview policy. All 89 imported physical files verify against the synthetic source originals.
- Build, package creation, extracted-package verification, and x86_64 macOS 13 source typechecking pass. This does not establish Intel runtime memory behavior.
- The owner offered the connected camera for memory debugging. A bounded standalone ImageCaptureCore probe read one original eight times into memory, compared matching stream hashes, and peaked at 34.1 MiB RSS. No real image was viewed or saved and the photo destination was untouched. This is a transport-probe measurement, not a complete live-app/card import measurement.

The verified development app was installed with the previous version retained locally and the settings checksum unchanged. USB preview still stages every supported original on disk. Large destination enumeration and a full live-camera preview/import remain to be measured separately; the current round establishes the streaming memory regression and lower preview-memory budgets, without claiming to remove all disk/latency costs.

## Duplicate-check speed, selection buttons, and redraw correction (2026-10-25)

The owner subsequently reported slow checking, requested visible selection controls, and supplied a screenshot of overlapping preliminary/finished grid text. After the owner said importing was finished, all further development checks used synthetic files and fixtures.

- `./test.sh`: 158 checks pass. Added coverage verifies both complete hashes/read counts, cancellation, missing source/candidate failures, and rejection of a deliberate sample collision before finding a renamed exact match through the overlap path.
- `./scripts/performance-exercise.sh`: all modes pass, including paired hashing and the memory-growth guard. The final cached 1 GiB workload measured approximately 0.49 seconds sequentially and 0.26 seconds with paired readers. Physical-card speed after the change has not been measured.
- `./scripts/ui-exercise.sh`: passes the synthetic 754-group preliminary-to-finished transition, repeated Show Imported toggles, tile/header/frame integrity checks, Select All New/Deselect All buttons, and compact/normal layouts. Screenshots were visually checked: section headers and captions are single, current labels. Existing functional workflows still verify all 89 imported synthetic files byte-for-byte.
- Build, package/archive verification, and x86_64 macOS 13 source typechecking pass. Remote CI and live Intel execution remain unrun in this session.

Cross-volume comparisons use one additional hash worker; both full hashes and all identity, cancellation, collision, source-preservation, and final-verification rules remain mandatory. Same-volume comparisons stay serial. Read progress updates more frequently, date labels are cached per grid rebuild, and scan completion publishes one coherent view state. See ADR-0010. The new buttons preserve the existing menu/filter selection behavior.

The final speed/UI build was installed at the existing application path, with the previous build retained and the current settings checksum unchanged. Its executable matches the package-tested dist build. A native UI check confirms both quick selection buttons are present. No new card/camera scan or import was started after the owner finished importing.

## Full-card profile and three selection commands (2026-10-25)

The owner later offered a fresh full scan and reinserted the SD card. On the installed overlapped-verification build, a read-only mounted-card scan completed in 474.2 seconds for 754 originals, reporting 83.93 GB read to check 41.79 GB, all already imported. A six-minute monitoring interval peaked at 233.5 MiB RSS and 160.3 MiB physical footprint, with no process disk-write bytes recorded in that interval. A concurrent verifier sample spent approximately 96% of its samples waiting in source file reads. A bounded one-file comparison of 1/4/8/1 MiB buffers showed little material benefit (approximately 81–86 MB/s); production buffers remain unchanged. This is a real scan measurement, not a before/after speedup claim or a new import. Detailed profiles remain ignored local build artifacts. See PERFORMANCE.md for scope and limitations.

Select All, Select All New, and Deselect All now have distinct behavior as requested by the owner. All/New replace the selection using current filters; All includes imported and undated groups, New includes only importable new groups. Deselect All clears hidden selections too. Imported selections are re-verified before skipping, and undated new selections still require an explicit date before import.

Validation for the three-command refinement:

- `./test.sh`: 158 checks pass. The synthetic memory exercise passes all five modes, with peak RSS approximately 8.2 MiB for serial hashes, 10.5 MiB for paired hashes, 12.6 MiB for camera transfers, 9.5 MiB for staged copies, and 50.4 MiB for thumbnails.
- `./scripts/ui-exercise.sh` passes all workflows, including All=754/New=58, hidden-selection clearing, an undated All selection blocked from importing, text-field versus grid Cmd-A, and an already-imported All selection that verifies 39 files while copying zero. All 89 resulting fixture files byte-match synthetic originals, with the exact count also asserted. Button-frame checks and visual inspection confirm all three controls fit in normal and compact layouts with no overlapping grid text.
- Build, package/archive verification, and x86_64 macOS 13 source typechecking pass locally. Hosted CI and Intel runtime checks remain unrun. No personal originals were imported, changed, or ejected during this diagnostic and selection follow-up.

The package-tested three-button build was installed with the preceding app retained locally and the saved settings checksum unchanged. Its installed executable matches the dist build. The app was left closed while the real SD card remained inserted, avoiding an automatic repeat scan.


## Fixed-expiry preview cache (2026-10-25)

The owner approved the rebuildable preview-cache proposal and requested a 30- or 90-day TTL. ADR-0011 selects a fixed 30 days since the last complete hash, with no renewal by preview hits, and independent limits of 10,000 entries and 8 MiB serialized data.

- `./test.sh`: 200 synthetic safety checks pass. Cache coverage includes exact cold/warm/bypass/expiry reads, a hit at day 29 followed by expiry at day 30, clock rollback, signature/sample/root/path changes, count/byte bounds, bounded loading, corrupt input, private permissions, symlinks, missing destinations, import-seeded entries, and incorrect cached hashes. A deliberately stale cached match outside the Import All New selection prevents any copying or successful completion/ejection. Selected files are independently checked through the normal import path.
- The six-mode memory exercise passes, including 30,000 synthetic cache insertions and bounded eviction/save/reload. The cache mode measured about 51.0 MiB peak RSS and 4.45 MB serialized output.
- Apple silicon build, package/archive verification, Intel source typechecking, and the six-mode memory exercise pass on the final candidate, including the omitted-selection verification guard. Hosted CI and Intel runtime execution remain unrun.
- The first GUI attempt was blocked by the locked Mac. After the owner unlocked it, the full `./scripts/ui-exercise.sh` run passed. A warm 26-group preview uses cached matching evidence, Full Verification produces zero cached groups and complete reads, and the next scan reuses the refreshed hashes. Cached badges were visually inspected. Existing selection, cancellation/retry, sidecar, synthetic camera, card/ejection, and lifecycle workflows pass; exactly 89 imported synthetic files match source bytes. No personal originals were imported, modified, or ejected.
- The package-tested cache build was installed after the GUI pass. The previous app is retained locally and the saved settings checksum is unchanged. Installed, dist, and extracted-package executables match. The app was left closed to avoid another automatic real-card scan. The first scan without cached entries still performs full verification; subsequent unchanged previews can reuse them. Physical-card cached timing remains unmeasured.
