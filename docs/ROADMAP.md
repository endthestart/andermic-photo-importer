# Roadmap

## Foundation — current work

- Private repository and durable product specification.
- Native GUI and accepted Aperture A branding.
- Synthetic import-safety checks.
- CI builds/tests/packages Apple silicon and Intel variants.
- Version tags produce reviewable draft prereleases with checksum files.

## Before a public download

- Qualify real NEF/GPR/JPEG metadata and pairing against representative cameras using owner-approved samples.
- Exercise Photography-volume copies, safe interruptions/removal, card ejection, and actual DxO folder handoff.
- Design and validate duplicate identity after embedded metadata changes, without violating immutable-original or no-catalog requirements.
- Improve large-library scans with measured evidence and a documented tradeoff.
- Settle ExifTool installation/bundling and redistribution requirements.
- Test supported macOS versions and end-user install permissions.
- Choose a source license and release support expectations.
- Developer ID signing, hardened runtime, notarization, and clean-install verification.

## After reliable importing

Evaluate optional fast culling only if DxO's existing fullscreen P/U/X workflow leaves a concrete gap. Any implementation needs an explicit portable-state design and an actual interoperability test. Rejection should be a mark; deleting files should be a separate user action.

## Domain hosting — later owner decision

Choose an Andermic domain/subdomain and hosting service. A small product page can provide screenshots, setup, release notes, and links to signed downloads. Source hosting and website hosting are independent. No DNS changes or website publication are part of the repository foundation.
