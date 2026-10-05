# ADR-0004: Bundle a pinned Perl runtime and ExifTool

Status: accepted for the first public release on 2026-10-04 (implementation). Public distribution still requires the qualification in [RELEASE.md](../RELEASE.md).

## Context

ADR-0003 requires a self-contained app: no Homebrew, separately installed ExifTool, or path setting. ExifTool is a Perl program; copying the script alone still depends on a Perl interpreter. macOS currently ships `/usr/bin/perl`, but Apple has deprecated bundled scripting runtimes, and its version and module set are outside our control.

## Decision

- `scripts/metadata-helper.lock` pins Perl 5.44.0 and ExifTool 13.59 by version and upstream SHA-256 (Perl from cpan.org's published `.sha256.txt`; ExifTool from exiftool.org's `checksums.txt`). `scripts/build-metadata-helper.sh` downloads them (ExifTool from its SourceForge release archive, which keeps every version, with exiftool.org and CPAN as fallbacks verified against the same hash) and refuses any mismatch.
- Perl is built unmodified from source for the build machine's architecture with `-Duserelocatableinc`, a macOS 13 deployment target, no local/Homebrew include or library paths, and without the optional DB_File/GDBM/NDBM/ODBM extensions. `@INC` is derived from the interpreter's own location, so the runtime works from inside the bundle.
- The app contains `Contents/Resources/MetadataHelper/` with the interpreter, its complete standard library (documentation pods, headers, the static `libperl.a`, and auxiliary scripts omitted), unmodified ExifTool, `licenses/` (Perl Artistic License, GPL v1, Perl README, ExifTool README), and `manifest.json` recording versions, sources, hashes, licenses, and omissions.
- The app runs the bundled interpreter with the bundled script by absolute path, with `-config ""` and an environment of only `PATH=/usr/bin:/bin` and `LC_ALL=C`, so `PERL5LIB`, `PERL5OPT`, and user ExifTool configuration cannot affect it. It never searches `PATH`, Homebrew, or the system Perl. The ExifTool path setting is removed.
- The build signs every nested Mach-O (the interpreter and 48 XS `.bundle` modules) before sealing the app; Developer ID builds sign them with hardened runtime and timestamps.
- Tests and CI use the same helper the app bundles. `verify-package.sh` checks the extracted archive's manifest against the lock file, every nested binary's architecture, signature, and system-only linkage, keeps `@INC` inside the bundle, and runs the packaged app's `--verify-metadata-helper` mode under `env -i` on a fixture whose date only ExifTool can supply.
- About and Help → Third-Party Notices show component versions, sources, hashes, changes, and the full license texts.

## Consequences

The app grows by about 57 MB unpacked (about 19 MB compressed per architecture). Each architecture builds its own runtime natively; CI caches it by lock/script hash, and tagged releases rebuild from verified sources. Metadata-helper updates ship only with app updates.

Perl and ExifTool are distributed under the Artistic License or GPL, at the distributor's choice. Notices identify the unmodified standard sources and where to obtain them; the owner should confirm the chosen licensing route during release review. Notarization of nested Perl code, clean-machine behavior, and macOS versions earlier than the build host are not yet qualified.
