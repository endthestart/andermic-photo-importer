# ADR-0012: Reuse native capture dates in verified-file previews

Status: implemented on the performance follow-up branch on 2026-10-30, pending final UI qualification.

## Context

After correcting an obsolete installed app copy, the real-card verification cache worked: a repeat engine scan found 43 new groups and 754 cached matches with no complete duplicate hashes. The pass still took 19.71 seconds. A separate stage-timed repeat took 26.68 seconds, including about 12.87 seconds rereading capture metadata for all 797 originals. Avoiding complete hashes did not avoid these header and metadata reads.

## Decision

Extend the existing bounded cache's v1 entries with optional native capture-day components and their original metadata-field name. Existing hash-only entries remain readable. A normal preview enriches them after a fresh metadata read, without extending the original full-hash expiry. Keep the existing 30-day TTL, 10,000-entry limit, 8 MiB limit, signature checks, and private storage. Never cache a fallback date or a group's inherited date as a file's own date.

Only reuse a date when its record has a valid complete hash and native calendar day, unexpired verification, unchanged file identity/timestamps/size, and a newly matching content sample. Reuse that sample later in the same preview instead of reading it twice. Retain the recorded full hash in the planned file even when its destination copy is absent; a reused date must not lose its binding to the previously hashed source bytes. Indicate cached metadata in date provenance and scan statistics. New/changed files, invalid/missing dates, and unknown metadata still use fresh native reads. Full Verification bypasses date and hash reuse.

Cached date fields are not authoritative for import placement. Before publishing anything, import re-reads the native metadata of selected members whose dates came from the cache. A mismatch stops the operation before copying and directs the owner to Full Verification. Restore the freshly observed field name in report provenance. Keep all strict source/version checks, full selected duplicate checks, checks of cache-assisted omitted matches, copy/readback verification, exclusive publication, and final destination verification. There are no source writes or metadata edits.

The core run API accepts the bundled metadata reader for this confirmation. A caller that supplies a cached-date plan without the reader fails closed; a fresh Full Verification plan needs no cached-date confirmation. The app passes its existing bundled helper.

## Validation and limits

Synthetic regressions cover reduced header reads, undecodable/missing native dates, source-hash retention when a destination disappears, legacy-cache enrichment without TTL renewal, exact TTL expiry, a valid-looking incorrect cached day, invalid calendar components, forged origin strings, byte-preserved imports, and explicit fallback dates that must not leak into the cache. Existing safety checks remain in place.

The optimization targets preview metadata I/O. It does not remove destination inventory enumeration, source listing, fresh samples, native reads for new originals, or full import-time verification. Real-card timing and final UI qualification are recorded in VALIDATION.md and PERFORMANCE.md; no claim of instant scanning follows from a synthetic pass.
