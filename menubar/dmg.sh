#!/bin/zsh
# Make the DMG people download: a window with Koe and a shortcut to Applications to drag it onto, on a background
# in the logo's style (menubar/dmg/background.swift). build.sh release runs it:
#     ./menubar/dmg.sh dist/Koe.app dist/Koe-0.9.0.dmg
# Only macOS's own tools: hdiutil makes the disk image, Finder lays out the window (as you would by hand; the
# first time macOS may ask to let Terminal control Finder), swift draws the background.
set -e
HERE="${0:A:h}"
PROJECT="${HERE:h}"
[[ $# == 2 && -d "$1" ]] || { echo "usage: $0 Koe.app OUT.dmg"; exit 1; }
APP="${1:A}"
OUT="${2:A}"
VOLNAME="Koe"
# where the icons go in the window (their centers); background.swift draws the arrow between these
KOE_AT="{170, 205}"
APPS_AT="{470, 205}"

TMP="$(mktemp -d)"
MOUNT=""
cleanup() {
  [[ -n "$MOUNT" ]] && hdiutil detach "$MOUNT" -quiet -force 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

STAGE="$TMP/stage"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/Koe.app"
ln -s /Applications "$STAGE/Applications"
swift "$HERE/dmg/background.swift" "$PROJECT/koe-logo/assets/wordmark/koe-wordmark.png" "$TMP"
# one TIFF with both sizes: Finder picks the sharp one on a Retina screen
tiffutil -cathidpicheck "$TMP/background.png" "$TMP/background@2x.png" -out "$STAGE/.background/background.tiff" 2>/dev/null
# the disk's own icon (the ring), shown on the desktop and in Finder's sidebar while it's open
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"

# a writable image first, to lay out its window; then a compressed read-only copy of it
hdiutil create -quiet -ov -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ -format UDRW "$TMP/rw.dmg"
# mounted where Finder sees it; the mount point comes from hdiutil (it's "/Volumes/Koe 1" if a Koe disk is already open)
MOUNT="$(hdiutil attach "$TMP/rw.dmg" -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\// {print $NF}')"
[[ -d "$MOUNT" ]] || { echo "Couldn't open the disk image."; exit 1; }
# "custom icon" flag on the disk, so Finder uses .VolumeIcon.icns (SetFile comes with the command line tools)
SETFILE="$(xcrun -f SetFile 2>/dev/null || true)"
[[ -n "$SETFILE" ]] && "$SETFILE" -a C "$MOUNT"

if osascript - "$MOUNT" "$KOE_AT" "$APPS_AT" <<'EOF' >/dev/null
on run argv
  set mountPoint to item 1 of argv
  tell application "Finder"
    set d to (POSIX file mountPoint) as alias
    open d
    set w to container window of d
    set current view of w to icon view
    set toolbar visible of w to false
    -- 640 × 400 inside the window, plus the title bar
    set bounds of w to {200, 120, 840, 548}
    set o to icon view options of w
    set arrangement of o to not arranged
    set icon size of o to 128
    set text size of o to 13
    set background picture of o to file ".background:background.tiff" of d
    set position of item "Koe.app" of d to (run script (item 2 of argv))
    set position of item "Applications" of d to (run script (item 3 of argv))
    -- hidden files stay hidden for most people; for those who show them, out of the way below the window
    repeat with f in {".background", ".VolumeIcon.icns", ".fseventsd"}
      if exists item f of d then set position of item f of d to {320, 640}
    end repeat
    update d without registering applications
    delay 1
    close w
  end tell
end run
EOF
then
  # Finder writes the layout into .DS_Store on its own schedule — wait for it
  for i in {1..20}; do [[ -f "$MOUNT/.DS_Store" ]] && break; sleep 0.5; done
  [[ -f "$MOUNT/.DS_Store" ]] || echo "Warning: Finder didn't save the window layout; the DMG opens as a plain window."
else
  echo "Warning: couldn't ask Finder to lay out the window (allow Terminal to control Finder in System Settings →"
  echo "Privacy & Security → Automation). The DMG works, but opens as a plain window."
fi
# macOS's file event log for the disk: not needed on a read-only image
rm -rf "$MOUNT/.fseventsd"
sync
hdiutil detach "$MOUNT" -quiet
MOUNT=""

rm -f "$OUT"
# ULFO: compressed with LZFSE (macOS 10.11+), smaller and faster to open than zlib
hdiutil convert -quiet "$TMP/rw.dmg" -format ULFO -o "$OUT"
echo "DMG: $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
