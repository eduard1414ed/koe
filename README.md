# Koe — record and transcribe calls (and anything else) on your Mac

Koe lives in the menu bar. Click **Start recording** and it captures both sides of a call: your
microphone and the sound of other apps (Zoom, Google Meet, Telegram, a browser tab — anything).
It can also record just your microphone (a voice note, a podcast) or just other apps' sound
(a webinar, a video). Click **Stop** and a minute or two later you get a text transcript with
timestamps and speaker labels:

```
[00:12:34] Me: Let's move the launch to Thursday.
[00:12:41] Speaker: Works for me, I'll tell the team.
```

**Everything stays on your Mac.** Recording and transcription run locally. There are no servers,
accounts, subscriptions or analytics. Koe goes online only to download its speech models (655 MB, once)
and to check for updates. See [Privacy](#privacy).

Koe is free and open source (MIT License). It needs a Mac with Apple Silicon (M1 or later) and macOS 15 or later.

**Website:** [koe.tsarionov.com](https://koe.tsarionov.com). **Download:** the [Releases page](https://github.com/eduard1414ed/koe/releases/latest). To build it yourself, see [docs/BUILDING.md](docs/BUILDING.md).

## What it can do

- **Record any call** without bots joining it and without virtual audio drivers. Your voice and
  everyone else's go on two separate tracks that stay in sync.
- **Pick what to record.** The microphone, system audio, or both: each can be turned off.
- **Record only some apps.** If music or videos are playing, tick the call app (or several apps)
  under **System audio**, and only their sound gets recorded.
- **Pick the microphone and the sound quality.** Use the system's microphone or a specific one (a USB
  mic, a sound card input), and record compact AAC for calls or lossless WAV for podcasts and interviews.
  The sound is recorded as is: no noise reduction, no automatic level.
- **Record several microphones at once.** Two people in a studio with a mic each, a mic plus a sound card
  with an instrument, or an aggregate device from Audio MIDI Setup: every microphone (or every input of
  a sound card) gets its own track and its own name in the transcript, and system audio is recorded
  alongside. All tracks run on one clock, so they stay in sync for hours.
- **Offer to record when a call starts.** When an app starts using your microphone, Koe can show
  a "Looks like a call started" notification with a **Record** button.
- **Tell voices apart.** On the system audio track, Koe works out how many people talked and labels them
  Speaker 1, Speaker 2… in the order they first spoke (one person is just "Speaker"). Afterwards you give them
  names in Settings → Transcripts, without transcribing again. See [Telling voices apart](#telling-voices-apart).
- **Clean up the text.** It skips silence and drops the phrases speech recognition tends to invent in
  quiet moments ("Thanks for watching!"). If you didn't wear headphones, it also removes the echo of the
  other person's voice that your microphone picked up. With two microphones in one room, a line both of them
  heard stays only on the track where it was louder.
- **Spell your words right**, sometimes. List product names and terms under Settings → Transcription →
  **Vocabulary**, and Koe fixes them when the speech model wrote something that sounds similar
  (`Superbase` → `Supabase`). It only works for words in Latin letters; see [Vocabulary](#vocabulary).
- **25 European languages, Russian and English included**, detected automatically. Every word is written in
  its own language, so English terms in Russian speech stay in Latin letters.
- **Survive surprises.** You can switch to AirPods mid-call, unplug a microphone, your Mac can go to sleep,
  or the app can crash, and the recording is kept and still gets transcribed.
- **Keep your edits.** If you edit a transcript and later transcribe that recording again, your edited
  version is saved next to the new one.

## Download and install

1. Download `Koe-<version>.dmg` from the [Releases page](https://github.com/eduard1414ed/koe/releases/latest).
2. Open it and drag **Koe** onto **Applications**.
3. Open Koe from Applications (or Spotlight). It has no Dock icon: look for the ring in the menu bar,
   at the top right of the screen. The first time, a setup window opens (see [First run](#first-run)).
4. Eject the "Koe" disk and delete the DMG.

Koe updates itself after that (see [Updates](#updates)).

## Using Koe

### First run

The first time Koe starts, it opens a setup window (always dark, whatever your Mac's appearance). It begins with
a few seconds of the logo: the water ring flows in the middle, then the letters come in around it and make the
word "koe" (click to skip). Then it walks
you through eight short steps, and any of them can be skipped with **Skip**. The ring on the left flows on
every step, and on the microphone step it moves with your voice:

1. **Welcome**: what Koe does, and that everything stays on your Mac.
2. **Microphone**: macOS asks for permission. Then a bar moves when you speak, and the window shows which
   microphone Koe hears you through.
3. **Sound from other apps**: why Koe needs it (to hear the other people on a call in Zoom, Telegram, a
   browser) and the **Screen & System Audio Recording** permission. **Allow System Audio** starts a two-second
   check: Koe plays a short sound and listens for it. The first time, that's when macOS asks. If the sound
   wasn't heard, the window says so and offers **Open System Settings**.
4. **Notifications**: for "Transcript ready" and "Looks like a call started".
5. **Transcripts folder**: `~/Documents/Koe` unless you pick another one.
6. **Your name**: how your microphone is labeled in transcripts ("Me" by default).
7. **Speech models**: what gets downloaded and how big it is (655 MB in all), with progress. **Continue in
   Background** lets you close the window while the download goes on; the panel shows its progress.
8. **Done**: where to find Koe in the menu bar, and **Open Koe at login**.

If you close the window before **Done**, it opens again the next time Koe starts (a model download you began
keeps going). To go through it again later: Settings → Help → **Set Up Again…**.
A permission you skipped or turned off later shows up as an orange card in the panel (see [The panel](#the-panel)).

### Recording

Panel → **Start recording**. The ring in the menu bar fills with moving water, and the button turns red:
**Stop recording · 12:34**. When you stop, the recording goes off to be transcribed. You'll get a
**Transcript ready** notification when it's done; click it to open the folder. Transcription runs inside the
app and takes about 1 second per minute of speech on a MacBook Air M2, so an hour-long call takes about a minute.
If the speech models aren't on your Mac yet (you skipped that step or deleted them), Koe downloads them before
the first transcription; the panel shows **Downloading speech models… 40 %** on the Transcription tab. Without internet the recording
isn't lost: it waits in the queue, the panel says **Waiting for the speech models** and why, and Koe tries
again when the internet is back (or every few minutes).

If you skipped the permissions in the setup window, macOS asks the first time you record (see
[Permissions](#permissions)).

### Tracks: microphones and system audio

A recording has microphone tracks and a system audio track. Both are picked, and can be turned off, in the panel:

| Track | Choices | Labeled in the transcript as |
|---|---|---|
| **Microphone** | tick one or several: **System default** and/or specific devices, or none (switch off **Record the microphone**). Each ticked one is its own track | the first one is your name ("Me"), the others are named after the device ("Mic 2, 3…" for the inputs of one device). Rename them in Settings → Transcription → **Microphone tracks** |
| **System audio** | off, **All apps**, or only the apps you tick | "Speaker", or "Speaker 1, 2…" if there are several voices |

- A call: both tracks. A voice note or a podcast: only the microphone. A webinar or a video: only system audio.
- You can tick several apps (say, Zoom and a browser): their sound goes on one system audio track. Ticking
  an app while **All apps** is on switches to "only the ticked apps". Unticking the last one turns
  system audio off.
- Koe also picks up an app's helper processes (a browser's tabs) and apps that start making sound
  after the recording began. When a new process appears, about a second of its sound may be lost.
- At least one track has to be on. With both off, the record button is grayed out and says
  **Nothing to record**.
- With only one track, the transcript has only that track's labels, and Koe doesn't look for echo
  (there's nothing to compare it with).
- With several microphones, see [Several microphones](#several-microphones).
- Koe remembers the choice between launches. It can't be changed during a recording.

### The panel

Click the ring in the menu bar and a panel opens; click the ring again, or anywhere else, to close it.
Right-click the ring for a short menu: **About Koe**, **Check for Updates…**, **Settings…** (⌘,), **Quit Koe** (⌘Q).

At the top: the Koe logo and what it's doing now (**Ready**, **Recording**, **42 %**, **Downloading**, **Paused**,
**1 failed**…). Under it, the big green **Start recording** button with the number of tracks on the right; while
recording it turns red and says **Stop recording** with the clock. Then four tabs. An orange dot on a tab means
something there needs you: a missing permission (an orange card in the tab, click it to fix) or a recording that
couldn't be transcribed. At the bottom: **Transcripts** (opens the transcripts folder), **Settings**, **Quit**.

| Tab | What's in it |
|---|---|
| **Microphone** | **Record the microphone** on or off. Tick one or more devices: **System default** (follows the system: connect AirPods and the recording moves to them) and/or specific ones. Virtual devices made by apps (BlackHole, Zoom, Krisp…) and aggregate devices from Audio MIDI Setup are folded under **Other devices** (a ticked one stays in the main list). Each ticked one is its own track, with its own **volume** slider (see [Volume](#volume)). A device with several inputs gets a small **Input channels** menu on its row (see below) |
| **System audio** | **Record system audio** on or off, and its **volume**; **All apps** or the apps you tick (one or several). Apps that are playing sound or using the mic are listed first |
| **Format** | the quality (see below), how many tracks the next recording will have and about how big it will be per hour |
| **Transcription** | **Transcribe automatically**: turning it off pauses transcription (the recording being transcribed starts over when you turn it back on; you can still record, and the menu bar icon stays the same). Under it, what transcription is doing now, which recording and how many are waiting, and recordings that couldn't be transcribed (click one for the reason and **Try Again**). **Save to**: which folder the transcript goes to; during a recording, this recording's. **Names**: how your microphone (**You**, "Me" by default) and the other side (**Others**, "Speaker") are labeled |

While recording, the choices of microphones, system audio and quality are locked (changes would only apply to the
next recording anyway), and each microphone and the system audio show a level meter, so you can see the sound is
coming in. The volume and the folder can still be changed.

### The menu bar icon

| Icon | Meaning |
|---|---|
| a thin ring with a puddle of water at the bottom | all good |
| water flowing around the ring | recording |
| three thin lines drifting past each other | transcribing |
| a ring with an exclamation mark | something needs your attention (open the panel) |

### Recording quality and microphone

The panel → **Format**. Changes apply to the next recording; a recording that's going keeps what it started with.

| Quality | Format | Good for | About per hour |
|---|---|---|---|
| **Compact** (default) | AAC 64 kbps, mono, 48 kHz | calls | 60 MB |
| **High** | AAC 256 kbps, the microphone's sample rate (44.1 or 48 kHz), mono or stereo | good sound without huge files | 230 MB |
| **Lossless** | WAV 24-bit, the microphone's sample rate and channels | podcasts, interviews, music | 1.6 GB at 48 kHz, more at 96 kHz |

"Per hour" is for all tracks together (the panel counts only the tracks that are on) and for your current microphones.
System audio is stereo in High and Lossless, mono in Compact.

**Microphones** are ticked in the panel → **Microphone**. **System default** follows whatever the system uses.
A specific device stays put even if
the system switches to something else. If you record one microphone and it gets unplugged mid-recording, Koe moves to
the system default (the moment of the switch may have a gap of about a second), goes back to your device
if it's plugged in again, and tells you after the recording. With several microphones it doesn't move anywhere
(see below).

**Input channels** is on the row of each ticked device with more than one input, like a sound card or an aggregate device:
**Mix to mono**, **Stereo (1+2)**, one **Channel** (for when the microphone is plugged into one input), or
**Each channel separately**: every input becomes its own mono track (two microphones in one sound card).
All inputs are listed, including those of every device inside an aggregate device.
Koe remembers the choice for each device. Compact is always mono: it mixes the channels or takes the one you chose.

Settings → Transcription → **Microphone tracks** lists every microphone track the next recording will have: its name in the transcript (empty means
the default: your name for the first one, the device name or "Mic 2, 3…" for the others) and **Transcribe**.
Turn **Transcribe** off for an instrument: the track is still recorded and lands in `audio/`, but it isn't
transcribed, and the transcript header says so (`Guitar — not transcribed`). Names and Transcribe are remembered
for each device and input.

### Volume

Every ticked microphone and the system audio have Koe's own volume slider in the panel, from 0 to 200 %.
**100 %** (the middle, marked) is the sound exactly as it came in; 50 % is half as loud, 200 % twice as loud. Click
the percentage to go back to 100 %. It changes only Koe's recording: Zoom, Telegram and the people on the call hear
you as before. Koe remembers it for each microphone (**System default** has its own) and for system audio.

You can move it while recording, and the recording gets louder or quieter from that moment on. Above 100 % the
slider turns orange: the loudest moments can go past the top and get cut, which sounds harsh. If your microphone
already sounds distorted at 100 %, lowering it here won't help: turn down the input on the microphone itself (its
sound card, or System Settings → Sound → Input). The volume barely matters for transcription; it's for listening
to the recording.

### Several microphones

Tick two or more microphones, an aggregate device from Audio MIDI Setup, or **Each channel separately**, and every
microphone or input gets its own track (`mic.aac`, `mic-2.aac`, `mic-3.aac`…). Koe records them all, and system
audio if it's on, through one private aggregate device of its own, so everything runs on the clock of the first
microphone and the tracks don't drift apart even over hours. An aggregate device from Audio MIDI Setup is taken
apart into its own devices for this, so its inputs and system audio are recorded together.

Things to know:
- The recording starts when the slowest microphone is ready. An iPhone used as a microphone can take a few
  seconds to wake up; all tracks start together after that.
- If one of several microphones is unplugged, its track stays silent until it's plugged back in (Koe doesn't
  switch it to another microphone: that would usually put the same room on two tracks), the other tracks go on
  with a gap of a fraction of a second, and Koe tells you after the recording.
- With **System default** ticked next to other microphones, switching the system's microphone restarts all tracks
  with a gap of about half a second. Connecting headphones or an app starting to make sound costs every
  track about 0.1 s or less.
- While it records system audio this way, Koe plays digital silence to your speakers (you won't hear anything).
  macOS only starts recording other apps' sound once one of them makes a sound, and until then it would hold
  up the microphones too.
- Two microphones in one room each hear everybody. When almost the same line is on two microphone tracks at the
  same time, Koe keeps it on the track where it was louder at that moment and drops it from the other one (the
  dropped copy stays in `raw/<track>.json` under `filtered`, with both levels). The rules for "almost the same"
  are the ones for echo: at least 70 % of the text matches within 1.5 seconds; a line of one or two words only
  counts if the other track has exactly the same line. So a short word can still show up twice when one
  microphone heard it as its own line and the other as part of a longer one. "Louder" is how loud the track
  itself was: if one microphone's level is set much higher than the other's, it can win lines that were said
  closer to the other one.
- Echo of the other side of a call is removed on every microphone track.

### "Looks like a call started"

When an app holds the microphone for more than a few seconds and you're not recording, Koe can
send a notification with a **Record** button. It's on by default; turn it off in Settings → General →
**Offer to record calls**. You can also say **Don't offer for this app** right
in the notification, and undo it with Settings → General → **Offer Again**.

**Record** in this notification always records a call: the microphone (if it's off in the panel, the system
default is used for this recording only) and system audio (your ticked apps, or all system audio if it's off).
Your choice in the panel doesn't change.

If the panel shows **Notifications are off**, click it and allow notifications for Koe.

### Telling voices apart

Only the system audio track is split by voice: that's where several people can share one track. Microphones
aren't split: one microphone (or input) is one person, named in Settings.

- Labels go in the order people first spoke: **Speaker 1** spoke first. If only one voice is found, it's
  just **Speaker**.
- Someone with less than 20 seconds of speech in the whole recording doesn't get a label of their own:
  their words go to the most similar voice.
- A line belongs to whoever starts its words. If the voice changes in the middle of a line, the line is
  split in two; a single word of another voice in the middle doesn't count as a change.
- When two people talk at once, the words go to the one heard louder.

How well it works: on recordings of real calls with 2 to 6 people, about 90% of the speech went to the
right person (89–95%; one 4-person recording was worse, 75%). Quiet people who said little are the
usual problem: their words can end up with a louder person's label. It takes a few seconds per
25 minutes of a call, on top of transcription.

Settings → Transcription → **Telling voices apart** is how readily Koe splits the system audio into
different people: toward **more people** if two people got one label, toward **fewer people** if one person
got two labels (it happens on long calls). The new value applies to new recordings; to apply it to an old
one, retranscribe it (Settings → Transcripts). Names you've already given are kept, but the labels
may now mean other people, so check them.

### Names

Settings → **Transcripts** → **Names**: pick a recording, and you'll see each of its tracks: every microphone and every voice
found on system audio. Type a name next to each. Under each row you'll see how long that person talked, and
the ▶ button plays about 5 seconds of their speech, which helps work out who's who. Giving two rows the same
name merges them: it's the same person. Renaming a microphone here renames it in this recording only (the
default names are in Settings → Transcription → Microphone tracks). Click **Save**, and the transcript updates in a few
seconds without transcribing the audio again. All recordings are listed, old ones too.

The names are kept in `speakers.json` in the recording's folder, and you can edit it by hand too:

```json
{
  "speakers" : {
    "Speaker 1" : "Anna",
    "Speaker 2" : "Anna"
  },
  "tracks" : {
    "mic-2" : "Bob"
  }
}
```

`speakers` are the voices on system audio, `tracks` are microphones renamed for this recording.

The transcript catches up the next time Koe looks: when it starts and after each transcription. Older recordings
had `speakers.toml` instead; Koe turns it into `speakers.json` once, keeping the names in it.

Your own name and the default label for other people ("Me" and "Speaker") are in
the panel → Transcription → **Names**. Changing them updates all transcripts, again without transcribing them.

### Vocabulary

Settings → **Transcription** → **Vocabulary**: one word or phrase per line, like `Supabase`, `Tailscale`,
`PostgreSQL`. When the box has words, the names of your microphone tracks are added to them, and Koe downloads a
small helper model (about 100 MB, once) that listens to each piece of speech for these words. Where the speech
model wrote something that sounds similar (`Superbase`, `tail scale`, `PostGur SQL`), the word from the list goes
in. An empty box means no helper model and no download.

What to expect, honestly:
- It costs time: transcription with Vocabulary is about three times slower.
- It only knows Latin letters. In Russian speech the model often writes product names in Cyrillic (`Ноушен`,
  `фигме`), and those aren't fixed.
- It never turns a real English word into a word from the list: without that rule "parcel" became "Vercel" and
  "motion" became "Notion". The price: if a term was heard as a real word ("Ark" for "Arc"), it stays as heard.
- It can still pick the wrong word from the list when two are similar (on our test, Russian `Perkit` became
  `WhisperKit` instead of `Parakeet`). Keep the list to words you actually use.
- What it changed is in `raw/<track>.json` (`vocabulary` next to the phrase) and in `pipeline.log`.

### Settings

Settings has what you set once and rarely touch; everyday choices are in the panel. Open it from the panel's
**Settings** button or right-click the ring → **Settings…** (⌘,). Changes are saved right away.

- **General**: whether Koe offers to record calls (and **Offer Again** for the apps you said no to); **Folders**:
  where transcripts go by default (`~/Documents/Koe` until you change it); **Other**: open at login, **Check for
  updates automatically** (see [Updates](#updates)).
- **Transcription**: the language (always detected automatically, on each track); **Vocabulary** (see above);
  **Telling voices apart** (see above); **Microphone tracks** (names and Transcribe, see above); **Speech
  models**: each model, its size and whether it's on this Mac. **Delete** removes one; a deleted model is
  downloaded again the next time it's needed. **Download** gets the missing ones now. Before downloading, Koe
  checks there's enough free space.
- **Transcripts**: open the latest one, transcribe any recording again, and give names to the people in a
  recording (see [Names](#names)).
- **Help**: **Set Up Again…** (the setup window), the log, the folder with audio waiting to be transcribed, the version.

## Permissions

Koe asks for these, each in its own step of the setup window. You can skip any of them and allow it later.

| Permission | What it's for | Where to change it |
|---|---|---|
| **Microphone** | your voice | System Settings → Privacy & Security → Microphone → Koe |
| **Screen & System Audio Recording** (system audio only) | the other people's voices, and any other app's sound. Koe records sound only, never your screen | System Settings → Privacy & Security → Screen & System Audio Recording → Koe |
| **Notifications** | "Transcript ready", "Looks like a call started", problems | System Settings → Notifications → Koe |
| **Open at login** (optional) | Koe is in the menu bar whenever you need it | Settings → General → Other, or System Settings → General → Login Items |

If a permission is missing when it's needed, the panel shows an orange card about it (and an orange dot on its tab); click it to fix it.

## What you get

Each recording gets its own folder:

```
~/Documents/Koe/2026-10-28_1405/
    transcript.md      the transcript: a short header, then lines like "[00:12:34] Name: text"
    raw/<track>.json   everything that was recognized on each track, with the time of every word;
                       the "filtered" section keeps whatever was thrown away, and why
    meta.json          where the recording came from, when and how it was transcribed
    speakers.json      names of the voices and renamed microphones (set in Settings → Transcripts)
    audio/             the recording itself: mic.aac (mic-2.aac, mic-3.aac… with several microphones) and/or
                       system.aac (.wav for Lossless), and session.json: the format, sample rate and channels
                       of each track, its device and input, name and Transcribe, volume, gaps
```

The header of `transcript.md` says which tracks were recorded and whose sound is on the system audio track,
for example `Recorded with Koe: microphone and system audio (Zoom, Telegram)`, `2 microphones and system audio
(all apps)` or `only the microphone`, plus a line for every track that wasn't transcribed.
`meta.json` has the same as lists: `source.tracks` (`["mic", "mic-2", "system"]`), `source.system_apps`
(empty for all system audio) and `source.not_transcribed`.

Transcribing a recording again only rewrites `transcript.md`, `raw/` and `meta.json`. Notes or anything
else you put in the folder stay untouched. If you edited `transcript.md`, your version is kept as
`transcript.edited-<date>.md`, and Koe tells you so.

### Where Koe keeps its files

| Path | What it is |
|---|---|
| `~/Documents/Koe/` | transcripts (default folder) |
| `~/Library/Application Support/com.tsarionov.koe/` | settings, recordings waiting to be transcribed (`inbox/`), the transcription queue and the list of recordings (`state/`), `hallucinations.txt` |
| `…/com.tsarionov.koe/Models/` | the speech models, downloaded in the setup window or the first time they're needed: Parakeet Ultra (632 MB), the Silero speech detector (1 MB), the models that tell voices apart (`speaker-diarization`, 22 MB) and, only if Vocabulary has words, Parakeet CTC 110M (103 MB). Settings shows them and can delete them |
| `~/Library/Logs/com.tsarionov.koe/` | logs: `recorder.log` (recording), `pipeline.log` (transcription) |
| `~/Library/Caches/com.tsarionov.koe/` | the speech models as prepared for your Mac's Neural Engine (made from the models above the first time), update downloads |
| `~/Library/Preferences/com.tsarionov.koe.plist` | the panel choices: microphones, system audio, quality, recent folders, updates |

## Privacy

- **Your recordings never leave your Mac.** Audio, transcripts and names are files in folders on your Mac (see
  [Where Koe keeps its files](#where-koe-keeps-its-files)). Speech recognition runs on your Mac's Neural Engine.
- **No accounts, no analytics, no crash reports.** Koe doesn't know who you are and doesn't count anything.
- **The network is used for two things only:**
  - downloading the speech models from Hugging Face (`huggingface.co`), once: in the setup window or before the
    first transcription, and the Vocabulary model only if you fill in Vocabulary;
  - checking for updates on GitHub (`github.com`), once a day: Koe downloads a small file that says what the
    latest version is. Nothing about you or your recordings is sent; GitHub, like any website, sees your IP
    address. Turn it off in Settings → General → Other → **Check for updates automatically**.

## Updates

Koe checks for a new version once a day (and you can check any time: right-click the ring → **Check for Updates…**). When there
is one, a window shows what's new, with **Install Update**; Koe downloads it, replaces itself and starts again.
If it finds one while you're busy, it doesn't interrupt you: the right-click menu shows **Update to Koe 0.9.1…** instead.

Updates come from this project's [Releases page](https://github.com/eduard1414ed/koe/releases), and Koe installs one
only if it's signed with the project's key, so nobody else can slip in a fake one. Updates are done by
[Sparkle](https://sparkle-project.org). To stop the daily check: Settings → General → Other → **Check for updates automatically**.

## Common problems

**The other people's voices are missing (system audio is silent).** Koe needs permission to
record other apps' sound: System Settings → Privacy & Security → Screen & System Audio Recording →
Koe. Koe tells you about this after a recording if it notices the problem.

**"No sound came from Zoom" (or "Zoom or Telegram").** The apps ticked under **System audio** made no
sound during the recording: the call was really in another app, for example a browser. Tick that app,
or pick **All system audio**.

**The same line shows up twice under two names.** Two microphones in one room both heard it, and Koe didn't
recognize the copy: usually a short word that one microphone heard on its own and the other inside a longer
line. Delete the extra line by hand.

**A recording with several microphones started a few seconds late.** All tracks start when the slowest
microphone is ready; an iPhone or Bluetooth headset can take a few seconds.

**Koe can't use the microphone.** System Settings → Privacy & Security → Microphone → Koe. The panel's card
**Microphone isn't allowed** opens that place.

**"Waiting for the speech models".** Koe couldn't download them: no internet, the download server didn't
answer, or there isn't enough free space (the message says which). Your recordings are saved and wait in the
queue; Koe tries again by itself when the internet is back or every few minutes. For lack of space, free some
up, then Settings → Speech models → **Download**.

**No notifications.** System Settings → Notifications → Koe → Allow notifications.

**Two people got one label, or one person got two.** Move Settings → Transcription → **Telling voices apart**
toward **more people** or **fewer people** and transcribe the recording again. If one person got two labels,
it's quicker to give both rows the same name in Settings → Transcripts.

**Words like names or product terms come out wrong.** Add them to Settings → Transcription → **Vocabulary**.
It helps with words in Latin letters only, and not always (see [Vocabulary](#vocabulary)).

**Quiet voices in the background got transcribed.** The speech model hears even faint speech (a TV in the
next room, a video playing quietly). Delete those lines by hand.

**A phrase that nobody said shows up in silent moments.** Add it to `hallucinations.txt` in
`~/Library/Application Support/com.tsarionov.koe/`. A piece of text is only dropped when such phrases
make up most of it, so real speech that happens to contain the phrase stays.

**A recording couldn't be transcribed.** Open it in the panel → Transcription to see the reason, then click **Try Again**. Before
that, Koe retries by itself a minute later, up to three times in all. Details are in `pipeline.log`.

**Your Mac went to sleep during a recording.** The recording stops properly when the lid closes. You'll
see a message after waking up, and what was recorded gets transcribed. Your Mac won't fall asleep
on its own while it's recording or transcribing.

**Koe was quit while transcribing.** Nothing is lost: the queue is saved, and the next time Koe starts it
transcribes that recording from the beginning.

## Remove Koe completely

1. If Koe is recording, stop the recording. In Settings → General → Other, turn off **Open at login**. Then
   click **Quit** in the panel.
2. Delete the app: drag `/Applications/Koe.app` to the Trash.
3. Delete its data. In Finder, Go → Go to Folder… (⇧⌘G), paste each path and move it to the Trash:
   - `~/Library/Application Support/com.tsarionov.koe` — settings, the speech models (about 650 MB, more with
     Vocabulary), recordings waiting to be transcribed;
   - `~/Library/Caches/com.tsarionov.koe` — the models prepared for your Mac, update downloads;
   - `~/Library/Logs/com.tsarionov.koe` — logs;
   - `~/Library/HTTPStorages/com.tsarionov.koe` — the download cache;
   - `~/Library/Preferences/com.tsarionov.koe.plist` — the panel choices.
4. Optional: forget the permissions you gave it. In Terminal:

   ```bash
   tccutil reset All com.tsarionov.koe
   ```

5. Your transcripts and recordings in `~/Documents/Koe` (or the folders you picked) stay. Delete them yourself if
   you don't need them.

## Build it yourself

How to build Koe from source, how the code is put together and how to test it: [docs/BUILDING.md](docs/BUILDING.md).

## License and credits

Koe is © 2026 Eduard Tsarionov, under the [MIT License](LICENSE).

Speech recognition is Parakeet TDT 0.6B v3 by **NVIDIA**, fine-tuned by **moondream** as Parakeet Ultra
(CC BY 4.0). Speech detection is Silero VAD (MIT). Telling voices apart uses pyannote's Community-1 models with
WeSpeaker and BUT Speech@FIT (CC BY 4.0). All of them run through FluidAudio by Fluid Inference (Apache 2.0);
updates come with Sparkle (MIT). Details and full license texts: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md),
also in About Koe.
