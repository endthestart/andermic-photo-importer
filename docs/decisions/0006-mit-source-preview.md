# ADR-0006: MIT source preview before signed app downloads

Status: accepted by the owner on 2026-10-05.

## Decision

Publish the repository and an initial source-only preview under MIT. The owner chose to defer Apple Developer Program enrollment and wants to use a locally built app now. Source archives and build/install instructions are the public release deliverables. Do not attach the ad hoc app ZIPs to the public release.

CI continues to build, test, package, and verify both architectures. Version tags create draft source prereleases after both builds succeed. Publishing remains explicit. Local app builds include the app’s MIT license, third-party notice summary, and the existing complete helper notices.

## Consequences

Apple signing, notarization, clean-machine installation, supported-version qualification, and genuine-camera workflow evidence remain recorded work for a future app-binary release. They do not block publishing the source preview. Preserve original files and existing settings; no new import features or deletion behavior are added for publication.

This supersedes the initial private-repository and source-license deferral in ADR-0001 and the public-source gate in ADR-0003. The source preview does not claim production readiness. Perl and ExifTool retain their own terms, distinct from the app’s MIT license.
