# Corvus status

Updated 2026-11-05. The closing note for the owner's cleanup week. Plans are in the
[roadmap](ROADMAP.md), evidence in [validation](VALIDATION.md), the October code review in
[audit/CLEANUP-2026-10.md](audit/CLEANUP-2026-10.md), and the plan for the suite in the
[SENEX photo suite roadmap](https://claude.ai/artifact/XdZEY2gDarpfCR2HzhvNSi).

Everything is on `main` in [endthestart/senex-corvus](https://github.com/endthestart/senex-corvus)
(renamed from `andermic-photo-importer` on 2026-11-05). The
[0.2.0-alpha.1 source preview](https://github.com/endthestart/senex-corvus/releases/tag/v0.2.0-alpha.1)
was published on 2026-11-05 from `737817f`; it is source only, with no app binaries. `./test.sh`
passes 261 synthetic checks, and a fresh clone tests and builds on the Intel Mac Pro. CI builds,
tests and package-verifies Apple silicon and Intel on every push to `main` and every pull request.

Done: the rename to Corvus (bundle ID `com.senexapps.corvus`), the design shared with SENEX Pictor
([tokens v1](DESIGN-TOKENS.md)), the October code review and its fixes, ExifTool 13.60, the
house-style formatter in CI, and the split of `MainWindow.swift` and `ImportCore.swift` by area.
The merged branches were deleted on 2026-11-05; their tips were
`claude/corvus-pictor-design-0851ec` f7b3a0198c53fe41f45a9d01a07fc68dbb654d00,
`claude/corvus-split-mainwindow` e49d5715c792002008e6b7b3c84a8e450e14334d,
`claude/corvus-split-importcore` 58963701775675f8e800a4ec90fa8b70346c26ee and
`claude/corvus-release-0.2.0-alpha.1` ef08cae10a5f1b4f70cd9af61355610ab32c8173.

## Blocked on whom

| What | Waiting on |
| --- | --- |
| VoiceOver, physical card reinsertion and a real-card import | Owner's hands-on run, 2026-11-07 |
| The synthetic GUI exercise on Apple silicon, and on `main` since PR #6 | A Mac with an unlocked screen; it last passed on Intel on PR #5's tree |
| Developer ID signing, notarization and public app binaries | Owner: the Apple Developer Program, decided after the hands-on run |
| `codex/sd-card-metadata-cache` on GitHub (its PR #3 was closed; its ADRs 0011 to 0014 are on `main`) | Codex confirming nothing is left on it |

## Move list

| Thing | Today | After the move off the Mac Pro |
| --- | --- | --- |
| Source | GitHub | The same; any clone builds on a Mac |
| Build, tests, packaging | Mac Pro (Intel) and GitHub CI (`macos-15`, `macos-15-intel`) | Any Mac with macOS 13 or later and the Command Line Tools, plus CI. The MiniPC runs Debian and cannot build it |
| Releases | A version tag makes a draft source prerelease in CI; the owner publishes it | The same, from any clone that can push |
| GUI exercise (`scripts/ui-exercise.sh`) | Mac Pro, needs an unlocked screen | Any Mac with an unlocked screen; not run in CI |
| Real-card and camera checks | The owner's Mac and card reader | The same, only with the owner's authorization |
| Bundled Perl and ExifTool sources | Downloaded by the first build into `build/downloads`, checked by SHA-256 | Each clone downloads them again; nothing to copy |
| Build output (`build/`, `dist/`) | Repo folder, ignored by git | Do not move; rebuild |
| Settings, presets and import reports | Application Support on the Mac that runs the app, not the Mac Pro | Stay with the installed app |
| Backup of the 2026-10-05 app build | External storage | The same |

Clone into an ordinary folder, not under `/tmp` or `/private/tmp`. Foundation shortens
`/private/tmp/…` to `/tmp/…`, and `/tmp` is a symlink, which the import checks refuse, so
`./test.sh` fails there. The same refusal applies to a source or destination chosen under `/tmp`.
