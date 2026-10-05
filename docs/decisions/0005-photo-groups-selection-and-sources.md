# ADR-0005: Photo groups, selection, and source handling

Status: accepted on 2026-10-04 with the first-release implementation. Rules below are normative for [SPEC.md](../SPEC.md).

## Related-file groups

- **Scope.** Files relate only within one source directory. `DCIM/100CAMERA/IMG_0001.JPG` and `DCIM/101CAMERA/IMG_0001.JPG` are separate photos.
- **Primaries.** Photos and videos with the same base name, compared case-insensitively, form one group: RAW+JPEG, RAW+HEIF, Live Photo HEIC+MOV, and similar. The group's display name and thumbnail come from its first image (JPEG/HEIF preferred for thumbnails, RAW otherwise).
- **Sidecars.** Supported: `.xmp` (XMP metadata), `.dop` (DxO PhotoLab), `.pp3` (RawTherapee), `.aae` (Apple Photos adjustments), `.thm` (camera video thumbnails), `.wav` (camera voice memos).
  - A sidecar named after a complete filename (`IMG_0001.CR3.dop`) belongs to that file's group. This is checked first.
  - Otherwise a sidecar joins the group with its base name (`IMG_0001.xmp`).
  - A sidecar matching no photo is reported and not imported.
- **Dates.** A group's capture day comes from its highest-priority dated member: RAW, then other images, then video. Undated members and sidecars inherit it, and reports record the source (`from IMG_0001.JPG (ExifIFD:DateTimeOriginal)`). Members with a different own day stay with the group, and the report keeps the own day. If no member has a date, the group needs an explicit fallback date for its source.
- **Counts.** The UI and reports count photo groups and physical files separately. Each physical file is copied, read back, verified, and published individually.

## Duplicate status

- A photo or video is already imported only when a complete SHA-256 match exists anywhere under the destination root, including renamed files. Size and samples only nominate candidates. Reports are never consulted.
- A sidecar is already imported only when an identical copy sits beside an imported copy of its photo, under the matching name (`<photo base>.xmp`, or `<photo filename>.dop` for full-filename sidecars). Identical sidecar contents elsewhere, such as template XMP files, do not count.
- Group status:
  - **New:** no primary found.
  - **Partly imported:** some primaries found. Only the missing members are copied, into the group's date folder.
  - **Sidecar differs:** all primaries found, but a sidecar is absent or changed beside them.
  - **Already imported.**
  - **Duplicate in source:** identical content occurs earlier in the same scan.
- New and partly imported groups with a usable date are selected by default. Sidecar-only differences and undated groups are not. All statuses except Already imported can be selected manually.

## Collisions

All new members of a group are staged and verified first. If the original names are free, every member keeps them. If a name holds identical bytes, that member is recorded as present and verified. If any name holds different contents, every remaining new member gets the same suffix after its base name (`DSC_0001__<16 hex>.NEF`, `DSC_0001__<16 hex>.NEF.xmp`). The suffix comes from the member's SHA-256 for a single file, or from the sorted member hashes for a group. `-1`, `-2`, … are added until the whole set is free. Exclusive rename (`RENAME_EXCL`) publishes each file. If another app creates a name in the gap, only that file receives an individual suffix, and the report states that its association was lost. Existing files are never replaced.

A new member of a partly imported group cannot share a suffix with already-imported members it does not rewrite. Its report entry and the result sheet identify any rename.

## Selection and import actions

- Clicking a tile toggles it; Shift-click toggles a range. ⌥⌘A selects all visible new photos, and ⇧⌘A deselects visible photos.
- **Import N Selected** imports exactly the selected photos that the current filters show. The footer reports selected photos hidden by filters, which will not be imported.
- **Import All New (N)** imports every new dated photo regardless of filters. Undated new photos are excluded and the status line says so, until the user chooses a fallback date.
- Changing structure, event name, or fallback date recomputes folders without rereading files. Changing destination or source cancels any scan and rescans. Results from an obsolete scan are discarded. Import requires a preview matching the current source, destination, structure, event, and fallback.
- A fallback date belongs to one source and is cleared when the source changes.

## Sources and cards

- Sources are detected local removable/ejectable volumes containing `DCIM`, or any folder chosen, dropped on the grid, or opened with the app.
- **Show and scan** (default): while the app is idle, a newly mounted card is selected, the window is shown, and the card is scanned. A card already mounted at launch is treated the same way. Later card-list changes, such as ejecting the current card, never switch to another card.
- **Only show availability:** the card appears in the sidebar with a dot, and the menu-bar icon changes. The same quiet indication is used whenever a scan or import is running. A card is never scanned automatically during other work, and copying always requires an import button.
- Ejection is offered only for a detected card that does not contain the destination, and only after the complete import and final verification succeed. Folder sources are never ejected.

## Settings

Settings move to `~/Library/Application Support/Andermic Photo Importer/settings.json` (schema 2). On first launch, a prototype `Photo Import/settings.json` is read once. Its destination, template, editor, and completion choices are kept, and the prototype file is left untouched. New installs default to `~/Pictures` and `{YYYY}/{MM}/{DD}`. An unreadable settings file is preserved as `settings-unreadable-<time>.json` before defaults are used. Reports are written to `Reports/` in the new directory; old reports stay where they are. Saved presets store destination, folder template, and after-import options.

## Consequences

Grouping is name-based and only uses files' locations and names. Content-based pairing, cross-directory sidecars, and import-time renaming remain out of scope. Real-camera grouping coverage needs representative fixtures.
