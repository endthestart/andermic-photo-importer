# Roadmap

Status: core-first public release accepted on 2026-10-04. Discovery changed documentation only; no implementation is scheduled or performed under the owner's notes-only instruction.

## Foundation — existing alpha

- Private repository, native macOS app, and accepted Aperture A branding.
- Source/destination comparison, content-confirmed duplicate detection, verified copies, and local settings/reports.
- CI builds/tests/packages Apple silicon and Intel variants.
- Version tags produce unpublished draft prereleases with checksum files.
- See [validation](VALIDATION.md) for actual tests and [the specification](SPEC.md) for alpha limitations.

## First public release — polished core

- Pictures/year/month/day defaults, remembering configured roots/templates and preserving existing settings on upgrade.
- Apple Photos-style thumbnail selection with selected/all-new actions, selection counts, and date/file-type filters.
- Familiar configuration side panels, visible common settings, saved import presets, and expandable advanced sections; no wizard.
- RAW+JPEG/sidecar selection groups, preserving and verifying each physical file with safe grouping/collision rules.
- Configurable card-insertion behavior: show and scan automatically by default, or quietly indicate availability while the app is running. Copying remains an explicit user action.
- Simple destination comparison and current lightweight reporting; keep advanced history/recovery out of this milestone.
- Self-contained metadata helper/runtime packaging and visible open-source notices, with no separate installation required.
- Preserve source files: no delete-after-import option in this release.

## Qualification before public distribution

- Test genuine camera metadata, grouping, sidecar coverage, dates, and related-file collisions using approved representative fixtures.
- Measure real-card and large-library preview performance; preserve full-copy verification.
- Exercise local/removable destination copies, interruption/removal, missing dates, repeat imports, physical-card ejection, and supported editor handoff.
- Test supported macOS versions and both architectures, upgrade/settings migration, and clean-machine installation without external metadata dependencies.
- Pin and verify redistributed helper/runtime components, include applicable licenses/notices, and qualify packaged fallback paths.
- Choose the app's source license and release support expectations.
- Complete Developer ID signing, hardened runtime, notarization, and clean-install verification. Publishing remains an owner decision.

## Later updates — approved advanced directions

Ordering is not yet selected; none blocks the first public release.

- Lightweight persistent import history/cache and selectable duplicate-detection approaches, with explicit missing/offline/edited-copy and reimport behavior.
- Optional filename templates using dates, camera information, sequences, and custom text, consistently applied to related files.
- Optional second verified import copy to another destination. If enabled, both copies must verify before source cleanup is offered.
- Optional delete after import, requiring verification and a final batch confirmation showing source card and file count. Settle deletion scope, duplicate eligibility, source identity, partial cleanup failures, option persistence, and cleanup/ejection ordering before implementation.

## Other future possibilities

- Linux: possible later platform; retain the native macOS foundation for the first release.
- Culling: outside the agreed first-release and advanced-import scope. Reconsider only after a separate product decision establishes a concrete need and portable state/interoperability requirements.
- Domain hosting: choose an owner-controlled Andermic domain/subdomain and hosting service for a small product page with screenshots, setup, release notes, and signed downloads. No DNS changes or website publication are authorized by this discovery work.
