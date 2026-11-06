#!/bin/zsh
# Make the update feed (appcast.xml) for a release DMG. Koe's release reads it from
#     https://github.com/eduard1414ed/koe/releases/latest/download/appcast.xml
# (SUFeedURL in build.sh), so with every release both files go into the GitHub release, tagged v<version>:
# Koe-<version>.dmg and this appcast.xml. "latest" then always points at the newest feed.
#
#     ./menubar/appcast.sh dist/Koe-0.9.1.dmg [--notes notes.html] [--url-base URL] [--out FILE]
#
# The version, build number and minimum macOS come from the app inside the DMG. The DMG is signed with the
# private EdDSA key from the keychain (made once with Sparkle's generate_keys, account com.tsarionov.koe):
# Koe installs an update only if this signature matches the public key in its Info.plist. The first time,
# macOS may ask to let sign_update use the key — Always Allow.
#   --notes FILE     what's new, as a piece of HTML (<ul><li>…</li></ul>); shown in the update window
#   --url-base URL   where the DMG will be, instead of the GitHub release (for a test feed on localhost)
#   --out FILE       instead of appcast.xml next to the DMG
set -e
HERE="${0:A:h}"
PROJECT="${HERE:h}"
REPO="https://github.com/eduard1414ed/koe"
KEY_ACCOUNT="com.tsarionov.koe"
SIGN_UPDATE="$PROJECT/.build/app-release/artifacts/sparkle/Sparkle/bin/sign_update"

[[ $# -ge 1 && -f "$1" ]] || { echo "usage: $0 Koe-<version>.dmg [--notes FILE] [--url-base URL] [--out FILE]"; exit 1; }
DMG="${1:A}"
shift
NOTES="" URL_BASE="" OUT="${DMG:h}/appcast.xml"
while (( $# )); do
  case "$1" in
    --notes) NOTES="$2"; shift 2 ;;
    --url-base) URL_BASE="${2%/}"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "unknown option: $1"; exit 1 ;;
  esac
done
[[ -x "$SIGN_UPDATE" ]] || { echo "No Sparkle tools yet: build the release first (./menubar/build.sh release)."; exit 1; }

# what's inside: the app's Info.plist
MOUNT="$(mktemp -d)"
trap 'hdiutil detach "$MOUNT" -quiet -force 2>/dev/null; rmdir "$MOUNT" 2>/dev/null' EXIT
hdiutil attach "$DMG" -readonly -nobrowse -noverify -noautoopen -mountpoint "$MOUNT" -quiet
PLIST="$MOUNT/Koe.app/Contents/Info.plist"
[[ -f "$PLIST" ]] || { echo "There's no Koe.app in $DMG."; exit 1; }
read_plist() { /usr/libexec/PlistBuddy -c "Print $1" "$PLIST"; }
VERSION="$(read_plist CFBundleShortVersionString)"
BUILD="$(read_plist CFBundleVersion)"
MIN_OS="$(read_plist LSMinimumSystemVersion)"
[[ "$(read_plist CFBundleIdentifier)" == "com.tsarionov.koe" ]] || { echo "This DMG isn't the release (bundle ID)."; exit 1; }
hdiutil detach "$MOUNT" -quiet
trap - EXIT
rmdir "$MOUNT"

NAME="${DMG:t}"
if [[ -n "$URL_BASE" ]]; then
  URL="$URL_BASE/$NAME"
else
  URL="$REPO/releases/download/v$VERSION/$NAME"
fi
# sparkle:edSignature="…" length="…"
SIGNATURE="$("$SIGN_UPDATE" --account "$KEY_ACCOUNT" "$DMG")"
[[ "$SIGNATURE" == *edSignature* ]] || { echo "Couldn't sign $NAME: $SIGNATURE"; exit 1; }
DESCRIPTION=""
[[ -n "$NOTES" ]] && DESCRIPTION="      <description><![CDATA[$(cat "$NOTES")]]></description>"

cat > "$OUT" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Koe</title>
    <link>$REPO</link>
    <description>Updates for Koe</description>
    <language>en</language>
    <item>
      <title>Koe $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
$DESCRIPTION
      <enclosure url="$URL" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
EOF
xmllint --noout "$OUT"
echo "Feed: $OUT — Koe $VERSION (build $BUILD), $URL"
