# ADR-0011: Expiring verification hints for fast repeat previews

Status: accepted on 2026-10-25. The owner approved the proposed rebuildable cache and requested a 30- or 90-day TTL. This implementation selects 30 days, with independent entry and byte limits.

## Context

A read-only SD-card scan took 474.2 seconds, reading 83.93 GB to compare 41.79 GB of originals. Sampling showed source file reads dominated verification. Repeating those complete reads on every preview costs minutes even when neither copy has changed. File size, timestamps, and samples cannot independently prove current byte identity; the UI must distinguish cached recognition from fresh verification.

This is a bounded preview optimization, not persistent import history or a catalog database. Original files remain ordinary files. Reports remain explanatory and never seed the cache or authorize skips.

## Decision

Store complete file hashes only after complete reads with stable file identity, or a completed verified import. On preview, reuse a hash only when its destination-root namespace, file path key, device/inode/size, nanosecond modification/change/birth times, and newly read content sample all match. A root namespace includes its path and device/inode. Path keys and namespaces are SHA-256 digests; personal filenames are not stored as plaintext. This is an unchanged-file assumption and cannot detect all unsampled changes with matching attributes or silent corruption.

Use a fixed **30-day TTL from the last complete hash**. Hits do not renew it. Expiry, future timestamps after clock rollback, changed attributes/samples, missing files, changed root identity, malformed/unknown cache schemas, oversized input, or unavailable storage cause normal reads. An uncached file is not labelled new merely because its cache entry is absent; normal content matching still runs, including renamed destinations.

Bound the entire cache at **10,000 entries and 8 MiB serialized data**. Evict older verification records, in small batches at the count limit to avoid sorting on every new record. Prune on app launch, scans, lookup, and save; an inactive app performs no scheduled deletion. Save only a bounded, private JSON cache under the user's Caches folder, with 0700 directory/0600 file permissions, bounded reads, symlink refusal, and an atomic private temporary-file rename. A missing/corrupt/unwritable cache is disposable. Concurrent processes may lose hints through last-writer-wins; that costs performance only. Nothing is written to card files, destination originals, extended attributes, settings, or existing reports by this cache.

Preview groups using any cached matching evidence show a cached count and an orange **Imported (cached)** or **Partly imported (cached)** badge, with an explanation in the tooltip. **File > Full Verification** (Option-Command-R) bypasses persistent hints, rereads complete matching contents, and refreshes their expiry. Scan Again uses the cache. Related sidecars continue to use complete content checks; the main reuse path is for original photos/videos.

Import constructs its duplicate index **without cache lookups**, even when recording fresh cache entries after completion. Before any copying, every cache-assisted match omitted from the selection is fully rechecked too, because it influenced which photos appeared new. A mismatch stops the import and asks for Full Verification. Selected duplicates are fully rechecked by the normal import path, without a redundant preflight. Copied originals retain streaming hashes, staged readback, exclusive publication, source stability checks, and final destination rereads. Cache-assisted previews cannot authorize a skip or successful completion/ejection without these checks. No source deletion or overwrite is added. A stale cached source digest can fail an import safely; Full Verification rebuilds the preview.

## Consequences and limits

The first preview after expiry/eviction, or after installation with no cache, pays the normal verification cost. Subsequent unchanged previews avoid complete hash reads for cached originals; metadata discovery, samples, directory enumeration, and sidecar checks remain. Import itself deliberately retains the full verification cost. No physical-card speedup is claimed until measured.

USB preview still stages all originals and uses disposable snapshot paths, so it does not receive the same source-read savings as a stable mounted card/folder. This decision does not replace USB transfer staging or solve large destination enumeration. Advanced history, selectable detection modes, recovery automation, and a catalog database remain deferred.

Synthetic regressions cover warm/cold reads, renamed originals, fixed TTL despite hits, clock rollback, identity/sample/root/path mismatches, bounded count/bytes/loading, corruption, symlinks, source edits, missing destinations, import-seeded entries, and deliberately incorrect cached source/destination hashes. The GUI exercises cached labels and the bypass command. The performance harness exercises 30,000 synthetic cache records under the existing resident-memory guard.


ADR-0012 extends entries with optional native date facts to reduce repeat header reads. It retains this verification policy and cache bounds, keeps fallback dates out of the cache, and independently confirms selected cached dates before publication.
