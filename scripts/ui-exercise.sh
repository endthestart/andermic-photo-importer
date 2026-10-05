#!/bin/bash
# Exercises the real GUI with synthetic fixtures and captures window screenshots.
# Builds a separate test-only app with the UI_AUTOMATION driver; dist/ is not modified.
# Uses isolated settings/reports, a synthetic folder card, and a synthetic disk-image card.
# It never selects, scans, or ejects any other mounted volume.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(pwd)/build/ui-exercise"
app="$root/Andermic Photo Importer.app"
screens="$(pwd)/build/screens"
test -d "dist/Andermic Photo Importer.app" || ./build.sh
pkill -f "$root/Andermic Photo Importer.app" 2>/dev/null || true
for volume in /Volumes/SYNTHCARD*; do [[ -d "$volume" ]] && hdiutil detach "$volume" -quiet || true; done
rm -rf "$root" "$screens"; mkdir -p "$root/run" "$root/Library" "$root/Settings" "$screens"

# Test-only app: the shipped bundle with an executable that also contains the driver.
ditto "dist/Andermic Photo Importer.app" "$app"
xcrun swiftc -swift-version 5 -O -D UI_AUTOMATION -module-cache-path build/module-cache Source/Core/*.swift Source/App/*.swift -o "$app/Contents/MacOS/PhotoImport"
codesign --force --sign - "$app"

# Fixtures: a 26-photo folder card, a large card for cancellation, and a DMG card for insertion.
xcrun swiftc -module-cache-path build/module-cache scripts/make-synthetic-card.swift -o "$root/make-card" 2>/dev/null
"$root/make-card" "$root/Card" >/dev/null
"$root/make-card" "$root/DiskCard" 3 >/dev/null
mkdir -p "$root/BigCard/DCIM/100SYNTH"
for index in 1 2 3 4 5 6; do
    file="$root/BigCard/DCIM/100SYNTH/BIG_000$index.JPG"
    cp "$root/Card/DCIM/100SYNTH/DSC_000$index.JPG" "$file"
    head -c $((150 * 1024 * 1024)) /dev/urandom >> "$file"   # bytes after the JPEG end marker
done
cards="$root/Card/DCIM/100SYNTH"
mkdir -p "$root/Library/Earlier import" "$root/Library/2026/09/12"
cp "$cards/DSC_0001.JPG" "$root/Library/Earlier import/renamed-copy.jpg"           # renamed duplicate
printf 'a different photo from another camera' > "$root/Library/2026/09/12/DSC_0003.NEF"   # name collision
hdiutil create -quiet -srcfolder "$root/DiskCard" -volname SYNTHCARD -fs ExFAT -format UDRW "$root/card.dmg"
cat > "$root/Settings/settings.json" <<JSON
{"schemaVersion":2,"destination":"$root/Library","folderTemplate":"{YYYY}/{MM}/{DD}","cardInsertion":"indicate","launchInBackground":true,"presets":[],"photoLab":"","openInDxO":false,"eject":false}
JSON

cat > "$root/run/script.txt" <<STEPS
wait 1
expect visible false
expect policy accessory
expect tray true
tray Show Andermic Photo Importer
wait 1
expect visible true
expect policy regular
# 1. Folder source: preview, select a subset, import across dates.
open $root/Card
waitIdle
wait 2
snap 01-preview
state preview
expect fallbackVisible true
# The grid's Select All (via the Edit menu and responder chain) selects every new dated photo.
menu Deselect All Photos
expect selected 0
focus grid
menu Select All
expect selected 23
toggle DSC_0002
toggle DSC_0004
toggle DSC_0005
wait 1
snap 02-subset
state subset
click Import 20 Selected
waitModal
wait 1
snap 03-import-complete
alert
click Done
waitIdle
state after-subset
# 2. Rescan: imported photos are recognized; undated photos need an explicit date.
rescan
waitIdle
wait 1
snap 04-rescan
state rescan
check Use this date
setDate 2026-09-14
wait 1
snap 05-fallback-date
state fallback
click Import All New
waitModal
alert
click Done
waitIdle
popup type 1
wait 1
snap 06-filter-pairs
popup type 0
# 2b. Changed sidecars: a dated RAW+JPEG+XMP group and the undated video+THM group.
check Use this date
shell change-sidecars
rescan
waitIdle
expect status DSC_0006=sidecarChanged
expect status MVI_0026=sidecarChanged
expect fallbackVisible false
expect selected 0
toggle DSC_0006
toggle MVI_0026
expect importSelected Import 2 Selected|true
wait 1
snap 07-sidecar-changes
click Import 2 Selected
waitModal
alert
click Done
waitIdle
rescan
waitIdle
expect status DSC_0006=imported
expect status MVI_0026=imported
state after-sidecars
# 2c. Standard menu commands route through the responder chain.
focus event
editing Lisbon Trip
focus grid
menu Minimize
wait 1.5
expect miniaturized true
deminiaturize
wait 1.5
expect miniaturized false
menu Close Window
wait 1
expect visible false
expect policy accessory
expect tray true
tray Show Andermic Photo Importer
wait 1
expect visible true
expect policy regular
# A background card scan stays hidden while new photos are compared.
popup card 2
close
wait 1
card $root/Card
expect visible false
expect policy accessory
waitIdle
expect groups 26
expect visible false
expect policy accessory
expect tray true
tray Settings…
wait 1
expect visible true
expect policy regular
check Start in the menu bar
expect backgroundLaunch false
check Start in the menu bar
expect backgroundLaunch true
popup card 1
# 3. Cancellation and retry on a large card.
open $root/BigCard
waitIdle
click Import All New
wait 0.3
click Stop
waitModal
wait 0.5
snap 08-cancelled
alert
click OK
waitIdle
state after-cancel
snap 09-after-cancel
click Import All New
waitModal
alert
click Done
waitIdle
rescan
waitIdle
state after-retry
# 4. Card insertion: show-and-scan mode with a synthetic disk-image card, then verified ejection.
popup card 0
shell attach-card
wait 4
waitIdle
wait 1
snap 10-card-inserted
state card
check Use this date
setDate 2026-10-06
check Eject card
click Import All New
waitModal
alert
snap 11-card-ejected
click Done
waitIdle
wait 2
state after-eject
# 5. Advanced options and third-party notices.
advanced
wait 1
snap 12-advanced-options
notices
wait 1
snapKey 13-third-party-notices
close
wait 1
expect visible false
expect policy regular
closeNotices
wait 1
expect policy accessory
expect tray true
tray Settings…
wait 1
popup card 1
check Start in the menu bar
expect backgroundLaunch false
quit
STEPS

open -n "$app" --args -AndermicSettingsDirectory "$root/Settings" -AndermicUIScript "$root/run/script.txt"
log="$root/run/script.txt.log"
deadline=$((SECONDS + 300)); handled=0
while (( SECONDS < deadline )); do
    sleep 0.3
    [[ -f "$log" ]] || continue
    lines="$(wc -l < "$log")"
    while (( handled < lines )); do
        handled=$((handled + 1))
        line="$(sed -n "${handled}p" "$log")"
        case "$line" in
            SNAP*) read -r _ name window _ <<<"$line"
                   sleep 0.4
                   screencapture -x -o -l "$window" "$screens/$name.png"
                   touch "$root/run/$name.done" ;;
            "SHELL attach-card") hdiutil attach -quiet "$root/card.dmg"; touch "$root/run/attach-card.done" ;;
            "SHELL change-sidecars")
                # Keep the originally imported versions for byte verification, then change the card's sidecars.
                mkdir -p "$root/run/original-sidecars"
                cp "$cards/DSC_0006.XMP" "$cards/MVI_0026.THM" "$root/run/original-sidecars/"
                printf '<x:xmpmeta><rating>1</rating> changed on the card</x:xmpmeta>' > "$cards/DSC_0006.XMP"
                printf 'changed thumbnail' > "$cards/MVI_0026.THM"
                touch "$root/run/change-sidecars.done" ;;
            DONE) break 2 ;;
        esac
    done
done
grep -E '^(STATE|ALERT|FAIL)' "$log" || true
grep -q '^DONE' "$log" || { echo 'GUI exercise did not finish.' >&2; exit 1; }
! grep -q '^FAIL' "$log" || { echo 'GUI exercise had failed steps.' >&2; exit 1; }
[[ ! -d /Volumes/SYNTHCARD ]] || { echo 'Synthetic card was not ejected.' >&2; exit 1; }

# A second process uses the saved foreground-launch preference, with real-card scanning disabled.
cat > "$root/run/foreground.txt" <<'STEPS'
wait 1
expect visible true
expect policy regular
expect tray true
expect backgroundLaunch false
close
wait 1
expect visible false
expect policy accessory
tray Show Andermic Photo Importer
wait 1
expect visible true
expect policy regular
quit
STEPS
open -n "$app" --args -AndermicSettingsDirectory "$root/Settings" -AndermicUIScript "$root/run/foreground.txt"
foregroundLog="$root/run/foreground.txt.log"
deadline=$((SECONDS + 30))
while (( SECONDS < deadline )); do
    [[ -f "$foregroundLog" ]] && grep -q '^DONE' "$foregroundLog" && break
    sleep 0.3
done
grep -q '^DONE' "$foregroundLog" || { echo 'Foreground-launch exercise did not finish.' >&2; exit 1; }
! grep -q '^FAIL' "$foregroundLog" || { cat "$foregroundLog"; exit 1; }
echo 'Menu-bar launch, hidden scan, window/Dock lifecycle, settings, and foreground relaunch passed.'

# Every imported file must byte-match a source original; no staging files may remain.
python3 - "$root" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''): h.update(chunk)
    return h.hexdigest()
sources = {}
for card in ('Card', 'BigCard', 'DiskCard', 'run/original-sidecars'):
    for base, _, files in os.walk(os.path.join(root, card)):
        for name in files: sources.setdefault(sha(os.path.join(base, name)), []).append(name)
imported, partial = 0, []
for base, _, files in os.walk(os.path.join(root, 'Library')):
    for name in files:
        path = os.path.join(base, name)
        if name.endswith('.partial'): partial.append(path)
        if name.startswith('.') or 'Earlier import' in path or path.endswith('2026/09/12/DSC_0003.NEF'): continue
        assert sha(path) in sources, f'{path} does not match any source original'
        imported += 1
assert not partial, partial
pre = open(os.path.join(root, 'Library/2026/09/12/DSC_0003.NEF'), 'rb').read()
assert pre == b'a different photo from another camera', 'existing file was modified'
names = os.listdir(os.path.join(root, 'Library/2026/09/12'))
suffixed = sorted(n for n in names if n.startswith('DSC_0003__'))
assert len(suffixed) == 2 and suffixed[0].split('.')[0] == suffixed[1].split('.')[0], suffixed
day12, day14 = os.path.join(root, 'Library/2026/09/12'), os.path.join(root, 'Library/2026/09/14')
xmp = sorted(n for n in os.listdir(day12) if n.startswith('DSC_0006'))
thm = sorted(n for n in os.listdir(day14) if n.startswith('MVI_0026'))
assert open(os.path.join(day12, 'DSC_0006.XMP'), 'rb').read() == open(os.path.join(root, 'run/original-sidecars/DSC_0006.XMP'), 'rb').read(), 'existing sidecar was modified'
companions = [n for n in xmp if n.startswith('DSC_0006__')]
assert len(companions) == 3 and len({n.split('.')[0] for n in companions}) == 1, xmp
assert len([n for n in thm if n.startswith('MVI_0026__')]) == 2, thm
print(f'Changed sidecars kept existing files and arrived with matching photo copies: {companions + [n for n in thm if "__" in n]}.')
print(f'Verified {imported} imported files byte-for-byte against synthetic sources; collision group kept one shared suffix: {suffixed}.')
PY
echo "Screenshots: $screens"
