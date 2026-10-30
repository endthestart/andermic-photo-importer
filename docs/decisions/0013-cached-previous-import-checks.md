# ADR-0013: Reuse unchanged previous-import verification during import

Status: accepted on 2026-10-30 as the owner's requested performance follow-up.

## Context

The owner selected 43 new photos after a cache-assisted preview of 797 originals. Before copying, import fully reread 754 previous matches outside the selection, showing “Rechecking cached match.” This conservative ADR-0011 guard defeated the requested rsync-style benefit during ordinary imports. The owner stopped the operation and requested a fix.

## Decision

For cache-assisted matches outside the selected groups, freshly check source/destination regular-file identities, attributes, and three bounded content samples. Reuse prior full hashes only when both cache entries are unexpired, in the current destination namespace, and match those fresh observations and the preview's expected full hash. Source identity must also remain stable since preview. Cache hits do not renew the fixed 30-day TTL.

A missing, expired, changed, or uncertain cache record requires a complete hash of that side; a valid record for the other side is still reused, so one stale record costs one complete read rather than two. Only sides that were read in full are re-recorded. A missing copy, changed source, or mismatching full contents stops import before publishing any new selected files. Complete successful fallback reads may refresh the cache. Progress distinguishes checking previous imports from fully verifying changed or expired matches.

Selected groups retain the independent duplicate index without persistent-cache lookups, native confirmation of cached capture dates, streaming copy hashes, staged readback, exclusive publication, and final destination rereads. All New therefore avoids complete reads of unchanged old groups while fully verifying the new copies. Selecting old groups explicitly still verifies them in full.

Completion and receipts state how many omitted previous files used cached verification and that their complete contents were not reread. These files are not counted as selected verified skips. Successful imports may still use the owner's optional ejection setting after these checks; no source deletion is added. File > Full Verification bypasses cached recognition for a complete audit.

## Consequences and limits

This deliberately adopts the same unchanged-file assumption as the preview cache. Matching attributes and samples cannot detect every unsampled alteration or silent corruption. Historical hashes are not fresh byte proof. Owners wanting complete current proof can use Full Verification. Cache loss or expiry costs additional reads rather than silently treating missing copies as new or safe.

The fixed TTL, entry/byte bounds, private cache storage, original preservation, no-overwrite publication, sidecar checks, and USB staging behavior remain unchanged. This is a rebuildable performance cache, not an import-history catalog.

Synthetic regressions measure zero complete hash bytes for unchanged omitted matches, full fallback reads at expiry without TTL renewal by import hits, rejection of changed omitted destinations before copying, honest receipt notes, and byte-preserved selected copies. Existing selected-file adversarial cache tests remain strict.
