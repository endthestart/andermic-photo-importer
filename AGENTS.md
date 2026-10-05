# Repository guidance

Andermic Photo Importer is a native macOS utility for safely importing new photo/video originals into ordinary folders. The product is local, has no account or catalog database, and delegates photo development to DxO or another editor.

- Preserve originals byte-for-byte. Never delete files from camera cards, overwrite an existing destination, or silently invent a capture date.
- Keep all credentials, personal photos, local import reports, certificates, and workstation settings out of Git.
- Import-safety changes need meaningful synthetic regression tests. Run `./test.sh` and `./build.sh` before submitting changes to source or packaging; run `./scripts/package.sh` and `./scripts/verify-package.sh` for packaging changes and `./scripts/ui-exercise.sh` for UI changes. Never exercise the app against real cards or personal photos without the owner's authorization.
- Document substantial behavior changes in `docs/SPEC.md`; durable architecture decisions belong in `docs/decisions/`.
- Keep build tools small: system Swift/AppKit/Foundation/CryptoKit/ImageIO. ExifTool and its Perl runtime are bundled from the sources pinned in `scripts/metadata-helper.lock` (ADR-0004); never depend on Homebrew, PATH, or the system Perl. Change pinned versions only together with their published SHA-256 and update the notices.
- Changes to culling, deletion, metadata writes, cloud features, catalog databases, or RAW development expand the scope and need an explicit product decision.
- Development builds use local ad hoc signing. Public app-binary download releases require Developer ID signing, notarization, and successful live workflow qualification. The owner approved MIT-licensed source-only previews on 2026-10-05; these publish source archives with local build instructions and no app binaries.
- Release automation creates draft source prereleases without app binaries. The owner selected MIT and authorized the initial source publication on 2026-10-05. Adding Apple credentials, publishing app binaries, or configuring domains remains an owner decision.
- Follow `docs/SPEC.md`, ADR-0003, ADR-0004, and ADR-0005 for the first public release. Keep advanced history, filename templates, second copies, and source deletion in the later backlog, and do not show settings for them. Do not infer an implementation request from a recorded design answer.
