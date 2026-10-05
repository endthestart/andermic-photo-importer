# Repository guidance

Andermic Photo Importer is a native macOS utility for safely importing new photo/video originals into ordinary folders. The product is local, has no account or catalog database, and delegates photo development to DxO or another editor.

- Preserve originals byte-for-byte. Never delete files from camera cards, overwrite an existing destination, or silently invent a capture date.
- Keep all credentials, personal photos, local import reports, certificates, and workstation settings out of Git.
- Import-safety changes need meaningful synthetic regression tests. Run `./test.sh` and `./build.sh` before submitting changes to source or packaging.
- Document substantial behavior changes in `docs/SPEC.md`; durable architecture decisions belong in `docs/decisions/`.
- Keep build tools small: system Swift/AppKit/Foundation/CryptoKit/ImageIO and a separately installed ExifTool.
- Changes to culling, deletion, metadata writes, cloud features, catalog databases, or RAW development expand the scope and need an explicit product decision.
- Development builds use local ad hoc signing. Public download releases require Developer ID signing, notarization, and successful live workflow qualification.
- Release automation creates draft prereleases. Publishing them, adding Apple credentials, choosing a source license, or configuring domains remains an owner decision.
- The completed design interview is documentation-only. Follow `docs/SPEC.md` and ADR-0003 for the first-public-release target; keep advanced history, filename templates, second copies, and source deletion in the later backlog. Do not infer an implementation request from a recorded design answer. Current source preservation and external-ExifTool facts remain accurate until authorized implementation changes them.
