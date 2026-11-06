#!/bin/zsh
# Build Koe. Two kinds of build, from the same code:
#
#   ./menubar/build.sh            the development build: "Koe", bundle ID com.tsarionov.koe.dev, process KoeDev,
#                                 put into ~/Applications and started. No automatic updates.
#   ./menubar/build.sh release    the release: "Koe", bundle ID com.tsarionov.koe, process Koe, with automatic
#                                 updates (Sparkle). Nothing is installed or started: the app and its DMG go into
#                                 dist/ (dist/Koe.app, dist/Koe-<version>.dmg). The update feed: menubar/appcast.sh.
#
# The code is a Swift package (Package.swift in the project folder, with FluidAudio for transcription and, in the
# release, Sparkle for updates): `swift build -c release`, then the binary is packed into an .app here.
# The version and build number come from version.env. Everything else that makes the two builds different is in
# the lines right below; the app works out all other names and paths from the bundle ID (menubar/Identity.swift).
# A build only touches its own things: the app $APP, the process running from $APP, the data folder $SUPPORT.
set -e
HERE="${0:A:h}"
PROJECT="${HERE:h}"
MODE="${1:-dev}"

case "$MODE" in
  dev)
    BUNDLE_ID="com.tsarionov.koe.dev"
    APP_NAME="Koe"
    EXEC="KoeDev"
    APP="$HOME/Applications/$APP_NAME.app"
    IDENTITY="Koe Dev Signing"   # see make_cert.sh
    ;;
  release)
    BUNDLE_ID="com.tsarionov.koe"
    APP_NAME="Koe"
    EXEC="Koe"                   # stopped only by its path, never by name: another app's process may be called Koe too
    OUT="$PROJECT/dist"
    APP="$OUT/$APP_NAME.app"
    # updates: the feed on GitHub Releases (appcast.sh makes it) and the public half of the EdDSA key that signs
    # every update. The private half is in the keychain of whoever publishes releases, never in this repository.
    FEED_URL="https://github.com/eduard1414ed/koe/releases/latest/download/appcast.xml"
    SPARKLE_PUBLIC_KEY="l5ofk8JJwHVqqCYKGU148879IcjY65mUmbYs6MYzsPU="
    # notarization: a notarytool profile in the keychain, made once with
    #   xcrun notarytool store-credentials koe-notary --apple-id … --team-id …
    NOTARY_PROFILE="koe-notary"
    ;;
  *)
    echo "usage: $0 [release]"
    exit 1
    ;;
esac
SUPPORT="$HOME/Library/Application Support/$BUNDLE_ID"
source "$PROJECT/version.env"
VERSION="${KOE_VERSION:-$VERSION}"
BUILD_NUMBER="${KOE_BUILD:-$BUILD}"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

# guard against a mistake in the settings above: never replace an app that isn't this one (another bundle ID)
existing=""
[[ -f "$APP/Contents/Info.plist" ]] && existing="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null)"
stop=0
[[ "$BUNDLE_ID" != com.tsarionov.* || ( -n "$existing" && "$existing" != "$BUNDLE_ID" ) ]] && stop=1
# the development build is the only one that's installed and stopped by its process name — so that name can't be Koe;
# the release is never put into ~/Applications (the development build lives there) or anywhere outside dist/
[[ "$MODE" == dev && "$EXEC" == "Koe" ]] && stop=1
[[ "$MODE" == release && ( "$BUNDLE_ID" != "com.tsarionov.koe" || "$APP" != "$PROJECT/dist/"* ) ]] && stop=1
if (( stop )); then
  echo "Stop: the build settings point at another Koe build ($APP${existing:+ is $existing}, $EXEC, $BUNDLE_ID)."
  exit 1
fi

# signing. The development build: our own certificate (see make_cert.sh) so the microphone and audio permissions
# survive a rebuild; without it the app gets an ad-hoc "-" signature and macOS asks for permissions again.
# The release: a Developer ID certificate if there is one (from an Apple Developer account), otherwise ad-hoc.
if [[ "$MODE" == dev ]]; then
  if ! security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    echo "No \"$IDENTITY\" certificate — signing without it (permissions will reset after the next build)."
    echo "To create the certificate: ./menubar/make_cert.sh"
    IDENTITY="-"
  fi
else
  IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
  if [[ -z "$IDENTITY" ]]; then
    IDENTITY="-"
    echo "Note: no Developer ID certificate — the release is signed ad-hoc. It runs on this Mac, but on another Mac"
    echo "macOS won't open it until the person allows it in System Settings → Privacy & Security → Open Anyway, and"
    echo "every update asks for the permissions again. Updates themselves still work: Sparkle checks them with the"
    echo "EdDSA key. A Developer ID certificate needs an Apple Developer account."
  fi
fi

# the package's own build folder: $PROJECT/.build (the first build downloads FluidAudio and takes a few minutes).
# The release builds with the Updates trait (Sparkle) in a folder of its own, so the two builds don't keep
# rebuilding each other; its binary looks for Sparkle.framework in Contents/Frameworks.
if [[ "$MODE" == dev ]]; then
  SWIFT_ARGS=(-c release --package-path "$PROJECT")
else
  SWIFT_ARGS=(-c release --package-path "$PROJECT" --scratch-path "$PROJECT/.build/app-release" --traits Updates
              -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
fi
swift build "${SWIFT_ARGS[@]}"
BIN="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"
cp "$BIN/KoeDev" "$BUILD/$EXEC"

# app icon — the water ring, ready-made PNGs from koe-logo
iconutil -c icns -o "$BUILD/AppIcon.icns" "$HERE/../koe-logo/assets/app-icon/AppIcon.iconset"

# the app at $APP, if it's running from there: by its path, because another app's process may have the same name
running_here() {
  for pid in $(pgrep -x "$EXEC"); do
    [[ "$(ps -o comm= -p "$pid")" == "$APP/Contents/MacOS/$EXEC" ]] && echo "$pid"
  done
}
# don't cut off a recording that's going: replacing the app quits it
# (recording = session.partial.json exists and one of the tracks next to it — mic.aac, mic-2.wav,
# system.aac… — changed in the last 10 seconds). The development build always quits; the release only if it's
# running from dist/ (an installed one, in /Applications, isn't touched).
quits=1
[[ "$MODE" == release && -z "$(running_here)" ]] && quits=0
recording=0
for partial in "$SUPPORT/inbox"/*/session.partial.json(N); do
  recent=("${partial:h}"/*.(aac|wav)(Nms-10))
  (( ${#recent} )) && recording=1
done
if (( quits && recording )); then
  echo "$APP_NAME is recording right now. Stop it from the menu and run the build again."
  exit 1
fi
if [[ "$MODE" == dev ]]; then
  pkill -x "$EXEC" 2>/dev/null || true
else
  for pid in $(running_here); do kill "$pid"; done
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BUILD/$EXEC" "$APP/Contents/MacOS/"
mv "$BUILD/AppIcon.icns" "$APP/Contents/Resources/"
# the starting list of hallucinations: copied into the data folder the first time it's needed
cp "$PROJECT/hallucinations.txt" "$APP/Contents/Resources/"
# licenses: Koe's own and those of everything it's built with (About points to them)
cp "$PROJECT/LICENSE" "$PROJECT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/"

# the release's Info.plist lines for Sparkle: where the feed is, the key updates must be signed with, and
# checking on its own (once a day) unless turned off in Settings
UPDATES_PLIST=""
if [[ "$MODE" == release ]]; then
  UPDATES_PLIST="  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>"
fi
PLIST="$APP/Contents/Info.plist"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$EXEC</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Eduard Tsarionov. MIT License.</string>
  <key>NSMicrophoneUsageDescription</key><string>Koe records your microphone so it can transcribe what was said afterwards.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Koe records the sound of other apps (the other people on a call in Zoom, Telegram or your browser, a webinar, a video) so it can transcribe it afterwards.</string>
  <key>LSUIElement</key><true/>
$UPDATES_PLIST
</dict>
</plist>
EOF
plutil -lint -s "$PLIST"

if [[ "$MODE" == dev ]]; then
  codesign --force --sign "$IDENTITY" "$APP"
  open "$APP"
  echo "Done: $APP"
  exit 0
fi

# ---------- the release: Sparkle, hardened runtime, DMG, notarization ----------

# Sparkle.framework from the package, without its XPC services: those are only for sandboxed apps
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"

# signing from the inside out: Sparkle's helpers, the framework, then the app with the hardened runtime and its
# entitlements (menubar/Koe.entitlements: the microphone and nothing else). A Developer ID signature needs a secure
# timestamp (notarization checks it); ad-hoc can't have one.
if [[ "$IDENTITY" == "-" ]]; then TIMESTAMP=(--timestamp=none); else TIMESTAMP=(--timestamp); fi
SIGN=(codesign --force --sign "$IDENTITY" --options runtime "${TIMESTAMP[@]}")
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
"${SIGN[@]}" "$SPARKLE/Autoupdate"
"${SIGN[@]}" "$SPARKLE/Updater.app"
"${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
ENTITLEMENTS="$HERE/Koe.entitlements"
if [[ "$IDENTITY" == "-" ]]; then
  # see Koe.entitlements: an ad-hoc signature has no team, so library validation would refuse Sparkle.framework
  ENTITLEMENTS="$BUILD/Koe.entitlements"
  cp "$HERE/Koe.entitlements" "$ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ENTITLEMENTS"
fi
"${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"
echo "Signed: $([[ "$IDENTITY" == "-" ]] && echo "ad-hoc" || echo "$IDENTITY"), hardened runtime"

# notarization: Apple checks the app and the DMG for malware; the ticket is then stapled to both, so Gatekeeper
# lets them open without going online. Needs a Developer ID signature and the notarytool profile above.
can_notarize=0
if [[ "$IDENTITY" == "-" ]]; then
  echo "Notarization: skipped — no Apple Developer account (no Developer ID certificate)."
elif ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "Notarization: skipped — no \"$NOTARY_PROFILE\" profile in the keychain. To make it (once):"
  echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID"
else
  can_notarize=1
fi
notarize() {
  echo "Notarizing $1 (usually a few minutes)…"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}
if (( can_notarize )); then
  ditto -c -k --keepParent "$APP" "$BUILD/Koe.zip"
  notarize "$BUILD/Koe.zip"
  xcrun stapler staple "$APP"
fi

DMG="$OUT/$APP_NAME-$VERSION.dmg"
"$HERE/dmg.sh" "$APP" "$DMG"
if [[ "$IDENTITY" != "-" ]]; then
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
fi
if (( can_notarize )); then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
fi
echo "Done: $APP ($VERSION, build $BUILD_NUMBER)"
echo "      $DMG"
echo "The update feed for it: ./menubar/appcast.sh \"$DMG\""
