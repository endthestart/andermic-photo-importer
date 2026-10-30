# ADR-0008: Read-only USB camera sources through ImageCaptureCore

Status: accepted for implementation on 2026-10-25 in response to the owner's request for Nikon Z 8 USB support. The owner authorized a bounded read-only NEF transfer check on 2026-10-25; that check passed.

## Context

The original source monitor discovers mounted removable volumes containing DCIM. A Nikon Z 8 connected by USB appears as an Image Capture camera, with no mounted source volume. Apple Photos can list that device while a filesystem-only importer cannot.

## Decision

Use Apple's system ImageCaptureCore framework to discover local USB cameras, separately from mounted cards. Show cameras in the source sidebar, including cameras already connected at launch. Discovery alone does not open a session or request media. Selecting a camera explicitly starts its preview. Mounted-card automatic-scan preferences remain independent because USB preview requires temporary space for all supported originals.

Open an Image Capture session, wait for the complete content catalog, and request original asset presentation. Merge the folder hierarchy with `mediaFiles`, deduplicating by device object identity. The Z 8 can report a complete, populated media list while `contents` is empty. Recover hierarchy from each file's parent-folder links in that case. Retain hierarchy-only sidecars when the media list omits them, and reject ancestry cycles or incomplete parent relationships. Map folder objects into separate staging directories so repeated filenames in different directories or card slots never merge. Refuse unsafe paths, ambiguous case-insensitive names, negative sizes, and converted filenames. Read original file data in bounded chunks using `ICCameraFile.requestReadData`, without requesting conversions, camera metadata writes, clock synchronization, uploads, capture, deletion, or ejection.

Use a unique, private disposable directory under `~/Library/Caches/Corvus/CameraTransfers/` for each scan. Foundation normalizes macOS temporary paths through the `/var` symlink, so use user-cache storage to preserve the core importer's refusal of symlinked sources. Tests inject an isolated fixture working folder. Stream a SHA-256 digest during transfer, flush the local copy, and verify its size and digest by reading it back. Short positive reads advance by their actual length; premature EOF, excessive response lengths, framework errors, timeout, cancellation, and disconnect fail the preview. No preview or import can use a partially transferred snapshot. Retain the transfer digest through planning and importing so later local changes cannot replace the transferred bytes. This verifies the bytes returned by Image Capture and their local copies, not an independently supplied camera checksum.

Feed the completed snapshot into the existing folder importer for metadata, grouping, destination duplicate checks, explicit missing-date fallback, collision handling, staged publication, final SHA-256 verification, and cancellation recovery. Reports retain the camera connection URI and camera-relative paths/object handles rather than disposable temporary paths. A connection URI identifies the current session, not a persistent camera catalog. Keep temporary originals alive while a preview or import uses them, remove them when their snapshot is released on rescan/source change/disconnect, and never use old snapshots to recognize a reconnected camera. Process termination during an operation can leave disposable camera copies in that cache folder; snapshots are never a persistent duplicate catalog.

USB cameras are never eligible for the mounted-volume ejection option. Discovery/removal must not switch another active source or restart copying. Disable physical-camera discovery entirely in the synthetic GUI exercise. Give the test app a separate bundle identifier (`net.andermic.photoimporter.ui-exercise`) so its changing ad hoc signature cannot replace the installed app's privacy identity.

Sign the main app with Apple's `com.apple.security.personal-information.photos-library` entitlement, which ImageCaptureCore documents for macOS photo import. The importer does not access a Photos library. Keep the bundled metadata reader, dependency pins, ad hoc local signing, and source-preview release policy.

## Consequences and qualification

USB previews read all supported originals before showing the normal grid and need equivalent temporary disk capacity. Rescanning transfers them again. A card reader remains the faster path for large cards because mounted files permit bounded preview reads. Support is limited to originals and sidecars exposed by the camera's Image Capture catalog. If another app holds the device, camera/session failures advise closing Photos or Image Capture and retrying.

Synthetic transport tests cover short reads, original hashes, grouped RAW/JPEG/sidecars, reused names across slots, camera provenance, destination deduplication, changed local snapshots, cleanup, malformed catalogs, cancellation, and disconnects. GUI fixtures exercise camera discovery without automatic scanning, camera preview, import, rescan, removal, and disabled ejection. Live USB identity discovery, corrected production catalog enumeration, and two identical, bounded reads of one NEF were verified on the connected Z 8 with explicit owner authorization. The installed app lists the camera once macOS removable-volume permission is granted. A full real-camera library import, both physical card slots, large videos, physical disconnect during transfer, and other camera/macOS combinations remain unqualified.

Reference: [Apple ImageCaptureCore documentation](https://developer.apple.com/documentation/imagecapturecore).
