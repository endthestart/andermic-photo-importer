# ADR-0002: Bound preview reads while retaining verified imports

Status: accepted

## Problem

The prototype hashes every source file during preview and fully hashes same-size destination candidates. Cards containing large RAW files and libraries with many equal-size originals can require substantial disk reading before the user sees the preview.

## Decision

Group destination candidates by file size, then by SHA-256 samples of up to 32 KiB at the beginning, middle, and end. Build each size group's sample index once within a scan. Samples reject candidates; a potential duplicate is always confirmed by full-file SHA-256. New originals receive their full hash while being copied instead of before preview. Reject source changes against the preview's file identity, size, modification time, and change time, and against the open source throughout copying. Preserve staged readback and final destination verification.

Read up to 256 KiB of each source header for ImageIO's standard EXIF original-capture date, without pixel decoding. Use full ExifTool metadata extraction when that date cannot be read. Retain capture-date priority and explicit missing-date handling. Metadata discovery checks identity, size, and modification time; the completed preview snapshot additionally records change time for import-time checks. Filesystem metadata updates can change change time during discovery without changing photo bytes.

No persistent index or database is introduced. The in-memory sample/hash index expires at the end of the operation. Original files remain independently usable and are never edited.

## Consequences and validation

New-file previews avoid full reads of the source and unrelated same-size library files. Destination directory enumeration remains necessary; true duplicate-heavy previews still require complete reads. ExifTool fallback and slow card access can still dominate. A future disposable cache would require a separate decision and must never independently authorize a skip or ejection.

Regression fixtures cover renamed matches, equal-size nonmatches, intentional sample collisions, source changes outside sampled regions, copy readback, final destination changes, and resume after failure. A synthetic workload measures read volume without imposing a machine-dependent timing threshold. Real-card timing remains to be qualified.
