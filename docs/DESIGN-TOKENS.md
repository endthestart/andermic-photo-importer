# SENEX family design tokens v1

Shared by SENEX Corvus (photo importer, AppKit) and SENEX Pictor (nightscape stacker, egui). Both repositories keep an identical copy of this file at `docs/DESIGN-TOKENS.md`. Each app's theme code follows it, and each app's tests compare its theme constants with its own copy.

To change a value, edit this file in both repositories, raise the version in the title in both, and land the two changes as paired commits that name the new version. Neither app depends on the other's code.

The owner approved this design on 2026-10-30: one dark palette and one accent for both apps, and a shared night-sky icon with a constellation emblem per app.

## Colours

Dark only. Both apps ignore the system appearance; Corvus pins AppKit's dark appearance. Text on ACCENT and on status fills is GROUND.

| Token | Hex | Use |
|---|---|---|
| GROUND | #0D1117 | window background, photo grid |
| CHROME | #11161D | headers, sidebars, footers, panels |
| CARD | #151A22 | cards, empty thumbnails |
| RAISED | #1B2330 | selected or hovered surfaces, progress track |
| LINE | #2A3340 | borders |
| LINE_STRONG | #3A4A63 | hovered borders, key caps |
| TEXT | #E6EAF0 | text |
| MUTED | #A1ABB8 | secondary text, section labels |
| ACCENT | #8FB4FF | star blue: selection, primary actions, progress |
| ACCENT_DIM | #2C4A7A | selection fill |
| GOOD | #5CC28A | done, imported |
| WARN | #F0A93B | look at this: missing date, cached match |
| BAD | #F07167 | failed |

Corvus's native AppKit controls (buttons, checkboxes, pop-up menus, sliders) keep the system accent: AppKit has no app-wide accent override without an Xcode asset catalog.

## Type roles

Pictor uses Inter (SIL OFL, bundled), because it also runs on Linux and Windows. Corvus uses SF Pro, the system font, because its native controls, menus and alerts are drawn in it. Sizes are points.

| Role | Size | Weight | Use |
|---|---|---|---|
| heading | 24 | Semibold | screen and window headings |
| panel | 15 | Semibold | panel and card titles |
| strong | 14 | Semibold | emphasised text, group titles |
| secondary | 12 | Regular | counts, status lines, details |
| section | 12 | Regular | section labels: uppercase, MUTED, +0.8 pt tracking |
| badge | 11.5 | Semibold | badges |
| note | 11 | Regular | notes; no text is smaller |

Body text is 13 in Corvus (AppKit's control size) and 14 in Pictor (its button labels). Corvus may use SF Pro Medium for 11–12 pt labels beside controls. Other sizes are app-specific and stay between 11 and 30.

## Corner radii

| Name | Points | Use |
|---|---|---|
| card | 12 | cards, Settings window |
| button | 8 | buttons, menus |
| tile | 8 | tiles, thumbnails |
| control | 6 | controls |
| key | 4 | key caps |

Badges and progress bars are capsules: the radius is half the height.

## Components

- **Badges:** capsule, `badge` type. Strong: ACCENT fill. Quiet: LINE outline with MUTED text. Status: GOOD, WARN or BAD fill. Badges over photos use GROUND at 80 % with TEXT, because outlines disappear on images.
- **Buttons:** one primary per view, rightmost. Return presses it and Esc cancels. Labels are Title Case verbs ("Import All New", "Open Folder…").
- **Selection:** 2 pt ACCENT outline; 3 pt on photos. Where the selected item is itself close to the accent (Pictor's frame chart), the outline is TEXT.
- **Progress:** an ACCENT capsule on a RAISED track. Spinners stay native.
- **Icons:** the same meaning in both apps: tick GOOD, triangle WARN, cross BAD, dot ACCENT.
- **Errors:** inline in WARN or BAD, plus the footer status line. Dialogs only for outcomes that stop the work, titled by what failed.
- **Cards:** CARD fill, 1 pt LINE border, `card` radius, 18 × 16 pt padding. Other spacing is per layout.

## App conventions

- **Names:** binaries, bundles and in-app text use the Latin name alone (Corvus.app, `corvus`), and so does the Application Support folder. Repository names, README titles, release titles and branding say "SENEX Corvus" and "SENEX Pictor".
- **Window title:** "<subject> — <App>", or "<App>" alone when nothing is open. Windows remember their frames.
- **App menu:** About <App>, Third-Party Notices…, Settings… (⌘,), Hide <App>, Hide Others, Show All, Quit <App>. No Help menu.
- **Window menu:** Minimize (⌘M), Zoom, Bring All to Front.
- **Shortcuts:** macOS standard keys keep their standard meaning; app-specific keys never reuse them.
- **About:** name, version and "© 2026 Michael Anderson · <licence>". Bundled components are credited in Third-Party Notices.

## Icon template

Pixels on a 1024 × 1024 canvas (S = 1024, pad = 100), y pointing down. Each app has its own script and random seeds (Corvus: `scripts/make-icon.swift`; Pictor: `tools/icon.py`). The values are identical; pixels may differ with each renderer's anti-aliasing.

1. **Gradient** over the full canvas: row y has t = y/S and colour (⌊10 + 14t⌋, ⌊16 + 22t⌋, ⌊36 + 42t⌋).
2. **Milky Way:** 60 ellipses, k = 0…59, t = k/60, centred at (pad + 80 + t·(S − 2·pad − 160), 0.62S − t·0.38S), radii 120 × 60, colour (150, 165, 230). Their union at alpha 10 on its own layer, Gaussian blur 40.
3. **Dots:** 140. For each, draw x = U(pad, S − pad), then y = U(pad, 0.72S), then r from {1.2, 1.6, 2.2, 2.8}, then alpha from 120–255 inclusive. Colour (220, 228, 255).
4. **Emblem placement:** star positions are J2000 RA and Dec in degrees. (RA0, Dec0) is the centre of their RA and Dec ranges; x = −(RA − RA0)·cos Dec0 and y = −(Dec − Dec0), so east is left and north is up. Scale the larger side of the projected box to 0.34S and centre the box at (0.50S, 0.36S).
5. **Figure lines:** ACCENT at alpha 150 on one layer, 5 px wide, round ends.
6. **Stars:** R = clamp(64 − 16·(V − 2.6), 28, 64). A halo disc of radius R in ACCENT at alpha 120 on its own layer, Gaussian blur 0.5R. Then a four-point sparkle: an eight-point polygon at angles k·45° − 90°, alternating radius R and 0.22R, filled (232, 240, 255).
7. **Treeline,** drawn last: base 0.78S, x from pad. While x < S − pad: w = U(26, 52), h = U(60, 190), triangle (x, base), (x + w/2, base − h), (x + w, base), then x += 0.8w. Ground rectangle (pad, base) to (S − pad, S − pad). Fill (6, 9, 14).
8. **Mask:** rounded rectangle (pad, pad) to (S − pad, S − pad), radius 185. Outside it is transparent.

The .icns holds 16, 32, 128, 256 and 512 px and their @2x sizes, made with `sips` and `iconutil`.

| App | Emblem | Stars: RA, Dec, V | Figure | Seeds (dots, trees) |
|---|---|---|---|---|
| Corvus | Corvus, the Crow | α 182.103, −24.729, 4.02 · ε 182.531, −22.620, 3.00 · γ 183.951, −17.542, 2.59 · δ 187.466, −16.516, 2.95 · β 188.597, −23.397, 2.65 | α–ε–γ–δ–β–ε | 11, 5 |
| Pictor | Pictor, the Painter's Easel | α 102.048, −61.941, 3.27 · β 86.821, −51.066, 3.86 · γ 87.457, −56.166, 4.50 | α–γ–β | 7, 3 |
