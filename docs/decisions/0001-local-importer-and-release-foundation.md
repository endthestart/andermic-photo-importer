# ADR-0001: Local importer and release foundation

Status: accepted for the repository/CI foundation on 2026-10-04. Public release remains pending qualification and owner decisions.

## Context

The owner wants a native GUI for a filesystem-based photography workflow, configurable Lightroom-style folder organization, only-new imports, verified copies, and optional DxO handoff. Building a competing RAW-development pipeline is outside the intended effort. The owner authorized GitHub repository creation and CI/CD and mentioned owner-controlled domains as a future hosting option.

## Decision

- Repository: `endthestart/andermic-photo-importer`, private initially.
- Product: Andermic Photo Importer; bundle ID: `net.andermic.photoimporter`.
- Keep the original prototype's `Photo Import` Application Support directory to preserve local settings across the name change.
- Native AppKit/system Swift frameworks; ExifTool remains an explicit separately installed metadata dependency.
- No persistent catalog, no app cloud service, and immutable original bytes.
- Build/test/package both arm64 and x86_64 using explicit GitHub-hosted macOS runner labels. Pin official Actions to immutable revisions; limit workflow permissions by job.
- Version tags create draft development prereleases after both variants pass. No automatic public publishing and no Apple credentials in the repository.
- Local scripts support Developer ID signing/notarization once the owner has configured credentials. The current automated path remains ad hoc signed.
- Preserve scope, behavior, qualification gaps, and release instructions in repository documentation.

## Consequences

The owner receives a reviewable release pipeline now, without implying that development signatures are public-release signing. Private GitHub-hosted macOS CI consumes the account's Actions allowance. License selection, Developer ID credentials, live photo qualification, public publishing, and domain/DNS configuration remain separate owner decisions.
