# Corvus cleanup audit, October 2026

Scope: the full checklist in `~/Development/plan/cleanup-playbook.md`, plus design, UI/UX and roadmap. The audit covered branch `claude/corvus-pictor-design-0851ec` on 2026-10-30, after the Corvus rename and SENEX design commit (`adaea03`) and the merge of `origin/main` at `0f5f055`.

Host: Mac Pro, Intel Xeon W-3245 (16 cores), 192 GB, macOS 15.7.4. Tools: Swift 6.2.4 (swift-driver 1.127.15), swift-format 6.2.3, Apple LLVM 17 llvm-cov, gitleaks 8.30.1. These tools are **not installed**, so their checks were done by hand or skipped: periphery, swiftlint, shellcheck, actionlint, git-sizer, lychee, jscpd, scc/tokei/lizard. Read-only tools ran at `nice 19`. Every number below was measured; none is estimated. Fixtures were synthetic only. No real card, camera or personal photo was opened, and the Hidden export was not touched.

The audit kept no caches. The 3.8 GB scan fixtures, the coverage build, the idle-probe app and the aborted UI-exercise output were all deleted.

## Summary

| Area | Finding | Action |
|---|---|---|
| Performance | Idle in the menu bar: 0.00 s CPU, 0 wakeups and 20 MB over 60 s. A cold scan keeps one core busy at 2.6 CPU-s per GB hashed. A warm (cached) scan is near-free. | The owner's fans most likely came from the old Oct 5 build's full scans (see below). Two options for owner question 3. |
| Tests | 207 checks pass in 16 s. Core line coverage is 93.3%. The production settings paths were untested. | Fixed: `227201c`. |
| CI | The performance exercise did not compile after the theme change, and CI runs it. | Fixed: `7a2dbde`. |
| Docs | The CHANGELOG stopped at Oct 5, the ROADMAP named the retired Aperture A branding, and build variables were undocumented. | Fixed: `c6b74be`, `11f8a85`. |
| Storage | A passing UI exercise leaves 1.8 GB of fixtures. The main checkout's `build/` is 2.4 GB. | Fixed going forward (`344b221`). The existing folders are owner question 4. |
| Size | `MainWindow.swift` (1,216 lines) and `ImportCore.swift` (1,005 lines) break the 300-line rule. | Owner question 7; not refactored during cleanup. |
| Dead code | None found. The 19 candidates are all framework callbacks. | — |
| Secrets | gitleaks: 15 commits, no leaks. | — |

## 1. Dead and duplicate code

- **Unused declarations:** a whole-repo reference count (declarations named only once across `Source`, `Tests` and `scripts`) found 19 candidates. All are AppKit, ImageCaptureCore or NSCollectionView callbacks and overrides (`applicationShouldHandleReopen`, `deviceDidBecomeReady`, `numberOfSections`, `draggingEntered`, `intrinsicContentSize` …). False-positive pattern: protocol and override methods are called by the frameworks. **No removal candidates.** Confidence: medium, because periphery is not installed.
- **Code nothing runs:** for `Source/Core`, coverage below lists what the safety suite never reaches. The App layer is exercised only by `scripts/ui-exercise.sh`.
- **Old next to new:** two legacy settings folders are adopted on purpose (`Andermic Photo Importer/`, then the prototype's `Photo Import/`), as `docs/SPEC.md` requires. Keep them until every install has run a Corvus build once.
- **Duplicates:** not measured (jscpd is not installed).

## 2. Dependencies

- **Runtime:** system frameworks only, plus the pinned helper (`scripts/metadata-helper.lock`): Perl 5.44.0 and ExifTool 13.59, checksum-verified.
- **Perl:** 5.44.0 is the latest stable (cpan.org on 2026-10-30; 5.45.x is a development series).
- **ExifTool:** **13.60 is available** (exiftool.org `ver.txt`). A bump needs its published SHA-256, updated notices and confirmation that it is a production release (owner question 5).
- **No package manager or lockfile** beyond the helper lock. CI pins actions by full SHA (checkout v7.0.1, cache v6.1.0, upload-artifact v7.0.1).
- **Toolchain:** not pinned. CI uses the runner's Xcode Command Line Tools.

## 3. Repository hygiene

- **History:** `.git` is 11 MB in the main checkout and the pack is 9.5 MiB. The largest blobs are the old 1.8 MB icon and the 0.5–0.6 MB screenshots. No build output is tracked, and `.gitignore` covers `build/`, `dist/`, apps, archives and signing material.
- **Branches:** `origin/feature/core-first-release` and `origin/feature/menu-bar-lifecycle` (both Oct 5) were squash-merged as PRs #1 and #2 but still exist, locally and on the remote (owner question 6).
- **Worktrees:** two (the main checkout and this branch).
- **Main checkout:** at `4f2dc89`, two commits behind `origin/main`.
- **Secrets:** gitleaks 8.30.1 found no leaks in 15 commits (~988 KB).
- **Stray files:** none at the root.
- **Second writer:** another session pushed `0f5f055` to `origin/main` during this audit. The PM was asked to coordinate, to keep one writer per repository.

## 4. Lint, format and types

- **Compiler:** zero warnings with `swiftc -swift-version 5 -typecheck` on all sources.
- **Swift 6 language mode:** stops at its first error, ``static property 'fm' is not concurrency-safe`` (ImportCore). The full count is unknown until that is fixed.
- **Formatter:** none is configured. `swift-format lint` with default rules reports 7,534 findings: 3,971 Indentation, 2,005 DoNotUseSemicolons, 1,175 LineLength, 156 AddLines, 146 OneVariableDeclarationPerLine and smaller counts. Most come from the house style (4-space indents, `;`-joined statements, long lines), not from defects. A `.swift-format` file matching that style would give a usable baseline (owner question 8).

## 5. Tests

- **Safety suite:** 207 checks, 16.4 s wall (13.5 s user). All synthetic, no skips. No flaky failures in seven full runs this session.
- **Core line coverage:** 93.3% (regions 85.9%, functions 86.3%).

  | File | Lines covered |
  |---|---|
  | `Settings.swift` | 67.0% |
  | `MetadataHelper.swift` | 85.7% |
  | `CameraStaging.swift` | 91.5% |
  | `ImportCore.swift` | 95.2% |
  | `Grouping.swift` | 98.5% |
  | `CameraCatalog.swift` | 98.7% |
  | `DuplicateVerificationCache.swift` | 99.2% |

- **Critical path with no test:** the production settings folder and the order of legacy folders after the rename. Fixed in `227201c`. What remains uncovered is `MetadataHelper.bundled()`, which the package verification exercises.
- **App layer:** selection, filters, ejection eligibility and window lifecycle are covered only by the GUI exercise. That exercise **could not run** on this audit, because window capture fails while the screen is locked (`CGSSessionScreenIsLocked = true`). Rerun it once the Mac is unlocked.
- **Mocks:** the camera tests use an injectable transport rather than a camera. The owner's rules allow this, because real cameras are off-limits without authorization.

## 6. Docs

- **README commands:** `./test.sh`, `./build.sh`, `./scripts/package.sh`, `./scripts/verify-package.sh` and `./scripts/performance-exercise.sh` were run and pass. `./scripts/ui-exercise.sh` is blocked by the locked screen.
- **Links:** 24 Markdown files, 0 broken relative links (checked by script; lychee is not installed, so external links were not checked).
- **ADRs:** 0001–0011 all carry a status line. ADR-0001's product line now records the rename.
- **CHANGELOG:** ended at 0.1.0-alpha.2 (Oct 5), missing the menu-bar lifecycle, USB camera, memory, cache and rename work. Fixed in `c6b74be`.
- **ROADMAP:** still said "accepted Aperture A branding" and omitted the shipped USB camera and cache work. Fixed in `c6b74be`.
- **Undocumented inputs:** `BUILD_NUMBER`, `-CorvusSettingsDirectory` and `-CorvusUIScript` were read but documented nowhere. Fixed in `11f8a85`.
- **README screenshots:** they still show the pre-SENEX look, and will be refreshed from the next GUI exercise.
- **AGENTS.md and CLAUDE.md:** match the repo. `CLAUDE.md` imports `AGENTS.md`.

## 7. Scripts, config and CI

- **Shell syntax:** all shell scripts pass `bash -n` (shellcheck is not installed).
- **Environment variables:** every one read by a script is now documented.
- **Performance exercise:** broken by the theme change. Fixed in `7a2dbde`.
- **UI exercise:** left about 1.8 GB of fixtures after each pass. It now keeps only its logs after a pass (`344b221`); a failed run still keeps everything for inspection. This change is not yet exercised, for the same locked-screen reason.
- **Workflows:** both are live (`ci.yml` on pushes and PRs, `release.yml` on tags). Neither is dead.

## 8. Complexity hotspots (not refactored)

| File or function | Size | Suggestion |
|---|---|---|
| `Source/App/MainWindow.swift` | 1,216 lines | Split into sidebar, grid, inspector and import-flow controllers |
| `Source/Core/ImportCore.swift` | 1,005 lines | Split into hashing, planning, copy/publish and reports |
| `UIAutomation.tick` | 207-line function | Table-driven command handlers |
| `Importer.run` | 141-line function | Extract per-group copy and verification steps |
| `Tests/main.swift` | 776 lines | Split by area (migration, grouping, cache, camera) |

`scripts/ui-exercise.sh` (436 lines) also breaks the 300-line rule.

## 9. Stale plans and TODOs

- No `TODO`, `FIXME`, `XXX` or `HACK` comments in tracked files.
- `docs/PERFORMANCE.md` lists open work: USB previews still stage every original. That item is now on the roadmap.

## 10. Storage

| Item | Size | Tracked | Proposal |
|---|---|---|---|
| Main checkout `build/ui-exercise` | 1.8 GB | no | Delete; self-cleaning from `344b221` (owner question 4) |
| Main checkout `build/module-cache` | 299 MB | no | Delete when idle; rebuilt by the next build |
| Main checkout `build/installed-backup-20261005-185204` | 60 MB | no | The owner's backup of the Oct 5 app. Keep or move to the NAS (owner question 4) |
| Main checkout `build/` (other) | 168 MB | no | Rebuildable: helper (57 MB), downloads (28 MB), archive check (60 MB) |
| Main checkout `dist/` | 79 MB | no | Rebuildable |
| This worktree's `build/` and `dist/` | 612 MB (536 + 76) | no | Goes when the worktree is cleaned up |
| Repository history | 9.5 MiB pack | yes | Fine |
| App data on this Mac | none | — | The owner's installed copy runs on another Mac |

Standing rule: generated fixtures live under `build/` and each script deletes its large fixtures after a pass. `test.sh` and `performance-exercise.sh` already do; `ui-exercise.sh` does from `344b221`.

## 11. Performance

**The owner's note:** "I'm using Andermic Photo Importer and it's currently using a bit fo my CPU and making my fans spin up." On the same day, the other session recorded in `docs/VALIDATION.md` that the copy the owner was running was the **Oct 5 build**. That build had no verification cache and was doing a full-hash preview scan when inspected. The tested cache build then scanned the real card warm in **19.71 s with zero full-hash bytes**. The earlier uncached build took 474.2 s and read 83.93 GB.

Measured on this Mac Pro with the current build (optimized, synthetic data):

| Workload | Wall | CPU | Peak memory |
|---|---|---|---|
| Menu-bar idle, no window, 60 s (`top`, 13 samples) | — | 0.00 s, 0.0 %, 0 idle wakeups, 3 threads | 20 MB footprint, 47 MB RSS |
| Window-open idle | not measurable while the screen is locked | | |
| Cold scan: 24 × 80 MB duplicates, card and library on one SSD (3.8 GB hashed, serial) | 10.07 s | 9.90 s | 27.5 MiB |
| Warm scan of the same, 24 cache hits | 0.25 s | 0.07 s | 7.1 MiB |
| `digest` 1 GiB / `paired-digest` 1 GiB | 2.62 s / 1.31 s | — | 17.0 / 16.0 MB |
| `thumbnails` (128 renders of a 4096-px JPEG) | 3.04 s | — | 49.2 MB |
| `cache` (30,000 records) | 3.23 s | — | **181.4 MB** (51.0 MiB on Apple silicon in `PERFORMANCE.md`) |

- **Interpretation:** idle costs nothing. Card and camera detection is notification-driven with no polling, and thumbnails run one at a time.
- **Where the heat comes from:** a cold scan with many already-imported photos. SHA-256 runs at ~380 MB/s on one core of this Xeon, which has no SHA instructions, so hashing the destination copies keeps a core at 100% for minutes. The cache removes this on repeat scans of the same card.
- **Concurrency:** scans and the second hash reader run at `.userInitiated`, even for background scans the user didn't start. At most one extra reader runs, and only when source and destination are on different devices.
- **The `cache` exercise:** peaks 3.5× higher on Intel than on Apple silicon. It is still under its 256 MiB guard, and real use is far smaller (1,508 entries). Worth a look if the cap is ever raised.
- **Dev speed:** `test.sh` 16.4 s, `build.sh` 59.5 s (helper cached), `performance-exercise.sh` 63.2 s. The Swift module cache is 299–391 MB per checkout.

## 12. Design and UI/UX

- **Branding:**
  - The app follows `docs/DESIGN-TOKENS.md` v1, shared with Pictor, and tests check the colour, radius and type tables against it.
  - The rename is complete, including the bundle ID `com.senexapps.corvus`. The verification cache is adopted once, so the first scan after updating stays warm.
  - Historical docs (`VALIDATION.md`, `PERFORMANCE.md`, `DESIGN-DISCOVERY.md`, `research/`) keep the old name as a record.
- **Contrast (WCAG):**

  | Pair | Ratio |
  |---|---|
  | TEXT on GROUND | 15.7:1 |
  | MUTED on CHROME | 7.8:1 |
  | GROUND on ACCENT | 9.1:1 |
  | GROUND on GOOD | 8.6:1 |
  | GROUND on WARN | 9.4:1 |
  | GROUND on BAD | 6.5:1 |
  | TEXT on a badge scrim over a white photo | 8.5:1 |

  White text on ACCENT would be 2.1:1, which is why fills take GROUND text.
- **Accessibility:**
  - Tiles are checkboxes with full labels.
  - Badges always pair colour with text.
  - Section labels expose sentence-case names.
  - The new progress bar reports its role and value.
  - VoiceOver was not run: the screen was locked.
- **macOS conventions:**
  - Native controls keep the system accent, a known seam: AppKit has no app-wide accent override without an asset catalog.
  - **Settings… (⌘,) opens the main window's Import Options panel** rather than a Settings window. That is unusual for a Mac app but deliberate in ADR-0005's single-window design. Leave as is unless the owner wants a window.
- **Error states:**
  - Errors that stop the work are sheets titled by what failed ("Scan did not finish", "Photos need a capture date").
  - Scan failures also appear in the footer status line, and folder-preview errors appear inline in BAD.

## 13. Roadmap

- **Next, in order:**
  1. Run the GUI exercise and the physical card reinsertion on the current build (both blocked by the locked screen), and refresh the README screenshots.
  2. Install the renamed app in place of the old one (README, "Moving from Andermic Photo Importer").
  3. Push this branch and open a PR.
  4. Complete the qualification list in `docs/ROADMAP.md` (real-camera fixtures, older macOS, clean install, Developer ID and notarization).
  5. The USB remote-reader design from `docs/PERFORMANCE.md`.
- **Stale (fixed in `c6b74be`):** the branding line, and shipped work missing from the first-release list.
- **Still accurate:** the later-update list (history, filename templates, second copy, delete after import) and the deferrals (richer menu-bar status, Linux, culling).

## Owner questions

Each comes with a recommendation; the PM sends them one at a time.

1. **Bundle ID:** answered. The owner registered senexapps.com, and Corvus now uses `com.senexapps.corvus`, matching Pictor.
2. **Push:** push `claude/corvus-pictor-design-0851ec` and open a PR to `main`? Recommendation: yes, after the GUI exercise passes.
3. **Background scan heat:** (a) run scans the user didn't start (background card insertion, launch scans) at `.utility`; (b) confirm duplicates by comparing the two files byte for byte instead of hashing both, which avoids most SHA-256 work; (c) leave as is. Recommendation: first confirm whether the fans still spin with the current build, which has the cache; if they do, (a). (b) changes import safety and needs its own ADR.
4. **Disk space in the main checkout:** delete `build/ui-exercise` (1.8 GB) and `build/module-cache` (299 MB), and keep or move to the NAS `build/installed-backup-20261005-185204` (60 MB)? Recommendation: delete the first two, move the backup.
5. **ExifTool 13.59 → 13.60?** Recommendation: only if 13.60 is a production release, with its SHA-256 and notices updated.
6. **Delete the merged remote branches** `feature/core-first-release` and `feature/menu-bar-lifecycle`? Recommendation: yes.
7. **Split `MainWindow.swift` and `ImportCore.swift`** to meet the 300-line rule, as a separate refactor after this branch lands? Recommendation: yes, one file per PR with the GUI exercise.
8. **Formatter:** adopt `swift-format` (it ships with the toolchain, so no new dependency) with a config matching the house style, and enforce it in CI? Recommendation: yes, with the config agreed first.
