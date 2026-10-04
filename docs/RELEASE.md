# Release procedure

## Development builds and draft releases

CI runs on `main`, pull requests, and manual dispatch. It tests synthetic originals, builds the GUI/icon, creates a ZIP and checksum, and extracts the ZIP to verify the signature, architecture, version, and icon. Development artifacts expire after seven days.

To create a reviewable draft, update `VERSION` if needed, commit, and push a matching version tag:

```sh
git tag v0.1.0-alpha.1
git push origin v0.1.0-alpha.1
```

Use a new version/tag for each release. Tags are immutable release inputs; don't move an existing tag. The tag's base version must match `VERSION`. The workflow builds both architectures and creates a **draft prerelease**, uploading ZIPs and SHA-256 files. A failed build prevents draft creation. Rerunning can replace assets only while that release is still a draft; published releases are refused by the upload step.

These automatic drafts are **ad hoc signed and not notarized**. They must not be presented as ordinary public-ready downloads. The app needs ExifTool separately. No public release is automatically published.

## Developer ID signing and notarization

Apple Developer Program membership and a Developer ID Application certificate are required for the normal direct-download signing path. Install/configure the certificate in the release operator's Keychain, then build:

```sh
SIGNING_IDENTITY='Developer ID Application: Your Verified Name (TEAMID)' ./build.sh
```

The signed build enables hardened runtime and secure timestamps. Set up a notarization credential profile interactively with Apple's tool; keep credentials in the Keychain, not in Git or shell history:

```sh
xcrun notarytool store-credentials andermic-notary
NOTARY_PROFILE=andermic-notary ./scripts/notarize.sh
./scripts/verify-package.sh
```

The script refuses an ad hoc/non-Developer-ID build, submits the app to Apple's notary service, staples and validates the ticket, checks Gatekeeper assessment, and repackages the stapled app. Preserve `APP_VERSION` if building for a prerelease label; it must be set consistently for build, notarize, and archive verification.

The CI workflow does not yet import certificates or perform notarization. After local signing works, add a dedicated protected signing workflow with scoped secrets and cleanup. Credentials/certificates should never enter this repository. Don't simply publish the automatic ad hoc draft assets as a signed release.

## Public-release gates

- Complete the live qualification items in [ROADMAP.md](ROADMAP.md).
- Settle ExifTool installation/redistribution and choose a source license.
- Build and notarize the qualified tag/commit for each distributed architecture.
- Verify signatures, stapled tickets, Gatekeeper behavior, checksums, architecture, and a clean installation on another Mac.
- Replace the draft's development ZIPs/checksums with the notarized packages, identify signing/qualification in release notes, and review before publishing.
- Only after a domain/hosting decision, point the product website to published downloads. Don't place private draft URLs on a public website.

References: [Apple Developer ID](https://developer.apple.com/developer-id/), [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [GitHub-hosted runner labels](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
