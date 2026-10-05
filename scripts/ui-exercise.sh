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
{"schemaVersion":2,"destination":"$root/Library","folderTemplate":"{YYYY}/{MM}/{DD}","cardInsertion":"indicate","presets":[],"photoLab":"","openInDxO":false,"eject":false}
JSON

cat > "$root/run/script.txt" <<STEPS
# 1. Folder source: preview, select a subset, import across dates.
open $root/Card
waitIdle
wait 2
snap 01-preview
state preview
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
# 3. Cancellation and retry on a large card.
open $root/BigCard
waitIdle
click Import All New
wait 0.3
click Stop
waitModal
wait 0.5
snap 07-cancelled
alert
click OK
waitIdle
state after-cancel
snap 08-after-cancel
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
snap 09-card-inserted
state card
check Use this date
setDate 2026-10-06
check Eject card
click Import All New
waitModal
alert
snap 10-card-ejected
click Done
waitIdle
wait 2
state after-eject
# 5. Advanced options and third-party notices.
advanced
wait 1
snap 11-advanced-options
notices
wait 1
snapKey 12-third-party-notices
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
            DONE) break 2 ;;
        esac
    done
done
grep -E '^(STATE|ALERT|FAIL)' "$log" || true
grep -q '^DONE' "$log" || { echo 'GUI exercise did not finish.' >&2; exit 1; }
! grep -q '^FAIL' "$log" || { echo 'GUI exercise had failed steps.' >&2; exit 1; }
[[ ! -d /Volumes/SYNTHCARD ]] || { echo 'Synthetic card was not ejected.' >&2; exit 1; }

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
for card in ('Card', 'BigCard', 'DiskCard'):
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
print(f'Verified {imported} imported files byte-for-byte against synthetic sources; collision group kept one shared suffix: {suffixed}.')
PY
echo "Screenshots: $screens"
