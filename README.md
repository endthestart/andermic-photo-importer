# Andermic Photo Importer

A lightweight native macOS app that copies **only new photo and video originals** from a camera card or folder into ordinary folders. No account, cloud service, telemetry, or photo library database. Photo development stays in DxO PhotoLab or your preferred editor.

![App icon](Assets/AppIcon.png)

![Import window](docs/screenshots/import-window.png)

**Source preview:** build the app on your Mac using the instructions below. This release publishes source code, with no prebuilt app downloads. Local builds are ad hoc signed; Apple Developer Program membership is not needed to build or use them. Real-camera, clean-machine, and older-macOS qualification remain in progress. See [validation](docs/VALIDATION.md).

## Build and install

Requires a Mac with macOS 13 or later, Apple’s Command Line Tools, and an internet connection for the first build. Apple silicon and Intel build and pass synthetic tests in CI; macOS versions earlier than the build hosts still need qualification. No Xcode project, Homebrew, separate ExifTool installation, or paid Apple membership is required.

Install the Command Line Tools if you do not already have them:

```sh
xcode-select --install
```

After installation finishes:

```sh
git clone https://github.com/endthestart/andermic-photo-importer.git
cd andermic-photo-importer
./build.sh
open "dist/Andermic Photo Importer.app"
```

The first build downloads pinned, checksum-verified Perl and ExifTool sources and compiles the bundled metadata reader (about two minutes on the development Mac). Later builds reuse it. The app builds for your Mac’s architecture. For a permanent installation, quit the app and drag `dist/Andermic Photo Importer.app` into Applications, then open that copy.

To update, quit the app, run `git pull --ff-only` and `./build.sh`, and replace your installed copy. Your destination, folder layout, presets, and reports stay in Application Support.

## Use it

1. Open the app. Nothing else needs to be installed: metadata reading is built in.
2. Insert a camera card. By default, the app shows its window and scans the card. You can also choose a folder (⌘O), drop one on the grid, or open one with the app. Scanning only previews; nothing is copied until you click an import button.
3. Review the thumbnail grid. New photos are selected. Click a photo to include or exclude it, and Shift-click to toggle a range. Filter by date or file type, or hide photos already imported.
4. Check **Import Options**. The destination defaults to your Pictures folder, and the folder structure defaults to Year / Month / Day (`~/Pictures/2026/10/04/`). Choices are remembered and can be saved as presets. An event name is optional.
5. Click **Import N Selected** or **Import All New**. Optionally, open the new folders in your editor and eject the card after verification.

The app stays in the menu bar when its window closes. Under **Advanced**, you can choose to only show that a card is available instead of opening the window and scanning. Cameras that appear only in Image Capture must first be copied into a normal folder.

## Folder structures

| Structure | Template | Example |
| --- | --- | --- |
| Year / Month / Day (default) | `{YYYY}/{MM}/{DD}` | `2026/10/04/` |
| Year / Year-Month-Day | `{YYYY}/{YYYY}-{MM}-{DD}` | `2026/2026-10-04/` |
| Year / Month-Day - Event | `{YYYY}/{MM}-{DD} - {event}` | `2026/10-04 - Lisbon Trip/` |
| Year / Event | `{YYYY}/{event}` | `2026/Lisbon Trip/` |
| Event | `{event}` | `Lisbon Trip/` |

Tokens: `{YYYY}`, `{YY}`, `{MM}`, `{DD}`, `{event}`. `/` separates folder levels. Each photo goes into the folder for its own camera-recorded capture day, so a card spanning several days needs no event name. Photos without a capture date are never guessed. They stay unselected until you choose a date for them in Import Options.

## Related files

RAW+JPEG pairs, Live Photo HEIC+MOV pairs, and sidecars (`.xmp`, `.dop`, `.pp3`, `.aae`, `.thm`, `.wav`) with the same name in the same folder are shown and selected as one photo. Every file is still copied and verified individually. If a filename is already taken by a different file, all of the photo's files get the same suffix, so they stay together. For a photo that is already imported, a missing sidecar is placed beside it. A sidecar that differs from the one beside it (for example, after editing) is imported with a matching copy of the photo under a shared name; the existing sidecar is never replaced. Full rules: [ADR-0005](docs/decisions/0005-photo-groups-selection-and-sources.md).

## Copy safety

- Originals are copied byte-for-byte; files on cards are never modified or deleted.
- A photo counts as already imported only when a file with identical contents exists anywhere under the destination, including renamed files. Size and small samples only find candidates. Import reports are never treated as proof.
- Copies are staged, flushed, read back, verified, published without overwriting, and verified again before the import is complete or the card is ejected.
- Stopping or a failure keeps completed, verified copies, removes the in-progress staging files, and leaves the card mounted. Import again or rescan to continue.
- Symbolic links, hidden files, packages, folder names that escape the destination, and overlapping source/destination folders are refused.

Photo formats include NEF, NRW, CR2/CR3, ARW, RAF, ORF, RW2, DNG, GPR, JPEG, HEIC/HEIF, TIFF, PNG, and others in `MediaTypes`, plus common video formats. **Limitation:** an original whose embedded metadata was edited by another app has a different hash and appears new.

Settings and import reports are local files in `~/Library/Application Support/Andermic Photo Importer/`. Prototype settings from `Photo Import/` are adopted once and left in place.

## Development checks

```sh
./test.sh
./build.sh
./scripts/package.sh
./scripts/verify-package.sh
```

Tests use disposable synthetic originals. Package verification checks signatures, architecture, license notices, checksums, and metadata reading from the extracted app with an empty environment. Packaging creates local development ZIPs; these are not the public source-release downloads.

`./scripts/ui-exercise.sh` drives the GUI against synthetic cards with isolated settings and saves screenshots to `build/screens/`. It exercises the system clipboard and restores it afterwards. Use it with real camera cards disconnected; it never imports from or ejects them.

## CI and releases

- Pushes to `main`, pull requests, and manual runs build, test, and verify packages on Apple silicon and Intel runners.
- Version tags build and verify both architectures, then create a **draft source prerelease**. Publishing is manual. GitHub provides the tagged source ZIP and tar archive; no app binaries are attached.
- [Release instructions](docs/RELEASE.md) cover source previews now and Developer ID signing/notarization later.
- Report reproducible problems in [GitHub Issues](https://github.com/endthestart/andermic-photo-importer/issues). Include macOS version, architecture, file formats, and the steps; remove personal paths and photo metadata from reports before sharing. This is an early preview with no support or compatibility guarantee.

Product behavior: [specification](docs/SPEC.md). Decisions: [ADR-0001](docs/decisions/0001-local-importer-and-release-foundation.md) to [ADR-0006](docs/decisions/0006-mit-source-preview.md). Evidence: [validation](docs/VALIDATION.md).

## License

The app’s source is under the [MIT License](LICENSE). Bundled ExifTool and Perl retain their own licenses and notices; see [THIRD_PARTY.md](THIRD_PARTY.md) and **Help → Third-Party Notices** in the app. The icon is the accepted Aperture A concept; builds generate macOS icon sizes from the original PNG.
