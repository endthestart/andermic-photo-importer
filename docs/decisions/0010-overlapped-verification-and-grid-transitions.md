# ADR-0010: Overlap independent-volume verification and refresh previews atomically

Status: accepted on 2026-10-25 for the owner's speed and UI follow-up.

## Context

The owner reported that checking a large card was slow and supplied a screenshot showing preliminary Scanning/Checking text overlapping the completed preview. They also requested quick selection buttons. The existing verifier read the complete source and destination candidate serially when proving a duplicate. The collection could reload twice back-to-back at scan completion while recycled tiles mixed layer-backed images with unbacked labels.

## Decision

When neither full hash is known and source/candidate device identifiers differ, read the two originals concurrently using one additional worker. Keep same-volume checks serial. Each reader keeps its own per-buffer autorelease pool, cancellation checks, file identity/stability checks, and SHA-256 state. Aggregate read counters only after joining the worker. Errors must abort the comparison. The device identifier is an I/O scheduling hint, never evidence that bytes match. This is bounded at two hash readers per active comparison, not one worker per photo.

Continue reading both complete files to prove equality. Samples may reject candidates, but never independently authorize skips or ejection. Keep operation-local candidate caching and all import-time/final verification rules. No persistent cache or catalog is introduced. Cross-volume concurrency can overlap separate devices and hashing work; two volumes on one physical device do not guarantee a speed gain.

Report duplicate-check progress at roughly ten updates per second, including the first and last file, rather than waiting for ten files between updates. Cache formatted capture-day labels within one grid rebuild.

Apply the verified preview and initial selection together, followed by one grid refresh. Use layer-backed tiles and headers, clear text/badges when recycling them, invalidate layout, and reload without implicit animation. An opaque native grid background clears old drawing. Start the verified grid at its top so its section header and first new photos are visible. Preserve original image framing and the existing embedded-preview policy.

Add **Select All**, **Select All New**, and **Deselect All** beside the source heading, as explicitly requested by the owner. All replaces the selection with every visible group, including imported and undated groups; New replaces it with visible new groups that have usable dates; None clears the complete selection, including hidden groups. The matching menu commands use these same rules, and grid Cmd-A invokes All while field Cmd-A keeps text-editing behavior. All/New respect the filters, and Import Selected still imports only selected groups visible under those filters. Already-imported selections are fully re-verified and skipped, never overwritten. Undated new selections still block Import Selected until the owner supplies a date or deselects them. Disable unavailable actions and all three buttons during scanning/import.

## Validation and limits

Synthetic tests cover full-hash equality, source/candidate failures, cancellation, and a deliberate sample collision followed by a renamed exact match through the overlap path. The memory exercise includes paired hashing with exact read accounting and the existing growth guard. The GUI exercise reproduces a 754-group preliminary grid becoming 58 visible new groups, toggles imported visibility repeatedly, checks headers/tile content/frames, exercises the buttons, and captures normal/compact screenshots.

An OS-cached 1 GiB hashing workload measured about 0.49 seconds serially and 0.26 seconds with paired reads on this host. This does not measure whole-card timing or promise the same gain on physical devices. After initially stopping live tests when the owner finished importing, the owner later reinserted the SD card and explicitly authorized a read-only full-scan profile. That profile is recorded in PERFORMANCE.md; it is not a before/after whole-card comparison. The first scan still reads full candidate/source contents to prove duplicates, and USB preview still stages all originals before the normal preview. Those costs remain explicit in PERFORMANCE.md.
