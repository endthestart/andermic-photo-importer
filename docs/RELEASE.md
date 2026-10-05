# Release procedure

## Source previews — current distribution

The owner selected MIT and approved source publication on 2026-10-05 ([ADR-0006](decisions/0006-mit-source-preview.md)). Publish the source so users can build and install locally. Apple Developer Program enrollment is deferred. The public release has GitHub’s source ZIP/tar archives and build instructions, with **no prebuilt app assets**.

Before a source preview:

1. Review the tracked files and history for credentials, personal photos, private paths, and local settings/reports. Keep those out of Git.
2. Run `./test.sh`, `./build.sh`, `./scripts/package.sh`, and `./scripts/verify-package.sh`. Both hosted architectures must also pass. UI changes additionally need the synthetic GUI exercise.
3. Confirm `LICENSE`, third-party notices, instructions, known limitations, and the changelog match the release.
4. Merge the reviewed change into `main`, then use a new immutable version tag. Its base version must match `VERSION`.

For example:

```sh
git tag v0.1.0-alpha.2
git push origin v0.1.0-alpha.2
```

The tagged workflow builds and verifies both architectures, then creates a **draft source prerelease without binary assets**. Review the draft and publish it explicitly. GitHub exposes source archives for the tagged commit. Failed builds prevent draft creation; the workflow refuses to update an already published release. Do not move release tags or attach the development app ZIPs to a source-only release.

CI also runs on `main`, pull requests, and manual dispatch. Its architecture-specific app ZIPs/checksums are development artifacts, retained for seven days. They are not public app-release downloads. Local package verification extracts the ZIP and checks signatures, architecture, version, icon, app license, helper licenses/manifest, system-only linkage, and metadata reading in an empty environment.

Support is best-effort through GitHub Issues. Source previews have no support or compatibility guarantee. Synthetic tests and hosted builds are distinct from live camera, destination-volume, editor, and clean-machine qualification; see [VALIDATION.md](VALIDATION.md).

## Local use

Follow [README.md](../README.md#build-and-install). Build on your Mac, open the resulting app, and optionally drag it into Applications. Locally built apps use ad hoc signing. No paid Apple membership or external metadata tool is needed. Keep your normal photo backups; source files are never deleted by this version.

## Future app-binary releases

A normal signed direct-download release remains a separate milestone:

- Complete the live qualification items in [ROADMAP.md](ROADMAP.md).
- Review redistribution of the bundled Perl/ExifTool runtime under its upstream terms. The app’s MIT license does not change those licenses.
- Exercise real-camera metadata/grouping, card/destination performance, interruptions, physical ejection, editor handoff, upgrade migration, and clean installation on supported macOS versions and architectures.
- Obtain a Developer ID Application certificate and qualify notarization of the nested Perl runtime.
- Verify the final signed/stapled packages, Gatekeeper behavior, checksums, and a clean installation before explicitly publishing app downloads.

To sign after configuring your certificate in Keychain:

```sh
SIGNING_IDENTITY='Developer ID Application: Your Verified Name (TEAMID)' ./build.sh
```

The build signs the bundled interpreter and compiled extensions, then the app, with hardened runtime and secure timestamps. Notarization has not been attempted. Keep credentials in Keychain, never Git or shell history:

```sh
xcrun notarytool store-credentials andermic-notary
NOTARY_PROFILE=andermic-notary ./scripts/notarize.sh
./scripts/verify-package.sh
```

The notarization script refuses ad hoc/non-Developer-ID builds, submits the app, staples and validates the ticket, checks Gatekeeper assessment, and repackages. Preserve `APP_VERSION` consistently across build, notarization, and verification for prerelease labels. CI does not import certificates or notarize. Add a protected signing workflow only after local qualification.

References: [Apple Developer ID](https://developer.apple.com/developer-id/), [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
