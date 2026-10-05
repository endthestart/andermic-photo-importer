# Andermic Photo Importer

A lightweight native macOS GUI that copies **only new photo/video originals** from a camera card into ordinary date/event folders. No account, cloud service, or photo catalog database. Photo development stays in DxO PhotoLab or your preferred editor.

![App icon](Assets/AppIcon.png)

**Development preview:** builds are locally signed, not Apple notarized. Real-camera and destination-volume qualification remains in progress. The repository is private while scope, licensing, and release readiness are settled.

The [first public release plan](docs/SPEC.md) prioritizes a polished core importer; [advanced features](docs/ROADMAP.md) follow in later updates. The setup and behavior below describe the current alpha. The completed [design interview](docs/DESIGN-DISCOVERY.md) changed documentation only.

## Use it

1. Install [ExifTool](https://exiftool.org/install.html#OSX), or use `brew install exiftool` if Homebrew is already installed.
2. Open the app and select a card or photo folder. A mounted removable camera volume containing `DCIM` is detected while the app runs.
3. Choose an existing destination root. The default is `/Volumes/Photography/Photo Container`.
4. Enter an event name and choose a folder preset or edit the template.
5. Click **Scan for New Photos** and review the capture dates, duplicate status, and destination folders.
6. Click **Import New Photos**. Optionally open new folders in DxO and eject the card after successful verification.

The app remains in the menu bar when its window closes. USB cameras that only appear in Image Capture must first be copied into a normal folder. Metadata and thumbnail support depend on ExifTool and macOS respectively.

## Folder templates

| Template | Example |
| --- | --- |
| `{YYYY}/{MM}-{DD} - {event}` | `2025/05-18 - Soccer Tournament/` |
| `{YYYY}/{YYYY}-{MM}-{DD}` | `2025/2025-05-18/` |
| `{YYYY}/{MM}/{DD}` | `2025/05/18/` |
| `{YYYY}/{event}` | `2025/Soccer Tournament/` |
| `{event}` | `Soccer Tournament/` |

Tokens: `{YYYY}`, `{YY}`, `{MM}`, `{DD}`, `{event}`. `/` separates directory levels. Multi-day events create a folder for each capture day. Files without a usable capture date require an explicitly selected fallback date and a fresh scan; modification dates are not silently substituted.

## Copy behavior

- Originals are copied byte-for-byte; photos on cards are never deleted.
- Size and small file samples narrow duplicate candidates across all visible regular files under the destination, including renamed files and other events. Potential matches are confirmed with complete SHA-256 hashes; samples alone never cause a skip.
- New originals are fully hashed while copying instead of during the preview. Standard capture dates use macOS's metadata reader; other dates and unsupported files fall back to ExifTool.
- Different contents with the same filename receive a digest suffix; existing files are never overwritten.
- Copies are staged, flushed, read back, verified, and published using macOS exclusive rename. All final destinations are verified before optional ejection.
- Cancel/failure retains completed verified copies, cleans up the current partial copy, and leaves the card mounted. Scan again to resume. A crash/power loss may leave hidden partial files, which the next scan ignores.
- Symbolic links, hidden files, packages, unsupported extensions, and source sidecars are excluded. Existing destination sidecars are untouched. Folder traversal and overlapping source/destination roots are refused.

Photo formats include NEF, NRW, JPEG, GPR, DNG, CR2/CR3, ARW, RAF, ORF, RW2, HEIC/HEIF, TIFF, PNG, and others listed in `Importer.media`. Common video formats are included. Capture days remain in the timezone convention recorded by the camera; review dates from cameras with incorrect clocks or ambiguous video timestamps.

**Current limitation:** embedded metadata edits change a whole-file hash. An original changed by another app may appear new on a subsequent import. Large libraries still require directory enumeration, and true duplicate matches require full reads. There is no persistent index. See [the roadmap](docs/ROADMAP.md).

Settings and reports remain in `~/Library/Application Support/Photo Import/` for continuity with the original prototype. Configurable DxO and ExifTool paths are available in Settings. Reports contain paths, date origins, hashes, and copy/verification outcomes. Originals remain independent of the app.

## Build and test

Apple's Command Line Tools are required to rebuild; the compiled app does not require them. The source targets macOS 13+, but earlier OS versions still need qualification.

```sh
xcode-select --install
brew install exiftool
./test.sh
./build.sh
./scripts/package.sh
./scripts/verify-package.sh
```

The app appears at `dist/Andermic Photo Importer.app`. Each build targets the current Mac architecture. Only system AppKit, Foundation, CryptoKit, and ImageIO frameworks are used. `EXIFTOOL_PATH=/your/path/exiftool ./test.sh` selects another installed ExifTool.

## CI and releases

- Pushes to `main`, pull requests, and manual CI runs build and test on Apple silicon and Intel macOS runners, then verify packaged artifacts.
- A version tag matching `VERSION` (such as `v0.1.0-alpha.1`) runs both architectures and creates a **draft prerelease** with ZIPs and SHA-256 checksums. Both builds must pass.
- Automated drafts use ad hoc signatures and are intended for development review. They are never automatically published.
- [Release instructions](docs/RELEASE.md) explain Developer ID signing, notarization, qualification, and later public downloads.

Product behavior: [specification](docs/SPEC.md). Architecture/scope: [ADR-0001](docs/decisions/0001-local-importer-and-release-foundation.md). Build verification: [validation](docs/VALIDATION.md).

## Hosting and license

A future product page can live under an owner-controlled Andermic domain and link to signed release downloads. No website, DNS, or hosting deployment is configured yet.

The source license is not yet selected. Creating this private repository does not establish an open-source license. The icon is the accepted image-generated Aperture A concept; packaging retains the original PNG and generates macOS icon sizes during builds.
