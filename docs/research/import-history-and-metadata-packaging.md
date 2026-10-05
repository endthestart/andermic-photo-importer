# Import history and metadata packaging

Research date: 2026-10-04. Primary documentation only. This is a comparison and design input, not approval of a new duplicate policy or runtime architecture.

## Previously imported photos

| Reference | Documented approach | Implication for this importer |
| --- | --- | --- |
| Lightroom Classic | Suspected duplicates use the original filename, EXIF capture date/time, and file size against the catalog. | Fast metadata identity is useful, but is distinct from full byte equality. |
| ON1 Photo RAW 2025 | An import database records original filename and capture time. Recognized imports are deselected and marked already imported; import-time renaming preserves recognition. Users can select an item to import it again. | Import history can exist alongside a folder-oriented workflow. A visible status and explicit reimport action are useful. |
| Capture One Sessions | Importer duplicate exclusion compares key metadata with the Session database. Its manual documents limits involving drag-and-drop imports, changed extensions, and EIP packing. | Define the boundary of recognition and show why an item is classified; do not promise universal identity matching. |
| Rapid Photo Downloader | Previously downloaded recognition compares name, size, and modification time. The UI can show prior download time, location, and filename, and users can select an item again. Time-zone/DST handling is configurable. | A lightweight importer can keep useful download history, but filesystem timestamps need careful interpretation. |
| digiKam | “Download New” uses database download records and distinguishes new from already downloaded items in the import UI. | Prior download status is useful without treating it as proof that a destination still exists. |

Sources:

- [Adobe: specify import options](https://helpx.adobe.com/in/lightroom-classic/desktop/import-photos/photo-video-import-options.html).
- [ON1 Photo RAW 2025 User Guide, printed page 55](https://ononesoft.cachefly.net/content/ON1-Photo-RAW-2025-User-Guide.pdf). The 2026 manual portal was available but its article/PDF content was not retrievable in this research pass; do not present the 2025 internals as verified for every later ON1 version.
- [Capture One: importing into a Session](https://support.captureone.com/hc/en-us/articles/360002521938-Importing-images-into-a-Session).
- [Rapid Photo Downloader documentation](https://damonlynch.net/rapid/documentation/) and [project source](https://github.com/damonlynch/rapid-photo-downloader).
- [digiKam: import from camera](https://docs.digikam.org/en/import_tools/camera_import.html).

## Cases our design must distinguish

“Imported before,” “suspected duplicate,” and “verified matching copy exists” are different states. The current alpha checks complete byte identity against files under the selected root; it does not remember imports independently of those files.

Before implementation, settle the policy for:

- A verified original still present under a renamed file or a different event folder.
- A file imported by Finder or another tool, with no history in this app.
- A prior copy deleted intentionally, lost accidentally, or moved outside the selected destination.
- An offline destination volume; absence cannot be established while the volume is unavailable.
- Embedded metadata changed by another application, altering the full-file hash.
- Reused camera filenames, identical capture timestamps, RAW/JPEG pairs, and multiple cameras/cards.
- Interrupted imports, verified partial progress, incomplete staging files, and a missing second copy if backup support is added.
- Deliberate reimport, destination changes, stale or deleted history, and rebuilding any cache.

Proposal, not an accepted policy: keep local import records and an optional rebuildable file index, while originals remain ordinary files. Use history to accelerate classification and explain previous activity. Distinguish missing/offline/uncertain states, and retain verified-copy requirements. Do not silently treat a prior import record as a currently safe copy or as authorization to eject after an unverified operation. The storage format and size limits remain undecided.

## Self-contained metadata support

The owner requested an app that runs without a separate ExifTool/Homebrew installation and exposes open-source licensing.

ExifTool's upstream README permits redistribution under Perl's terms (Artistic License or GPL), requires Perl, and explains that its script must remain with its library modules unless those modules are installed. Therefore bundling is feasible in principle; merely copying the script would retain an external runtime dependency. The exact licensing route and notices must cover the selected ExifTool, Perl runtime, and any additional modules/binaries actually shipped. [Upstream README](https://github.com/exiftool/exiftool/blob/master/README), [installation documentation](https://exiftool.org/install.html).

Proposed packaging acceptance criteria:

- The app contains the required metadata helper and runtime; a normal user has no executable-path setting or installation step.
- Versions and upstream source/checksum provenance are pinned in the build; helper paths resolve within the signed bundle.
- An About/Open Source Licenses view and bundled notice files identify shipped components and retain applicable license/copyright text and source access required by their terms.
- Both Mac architectures build, all nested executable components are signed appropriately, and the complete app is notarized for public distribution.
- A clean-machine test exercises RAW metadata with no external ExifTool/Homebrew/Perl dependency available to the helper. Tests explicitly select the bundled helper and exercise fallback rather than passing only through ImageIO.
- Metadata helper updates ship with an app update; the ordinary import workflow requires no download or login.

These packaging criteria are a proposed implementation plan. No helper/runtime has been bundled into the current alpha yet. Linux packaging and replacing macOS-specific APIs require a later platform decision.
