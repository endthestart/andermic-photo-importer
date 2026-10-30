# ADR-0009: Bound working memory during transfers and previews

Status: accepted on 2026-10-25 for the owner's performance development round.

## Context

A full USB camera preview exhausted system memory. The transfer was already sequential and requested 4 MiB chunks, but chunk size alone did not bound memory. Foundation's autoreleased file buffers stayed alive in the enclosing background operation. A synthetic 512 MiB transfer plus its verification readback reached approximately 1,036 MiB peak resident memory. Repeated hashing exhibited the same growth. The small functional camera fixtures did not detect this.

## Decision

- Drain an explicit autorelease pool around every streamed camera buffer, hash-read buffer, and staged-copy buffer. Hashing, writing, cancellation checks, and byte counts occur inside that buffer's pool. Retain hashes and metadata rather than file contents between iterations.
- Drain temporary metadata objects per ImageIO header and per bounded ExifTool batch. Drain fingerprint samples after each sample. Preserve capture-day priority and explicit missing-date handling.
- Keep camera transfer chunks at most 4 MiB and core copy/hash chunks at most 1 MiB. Continue streaming SHA-256, flushing staged files, verifying readback, checking source identity, publishing without overwrite, and checking final destinations.
- Limit camera progress notifications to approximately ten per second to avoid flooding the main queue with redundant status changes.
- Render one grid thumbnail at a time, with a local pool around each ImageIO operation. Configure the thumbnail cache for 64 MiB and 256 entries and account for the actual bitmap row stride and height. NSCache limits are advisory, not a whole-app memory guarantee. Visible views and decoder scratch space also consume memory.
- Use embedded previews for RAW thumbnails. If no embedded preview is supported, show the existing importable placeholder rather than decode/develop the full RAW for a grid tile. Ordinary images retain bounded-size downsampling.
- On source cancellation/rescan, clear thumbnail cache/failure state and invalidate stale worker results and main-queue deliveries. A worker finishing after cancellation must not repopulate the old cache or update the new preview.
- Add a synthetic memory exercise separate from functional safety tests. Keep one enclosing autorelease pool alive while processing more data than the memory-growth allowance. Check real SHA-256 results, cleanup, thumbnail dimensions, cancelled deliveries, and process high-water resident memory. Use a generous 256 MiB growth guard rather than a machine-dependent timing threshold.

## Consequences

This addresses measured buffer accumulation without weakening verified-copy behavior. Fewer simultaneous decoders and a smaller cache trade some cold-thumbnail throughput for lower peak memory. RAW files without an accessible embedded preview remain safely importable.

USB preview still creates local verified copies of all supported originals before planning. It therefore still needs corresponding disk space and USB transfer time. Replacing that with remote metadata/sample reads and selected-file transfer is a separate performance design step that must preserve live-source identity, duplicate proof, dates, related-file grouping, and verification. It is not implemented in this round.

See [PERFORMANCE.md](../PERFORMANCE.md) for workloads, measured before/after values, and validation limits. Apple describes local autorelease pools for bounding temporary Cocoa objects in [NSAutoreleasePool documentation](https://developer.apple.com/documentation/foundation/nsautoreleasepool).
