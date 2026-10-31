# ADR-0014: Other-card copies and on-demand camera reads

Status: accepted on 2026-10-30 at the owner's direction. Part 1 is implemented first; part 2 follows and needs live-camera qualification.

## Context

A USB preview of a Nikon Z 8 reported all 929 originals as new. 893 had been imported from the camera's other card. Each matched an imported file in name, size, and content samples, but not in full SHA-256: Nikon records the card slot inside the maker notes (`MemoryCardNumber`, and `BurstStartSlotNumber` in bursts), so backup-recording copies differ by one or two bytes. The importer's byte-equality rule correctly refused them, but that is not what the owner means by "already imported."

The same preview held 48 GB of temporary full copies, and an abandoned earlier preview held another 41 GB. ADR-0008 copies every camera original before preview because only a complete read proves byte equality.

## Decision, part 1: other-card copies

Add a setting for photos already imported from the camera's other card: **Show as new** (default, unchanged behavior) or **Treat as imported**.

When enabled, a photo or video with no byte-identical destination copy is an other-card copy of a destination file only if all of these hold:

- the destination file is a regular file in the index with the same size and the same filename, compared case-insensitively;
- the middle and last 32 KiB content samples are equal (the first sample covers the header, where slot fields may lie);
- the bundled ExifTool reports the same camera serial number and the same original capture time, both non-empty, plus the same shutter count when present;
- every other reported metadata value is equal, except file-system values and the allowlisted slot fields `MemoryCardNumber` and `BurstStartSlotNumber`.

These are recognition rules, not byte proof. Such groups are labelled "Imported (other card)", count as imported, and stay unselected. Selecting one imports a separate verified copy under the usual no-overwrite naming. Sidecars keep their existing rules.

During import, omitted other-card matches get a cheap preflight: the destination file must still be a regular file of the same size with the same middle and last samples. The receipt states how many photos were treated as imported from the other card, and that they are not byte-identical. Other-card verdicts are not cached; they are recomputed on each scan from the files themselves.

## Decision, part 2: on-demand camera reads

Replace the full temporary snapshot with bounded partial reads through `ICCameraFile.requestReadData`:

- For preview, read each original's 256 KiB header and its three content samples over USB, and use embedded previews for thumbnails. Capture dates, grouping, other-card recognition, and duplicate candidates come from those reads.
- Recognize previous imports from verification-cache records keyed by camera identity: camera serial number, camera-relative path, name, size, capture time, and samples. Only a complete hash creates such a record. Without a record, a candidate's full camera bytes are hashed while streaming, with nothing written to disk.
- At import, stream only the selected new originals from the camera straight into the destination's existing staging, readback, exclusive publication, and final verification.

Temporary disk use falls from the size of the camera's contents to bounded buffers. Repeat previews read headers and samples rather than every byte. The identity is weaker than a mounted file's inode and change time, so this cache use is limited to camera sources and labelled the same way as other cached recognition. Full Verification still hashes every candidate in full.

## Consequences

Part 1 can recognize an other-card copy without reading every byte, so a photo altered only in its unsampled middle, with identical metadata, would be missed. The owner accepts that when the setting is enabled; the default remains strict. Synthetic regressions cover twins, near-twins differing in other metadata, different serials or capture times, differing samples, and the default setting.

Part 2 changes ADR-0008's snapshot model and must be qualified on the owner's camera with explicit authorization before release: partial-read latency, both card slots, large videos, disconnects mid-read, and cancellation.
