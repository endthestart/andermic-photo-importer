# Performance development round: bounded memory

## Reproduction and result

The owner reported system-memory exhaustion during a USB-camera preview. Read-only inspection after the app had exited found that camera staging had produced the full set of temporary originals. A bounded synthetic probe then reproduced accumulation in the production streaming paths without any camera or personal photos.

Measured on the current Apple silicon development host, using optimized Swift builds and the same probe before and after the local memory change:

| Workload | Before: peak RSS | After: peak RSS |
| --- | ---: | ---: |
| Hash the same synthetic 64 MiB file 16 times (1 GiB read) | 1,035.3 MiB | 9.2 MiB |
| Transfer eight synthetic 64 MiB originals and verify their readback (512 MiB staged) | 1,035.6 MiB | 13.7 MiB |

These are process high-water resident-memory measurements from `getrusage`, taken inside an intentionally long-lived outer autorelease pool. They demonstrate bounded streaming-buffer lifetime. They do not establish whole-app peak memory, real-card throughput, or cold-storage performance. The fixture contains synthetic repeated bytes and is OS-cached. Timing is recorded for context, not used as a pass/fail criterion.

A subsequent synthetic regression run using the permanent harness measured approximately 8.2 MiB for hashing, 12.6 MiB for camera staging, 9.5 MiB for staged copies, and 49.5 MiB for repeated 4K JPEG thumbnails. The thumbnail run also checks cache clearing and suppression of a completed worker's stale main-queue delivery.

With explicit owner authorization, a standalone read-only ImageCaptureCore probe read one connected-camera NEF eight times into memory, comparing all stream hashes. Its peak RSS was 34.1 MiB with approximately 13.9 MiB growth. It neither viewed images nor saved real photo bytes or wrote to the photo destination. This validates the bounded native read pattern, not a full camera preview/import or a measurement of the camera service's memory.

## Repeatable checks

Run `./scripts/performance-exercise.sh`. It creates isolated synthetic fixtures under `build/performance-exercise/` and records one JSON measurement per mode in `results.jsonl`:

- `digest`: 1 GiB total hashing with known expected content.
- `paired-digest`: the same 1 GiB total hash work with two readers, known expected hashes, and exact read accounting.
- `camera`: 512 MiB of verified snapshots through the injectable camera transport, with 4 MiB maximum requests and progress-update counts.
- `copy`: 512 MiB of staged copies through the real copy/readback implementation.
- `thumbnails`: 128 renders of a synthetic 4096-pixel JPEG, bounded output dimensions/bitmap cost, and stale-result cleanup.

Both CI and source-release build jobs run this exercise after the safety suite on their configured architecture. Each mode runs in a fresh process. A 256 MiB incremental peak-RSS guard catches the original accumulation with headroom for allocator/platform variation. Functional safety checks remain in `./test.sh`; real AppKit workflows remain in `./scripts/ui-exercise.sh`. No script discovers physical cameras, uses the configured destination, or reads personal photos. Do not use a synthetic pass to claim live-camera timing or complete RAW compatibility.

## Remaining performance work

USB preview still transfers and stages every supported original before showing the normal grid. Peak working memory is now bounded at the streaming-loop level, but disk requirements and first-preview latency still scale with camera contents. The next architecture investigation is a remote source reader for bounded metadata/samples, viewport-driven embedded thumbnails, and transfer of selected/new originals. Full hashing remains necessary to prove a duplicate, and source changes or disconnects must fail safely.

Large destination enumeration, unsupported RAW embedded previews, simultaneous processes/volumes, Intel execution, and a complete live-camera preview/import still require separate measurements. The memory round added no persistent catalog, source deletion, RAW development, cloud service, or metadata writes. A later owner-approved preview cache is described below.

## Duplicate-check speed and preview controls

The source and destination full hashes are now read concurrently when both are unknown and their device IDs differ. One extra reader is the limit; same-volume comparisons remain serial. The optimized synthetic regression run measured 1 GiB of cached hash work at 0.49 seconds serially versus 0.26 seconds paired, with both modes below 11 MiB peak RSS. This is a cached hashing measurement, not a measured speedup for a full physical-card scan. The full-byte proof, identity checks, cancellation, and final verification remain in place.

Passive monitoring of an owner-initiated mounted-card scan sampled an approximately 426–456 MiB RSS working set over a three-minute segment rather than byte-proportional growth. The app was left to complete the owner's work. Live tests stopped when the owner said importing was finished. No new camera scan or import was started for the UI/speed follow-up.

The preview now has visible Select All, Select All New, and Deselect All buttons. All includes visible imported/undated groups, New includes only visible new groups with usable dates, and None clears even hidden selections. A synthetic 754-group scan-to-preview transition, imported-visibility toggles, selection actions, and normal/compact layouts are exercised by the GUI script. Tile/header state is reset and layer-backed, scan completion reloads once, and formatted date labels are reused within a rebuild. Normal and compact screenshots were visually checked for overlapping text.


## Owner-authorized full SD-card scan (2026-10-25)

The owner reinserted the card for a read-only profile after finishing importing. The installed build with overlapped verification scanned 754 originals on an exFAT card exposed through macOS FSKit, comparing against an APFS destination on a separate device. The completed app status reported **474.2 seconds**, **83.93 GB read to check 41.79 GB of photos**, and all 754 groups already imported. No import or ejection was initiated by the diagnostic work.

A six-minute process-monitor interval during that scan peaked at **244,842,496 bytes RSS** (233.5 MiB) and **168,133,832 bytes physical footprint** (160.3 MiB). It recorded 65.86 GB of physical reads and zero process disk-write bytes during that interval. This is an observed interval, not a whole-scan memory high-water measurement. A concurrent call-stack sample placed 2,906 of 3,026 verifier samples in the source file-read path, approximately 96%; the destination reader had substantially less active work. The remaining latency is predominantly storage waiting while proving full-content equality, rather than unbounded memory or thumbnail decoding. The app's logical read count includes both originals and destination candidates and differs from physical disk I/O because of caching.

A separate bounded read-only probe hashed one card original using 1, 4, 8, then 1 MiB buffers with caching disabled on the probe file descriptor. Throughput was approximately 80.6, 86.1, 85.6, and 84.3 MB/s, respectively, with identical hashes and stable file identity. This small single-file sample does not justify raising production memory use or claim a whole-card speedup. The production hash buffer remains 1 MiB.

This measurement confirms that full duplicate verification still takes minutes on this card/reader. Avoiding those reads required the cache design below; ADR-0013 later extends cached recognition to unchanged previous imports outside the selection. Persistent history remains deferred; size, samples, and prior reports do not become proof of equality. Local detailed profiles stay under ignored build artifacts and contain no committed photo payloads or personal filenames.


## Fixed-expiry preview cache

ADR-0011 initially added a 30-day preview-only hash cache, bounded at 10,000 entries and 8 MiB. Expiry is measured from a complete hash; preview hits never extend it. Changed identity/attributes/samples and missing/expired/corrupt entries fall back to full verification. Cached matches are labelled, and File > Full Verification bypasses them. Import first rechecks cache-assisted matches outside the selection, then reads selected duplicates in full and verifies copies/readback/final destinations. This prevents a cached item excluded from Import All New from authorizing an unverified skip or successful ejection. That original policy targeted repeat preview latency; ADR-0013 below supersedes the omitted-match preflight. The first scan with no cache still costs complete reads. Sidecars retain full checks, and USB staging remains unchanged.

The synthetic safety suite checks exact full-read accounting for cold, warm, expired, and bypassed scans, plus stale/incorrect cache hints that must never authorize import-time skips. The performance script adds a `cache` mode that records 30,000 synthetic identities, checks count/serialized-size caps, and reloads the result under the same 256 MiB incremental peak-RSS guard. These tests use no real card or personal photo. Physical-card cached timing remains unmeasured.


Local cache workload results on the development host: a 30,000-record synthetic insert/eviction/save/reload exercise took approximately 0.44 seconds, peaked at 51.0 MiB RSS, and serialized 4.45 MB below the 8 MiB cap. These are synthetic cache-operation measurements, not a real-card scan speedup.

## Capture-date cache follow-up (2026-10-30)

Correcting the installed-copy mismatch enabled the existing verification cache on the real SD card. A warm production-Core engine pass took 19.71 seconds with 754 cached groups and 43 new groups, zero complete hash reads, and 361.40 MB of headers/samples. A separate timed pass took 26.68 seconds: listing/initial attributes about 4.19 seconds, capture metadata 12.87 seconds, destination inventory 4.37 seconds, and duplicate matching 5.25 seconds. It still read capture headers for all 797 originals.

ADR-0012 adds optional native capture-day facts to the same verified-hash records. The first pass over a legacy hash-only cache enriches them without extending the full-hash TTL. The next warmed production-Core pass on this card measured **2.05 seconds**, still 797 groups / 43 new / 754 cached matches and zero full-hash reads. It reused 754 capture dates and read headers only for 43 originals: 11,272,192 header bytes plus 152,469,504 sampled bytes, or 163,741,696 bytes total. That is 754 fewer header reads and approximately 55% fewer logical read bytes. The earlier metadata-enrichment pass took 26.94 seconds and read the original 361.40 MB.

These are read-only engine probes on the real mounted card, with OS caches warmed by prior work. They exclude AppKit rendering and cache-object initialization, and do not promise a two-second physical insertion after removal, sleep, or restart. Normal insertion and final UI qualification remain separate gates. Selected imports retain full content verification and independent confirmation of cached dates before publication. ADR-0013 separately optimizes the preflight of omitted previous imports.

## Destination inventory and partial cache fallback (2026-10-30)

Preview and import each list the whole destination. The index now uses one physical `fts` pass that returns attributes with each name, instead of URL enumeration, a path sort, and a second `lstat` per file. Hidden items, flagged-hidden files, package contents, and symlinks remain skipped, and unreadable folders still fail the scan. On a synthetic, OS-cached 100,800-file tree on the development host, building the index fell from about 2.2 seconds to 0.37 seconds. This is not a measurement of the owner's destination.

The ADR-0013 import preflight now looks up source and destination records independently. When only one side's record is stale, for example after a Finder tag changes the destination's ctime, only that side is read in full; the other side's unexpired record is reused and not renewed.
