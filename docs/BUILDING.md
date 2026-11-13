# Building Koe

## What you need

- A Mac with Apple Silicon and macOS 15 or later.
- Xcode Command Line Tools with Swift 6.2 or later (`xcode-select --install`). The full Xcode isn't needed.

Everything is built by one script, `menubar/build.sh`, in two kinds:

| | Development build | Release |
|---|---|---|
| Command | `./menubar/build.sh` | `./menubar/build.sh release` |
| App | `~/Applications/Koe.app`, built and started | `dist/Koe.app` and `dist/Koe-<version>.dmg`; nothing is installed or started |
| Bundle ID | `com.tsarionov.koe.dev` | `com.tsarionov.koe` |
| Process | `KoeDev` | `Koe` |
| Data, logs, caches | folders named `com.tsarionov.koe.dev` | folders named `com.tsarionov.koe` |
| Transcripts by default | `~/Documents/Koe Dev` | `~/Documents/Koe` |
| "Looks like a call started" | off by default (so it doesn't double a release on the same Mac) | on by default |
| Signing | the self-signed "Koe Dev Signing" certificate (`make_cert.sh`) | Developer ID if the keychain has one, otherwise ad-hoc |
| Hardened runtime, entitlements | no | yes (`menubar/Koe.entitlements`) |
| Automatic updates | none: Sparkle isn't even linked | Sparkle 2 |

Both use the same code. Everything the app calls itself and every folder it uses follows from the bundle ID
(`menubar/Identity.swift`), so the two builds keep their own data and logs and never touch each other on one Mac.
`build.sh` refuses to build over an app with another bundle ID, and refuses to replace an app that's recording.

The version is set in one place, `version.env`: `VERSION` (what people see) and `BUILD` (a whole number, one more
with every release; updates compare it). For a test build with another version:
`KOE_VERSION=0.9.1 KOE_BUILD=2 ./menubar/build.sh release`.

## The development build

```bash
./menubar/make_cert.sh
```

```bash
./menubar/build.sh
```

`make_cert.sh` creates a self-signed "Koe Dev Signing" certificate in your keychain, once. macOS
remembers permissions by the app's signature, so with the certificate your permissions survive
rebuilds. On the first build macOS may ask for your Mac password. Click **Always Allow**.

`build.sh` builds `~/Applications/Koe.app` (`swift build -c release`; the first build downloads
FluidAudio and takes a couple of minutes), signs it and launches it.

To remove the development build completely: quit it from the menu, then delete `~/Applications/Koe.app`,
`~/Library/Application Support/com.tsarionov.koe.dev`, `~/Library/Logs/com.tsarionov.koe.dev`,
`~/Library/Caches/com.tsarionov.koe.dev` and the "Koe Dev Signing" certificate (Keychain Access → My
Certificates). Your transcripts in `~/Documents/Koe Dev` stay.

## The release

```bash
./menubar/build.sh release
```

It builds with the package trait `Updates` (Sparkle) in its own build folder, `.build/app-release`, and then:

1. **Packs the app**: `dist/Koe.app` with `Sparkle.framework` in `Contents/Frameworks` (without Sparkle's XPC
   services, which only sandboxed apps need), `LICENSE` and `THIRD_PARTY_NOTICES.md` in `Contents/Resources`.
   `Info.plist` gets the update feed (`SUFeedURL`), the public update key (`SUPublicEDKey`) and daily checks.
2. **Signs it** from the inside out (Sparkle's helpers, the framework, the app), with the hardened runtime and
   `menubar/Koe.entitlements`: the microphone, nothing else. With a **Developer ID Application** certificate in the
   keychain it signs with that, with a secure timestamp. Without one it signs ad-hoc and says what that means: the
   app runs on the Mac that built it, but on other Macs Gatekeeper asks people to allow it in System Settings, and
   every update asks for the permissions again. An ad-hoc signature has no team, so the hardened runtime's library
   validation would refuse `Sparkle.framework`; for ad-hoc only, `build.sh` adds
   `com.apple.security.cs.disable-library-validation`.
3. **Notarizes** the app, staples the ticket, makes the DMG, signs and notarizes the DMG, staples it — but only with
   a Developer ID and a notarytool profile called `koe-notary` in the keychain. Make the profile once:

   ```bash
   xcrun notarytool store-credentials koe-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
   ```

   Without them the step is skipped with a message.
4. **Makes the DMG**, `dist/Koe-<version>.dmg`, with `menubar/dmg.sh`: a window with Koe and a shortcut to
   Applications on a background in the logo's colors (`menubar/dmg/background.swift` draws it). Only macOS's own
   tools: `hdiutil`, Finder (to lay out the window; the first time macOS may ask to let Terminal control Finder)
   and `swift`. Without Finder the DMG still works, as a plain window.

The release never goes into `~/Applications` (the development build is there) or anywhere outside `dist/`. Its process
is called `Koe`, so the script stops a running copy only by its exact path, never by name.

### Updates

Koe's release looks for updates in `https://github.com/eduard1414ed/koe/releases/latest/download/appcast.xml`. Every
GitHub release carries `Koe-<version>.dmg` and `appcast.xml`, so "latest" always points at the newest feed. It also
carries `Koe.dmg`, a copy with a name that never changes, for the download button on the website.

Updates are signed with an EdDSA key. The public half is in `build.sh` (`SPARKLE_PUBLIC_KEY`); the private half lives
only in the keychain of whoever publishes releases (Sparkle's `generate_keys`, account `com.tsarionov.koe`), never in
the repository. Back it up somewhere safe: without it no installed Koe will accept another update.

```bash
.build/app-release/artifacts/sparkle/Sparkle/bin/generate_keys --account com.tsarionov.koe -x koe-update-key.txt
```

A fork that publishes its own builds needs its own key (`generate_keys --account <yours>`), its own feed address
(`FEED_URL` in `build.sh`, `REPO` in `appcast.sh`) and its own bundle ID.

To publish a release:

1. Raise `VERSION` and `BUILD` in `version.env`.
2. `./menubar/build.sh release`.
3. Make the feed:

   ```bash
   ./menubar/appcast.sh dist/Koe-0.9.1.dmg --notes notes.html
   ```

   It reads the version from the app inside the DMG, signs the DMG with the key from the keychain and writes
   `dist/appcast.xml`. `--notes` is a piece of HTML with what's new, shown in the update window.
4. Create a GitHub release tagged `v<version>` and attach `Koe-<version>.dmg`, a copy of it named `Koe.dmg`, and
   `appcast.xml`.

**Testing an update without GitHub.** Build an older version and install it, build a newer one, make its feed with
`--url-base http://127.0.0.1:8765/`, serve the folder (`python3 -m http.server 8765 --bind 127.0.0.1`), then:

```bash
open -n -W --stdout /tmp/update.txt /Applications/Koe.app --args --update-test http://127.0.0.1:8765/appcast.xml
```

`--update-test` checks, downloads and installs with no windows, answering as if every button were clicked, and Koe
starts again as the new version. `--expect-rejected` checks the opposite: a feed whose signature doesn't match
must be refused. To try the real update window instead: `defaults write com.tsarionov.koe SUFeedURL <feed>`,
then menu → **Check for Updates…**; `defaults delete com.tsarionov.koe SUFeedURL` afterwards.

## How it's put together
The app is a Swift package (`Package.swift` in the project
folder, the code in `menubar/`), built by `build.sh`. Everything happens in its own process: recording,
transcription (FluidAudio 0.18.0 with the Parakeet Ultra model) and updating names. There's no Python anymore.
After a recording stops it goes into the queue; the queue does one recording at a time, off the main thread,
and survives quitting (`state/queue.json`). Name updates are jobs of the same queue. The list of recordings is
`state/registry.json`.

| File | What it does |
|---|---|
| `Package.swift` | the package: one program, `KoeDev` (renamed to `Koe` in the release's `.app`), FluidAudio (pinned to 0.18.0) and, with the `Updates` trait, Sparkle (pinned to 2.10.0) |
| `version.env` | the version and build number, for both builds |
| `menubar/Identity.swift` | every name and path of the app, derived from the bundle ID |
| `menubar/KoeMenu.swift` | the menu, alerts, the menu bar icon, About |
| `menubar/Recorder.swift` | recording: one microphone through AVAudioEngine and system audio through a Core Audio process tap; several microphones (or an aggregate device) and system audio through one private aggregate device |
| `menubar/RecordingFormat.swift` | quality presets, input devices, the microphone and input channel choices, how they're laid out into tracks |
| `menubar/WavWriter.swift` | the Lossless WAV writer: survives a crash, turns into RF64 past 4 GB |
| `menubar/CallSources.swift` | what goes on the system audio track (off, all, ticked apps), the "Looks like a call started" suggestion |
| `menubar/SettingsWindow.swift` | the Settings window (General and Names), the Speech models list |
| `menubar/Setup.swift` | the setup window (first run, Settings → Set Up Again…) |
| `menubar/Intro.swift` | the logo intro at the start of the setup window: the ring, then the letters of "koe" |
| `menubar/Permissions.swift` | the microphone, system audio and notification permissions: their state, asking, the system audio check, the microphone level in the setup window |
| `menubar/Models.swift` | the speech models: sizes, downloading one at a time with progress, free space and internet checks, waiting for the internet, deleting |
| `menubar/TrackAudio.swift` | reading a track (AAC, WAV, RF64, also repaired after a crash) as 16 kHz mono |
| `menubar/Engine.swift` | the recognizer (Parakeet through FluidAudio) behind one interface, Vocabulary, the speech detector and how speech is cut into pieces, where models go, the fine-tuning values (`Tuning`) |
| `menubar/Voices.swift` | telling voices apart on the system audio track (FluidAudio's offline diarization), the 20-second rule, which voice each word belongs to |
| `menubar/MeetingFolder.swift` | what's where in a transcript folder: `transcript.md` and `audio/` in sight, Koe's working files in the hidden `.koe`; moving the files of older folders there |
| `menubar/Transcriber.swift` | one recording → `transcript.md`, `.koe/raw/`, `.koe/meta.json`: tracks lined up, phrases, filters, echo and repeats between microphones, lines, protecting your edits |
| `menubar/Names.swift` | updating names in finished transcripts without transcribing again, `.koe/speakers.json` (and turning old `speakers.toml` into it) |
| `menubar/TranscriptionQueue.swift` | the queue: order, pause, attempts, notifications, the list of recordings, when names need updating |
| `menubar/Updates.swift` | automatic updates with Sparkle (release only), `--update-test` |
| `menubar/build.sh`, `dmg.sh`, `dmg/background.swift`, `appcast.sh`, `Koe.entitlements` | building the app, the DMG and its window, the update feed, what the release may do |
| `menubar/KoeRing.swift`, `KoeStates.swift` | the animated menu bar ring (assets in `koe-logo/`, `koe-logo-states/`) |

**Interface language.** All interface texts go through `String(localized:)` (or SwiftUI string
literals, which work the same way) with the English text as the key. Without translations the key itself is
shown. To add a language, add `<lang>.lproj/Localizable.strings` to the app's `Resources`, no code changes
needed.

## Testing without the menu

```bash
"$HOME/Applications/Koe.app/Contents/MacOS/KoeDev" --record-test 20
```

This records 20 seconds with the saved tracks and settings, transcribes them and quits; the result is in
`~/Documents/Koe Dev`. For this run you can override: `--mic off|default|<UID or name>[,…]` (several —
each its own track), `--system off|all|<bundle ID>[,<bundle ID>…]` (only these apps), `--quality compact|high|lossless`,
`--channels mix|stereo|ch2|each`, `--name mic-2=Guitar`, `--skip mic-2` (don't transcribe that track).
With both off it refuses to record. `--restart-at 8` restarts
capture at second 8, as if you plugged in headphones; `--swap-tap-at 8` swaps the system audio tap inside Koe's
aggregate device, as if the output device changed; `--volume 50` records every track at that volume instead of the
saved ones, `--volume-at 4=200` changes every track's volume at second 4, as the panel's slider; `--no-transcribe` skips transcription. Also: `--mics` (input
devices with their UIDs), `--wav-test <folder>` (write test files with the WAV writer: plain, RF64,
cut off and repaired), `--dump` (print the panel, every tab; `--click "System audio/Zoom"` clicks
a row first, as `Tab/Row`, and the choice is saved just like a real click; `Tab/Row=PERCENT` moves that row's volume
slider), `--panel-png <folder>` (draw each tab
of the panel into `panel-N.png`), `--processes` (audio processes and their
apps), `--watch-calls 30` (print which app Koe would offer to record),
`--settings-png <file> 0…3 [0…1]` (draw a Settings tab — General, Transcription, Transcripts, Help — into an image, scrolled that far), `--setup-png <folder> [download]`
(draw every step of the setup window; `download` starts a model download first), `--intro-png <folder> [live]`
(draw moments of the logo intro; `live` plays it in a window and prints when it ends), `--permissions` (the three
permissions as Koe sees them: run it as the app, `open -n -W --stdout <file> "$HOME/Applications/Koe.app" --args
--permissions`, because from Terminal macOS reports Terminal's permissions), `--check-system-audio` (the
two-second check from the setup window), `--models` (the models, sizes, free space), `--delete-model
recognizer|detector|voices|vocabulary`. `KOE_FREE_SPACE_TEST=<bytes>` pretends the disk has that much free space; `KOE_LIGHT_TEST=1` draws the
app as if the Mac were in light mode (the setup window should stay dark).

Transcription without the menu: `--transcribe <recording's audio folder> [--out <folder>] [--force]`
(one recording, the queue and the list of recordings aren't touched), `--refresh-names <transcript folder>…`
(update names, as after a change in Settings), `--set-speakers <transcript folder> '{"Speaker 1": "Anna"}'` (as the
Names window; `'{"speakers": {…}, "tracks": {"mic-2": "Bob"}}'` also renames microphones); with these three,
`--me`, `--other`, `--vocabulary "Word\nWord"` and `--voices-threshold 0.7` replace what's in Settings for
this run. `--voices <file> <out.json> [--thresholds 0.5,0.6]` tells voices apart in a file at each threshold
(`--sortformer <models folder>` also runs Sortformer, to compare). `--download-models` (download the models,
printing progress), `--run-queue 60` (run the queue for 60 seconds and print what the menu would show;
`--pause-at 10 --resume-at 15`, `--again local:2026-10-29_1501` as **Try Again**), `--decode <track> <file>`
(the track as transcription reads it, 16 kHz float32), `--vad <file>` (speech regions and pieces),
`--pieces-test <file> <pieces.json> <out.json>` (recognize given pieces of a file). `--verbose` also prints the transcription log.

`--update-test <feed> [--expect-rejected]` is in the release only, see [Updates](#updates).
