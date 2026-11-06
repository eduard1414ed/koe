// The Koe app's entry point.
//   --dump               print what the panel would show right now, every tab, and quit (for testing);
//                        with --click "Tab/Row" (can repeat; "Record" — the Record button) — click those first, as a
//                        person would
//   --panel-png DIR      draw each tab of the panel into DIR/panel-N.png and quit
//   --record-test SEC    record that many seconds without the menu bar icon, transcribe it and quit
//                        (for testing; with --no-transcribe — no transcription; transcription is the same as the
//                        menu's, it waits if the app is transcribing something). Tracks and settings are the
//                        saved ones, unless overridden:
//                        --mic off|default|UID|NAME[,…] — no microphone track, or these microphones (each one
//                        its own track; several, or an aggregate device — through Koe's aggregate device);
//                        --system off|all|BUNDLE_ID[,BUNDLE_ID…] — no system track, all system audio, or only
//                        these apps (--source is the same thing);
//                        --quality compact|high|lossless; --channels mix|stereo|chN|each (every microphone);
//                        --name TRACK=NAME (can repeat) — a track's name in the transcript, --skip TRACK[,…] — don't
//                        transcribe these tracks (TRACK: mic, mic-2…);
//                        --restart-at SEC — restart capture of every track at that moment, as if the device changed;
//                        --swap-tap-at SEC — swap the system audio tap inside Koe's aggregate device at that moment;
//                        --volume PERCENT — every track's volume instead of the saved ones (100 — the sound as is);
//                        --volume-at SEC=PERCENT — change every track's volume at that moment, as the panel's slider;
//                        --regular — pretend to be a regular app (for testing --watch-calls)
//   --mics               print input devices (UID, channels, sample rate; "other device" — not a real microphone)
//   --wav-test DIR       write test WAV files with the Lossless writer (plain, RF64, cut off and repaired)
//                        and route-*.wav: a 3-channel source through each Input channels choice
//   --watch-calls SEC    watch the microphone and print which app Koe would offer to record (no notifications)
//   --processes          print audio processes and their apps
//   --settings-png PATH [0…3] [SCROLL]  draw the Settings window (General, Transcription, Transcripts, Help) into an
//                        image and quit; SCROLL 0…1 — how far down the tab is scrolled
//   --intro-png DIR [live]  draw moments of the setup window's intro into DIR/intro-T.png and quit; with live —
//                    play it in a window, draw it at 1 s and 3 s and print when it ends
//   --setup-png DIR [download]  draw every step of the setup window into DIR/setup-N.png and quit; with download —
//                        start downloading the missing models first (to see the models step while it downloads or fails)
//   --permissions        print the state of the microphone, system audio and notifications permissions (as macOS
//                        sees the process that runs this: start it with `open` to see the app's own)
//   --check-system-audio the setup window's system audio check: a short capture with a sound played in the middle
//   --models             print the speech models: size, downloaded or not, where
//   --delete-model NAME  delete a model (recognizer, detector, voices, vocabulary), as Delete in Settings
//   --update-test FEED_URL [--expect-rejected]   release only: install an update from that appcast with no windows, as
//                        if every Sparkle button were clicked, and relaunch; --expect-rejected — the update must be refused
//
// Transcription, for testing (models are downloaded the first time, as from the menu):
//   --transcribe DIR [--out FOLDER] [--force]   transcribe a recording folder (with session.json) into FOLDER
//                        (default: as chosen in the app); the registry and the inbox aren't touched
//   --refresh-names DIR…  update the speaker names in these transcript folders (as after a change in Settings)
//   --set-speakers DIR JSON   names from the Names window for one transcript: {"Speaker 1": "Anna", …}, or
//                        {"speakers": {"Speaker 1": "Anna"}, "tracks": {"mic-2": "Bob"}} (microphones renamed for it)
//   with the three above: --me NAME, --other NAME, --vocabulary "WORD\nWORD", --voices-threshold X — instead of
//                        what's in Settings
//   --decode FILE OUT    a track as transcription reads it: 16 kHz mono float32 into OUT
//   --vad WAV            the speech detector on a file: speech regions and pieces as JSON
//   --voices WAV OUT.json [--thresholds 0.5,0.6,…] [--sortformer MODELS_DIR]   tell voices apart in a file (as on the
//                        system track): FluidAudio's turns and the voices after the 20 s rule, at each threshold; with
//                        --sortformer — also Sortformer's turns, its models in MODELS_DIR (to compare the two)
//   --pieces-test WAV PIECES.json OUT.json   recognize the given pieces ({"chunks": [[start, end], …]}) of a file,
//                        phrases as JSON (for comparing engines)
//   --download-models    download the speech models (as the setup window does) and load them, printing progress
//   --run-queue SEC [--pause-at S] [--resume-at S] [--again KEY]   run the transcription queue without the menu bar
//                        icon for SEC seconds, printing what the menu would show; pause/resume at those moments;
//                        --again — as Try Again in the menu for that recording (local:2026-10-29_1501)
//   --verbose            with the above: the transcription log on the screen too
//
// Command line output is for development and stays in English, without String(localized:).
import AppKit
import AVFoundation
import CoreAudio
import FluidAudio
import SwiftUI

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = App()
    let args = CommandLine.arguments
    // for checking that the setup window stays dark: the whole app as if the Mac were in light mode
    if ProcessInfo.processInfo.environment["KOE_LIGHT_TEST"] != nil { app.appearance = NSAppearance(named: .aqua) }
    if args.contains("--dump") {
        let panel = delegate.panel
        delegate.settings.loadFields()
        panel.reload()
        // "Microphone/AirPods": a row's title, or the start of it, in that tab ("Record" — the Record button)
        for (i, a) in args.enumerated() where a == "--click" && i + 1 < args.count {
            guard panel.click(args[i + 1]) else {
                print("nothing to click: \(args[i + 1])")
                exit(1)
            }
            panel.reload()
        }
        print(panel.dump())
        exit(0)
    }
    if let i = args.firstIndex(of: "--panel-png"), i + 1 < args.count {
        app.setActivationPolicy(.accessory)
        delegate.settings.readOnly = true
        delegate.settings.loadFields()
        let panel = delegate.panel
        panel.reload()
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let saved = panel.tab
        let host = NSHostingView(rootView: PanelView(model: panel, settings: delegate.settings, opaque: true))
        let w = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = host
        w.orderFrontRegardless()
        @MainActor func shoot(_ tabs: ArraySlice<PanelModel.Tab>) {
            guard let t = tabs.first else { panel.tab = saved; exit(0) }
            panel.tab = t
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated {
                    w.setContentSize(host.fittingSize)
                    host.layoutSubtreeIfNeeded()
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("panel-\(t.rawValue).png"))
                    }
                    shoot(tabs.dropFirst())
                }
            }
        }
        shoot(ArraySlice(PanelModel.Tab.allCases))
        app.run()
    }
    if let i = args.firstIndex(of: "--settings-png"), i + 1 < args.count {
        app.setActivationPolicy(.accessory)
        delegate.settings.readOnly = true
        delegate.settings.load()
        delegate.settings.suggest = delegate.watcher.enabled
        delegate.settings.ignored = delegate.watcher.ignored
        delegate.settings.tab = i + 2 < args.count ? Int(args[i + 2]) ?? 0 : 0
        let w = NSWindow(contentViewController: NSHostingController(
            rootView: SettingsView(model: delegate.settings, watcher: delegate.watcher)))
        w.styleMask = [.titled, .closable]
        w.title = Identity.appName
        w.orderFrontRegardless()
        w.makeFirstResponder(nil)
        if i + 3 < args.count, let f = Double(args[i + 3]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                func scroll(_ v: NSView) -> NSScrollView? { (v as? NSScrollView) ?? v.subviews.lazy.compactMap(scroll).first }
                if let sv = scroll(w.contentView!), let doc = sv.documentView {
                    let room = max(0, doc.frame.height - sv.contentView.bounds.height)
                    sv.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? room * f : room * (1 - f)))
                    sv.reflectScrolledClipView(sv.contentView)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let v = w.contentView!
            if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
            }
            exit(0)
        }
        app.run()
    }
    if let i = args.firstIndex(of: "--setup-png"), i + 1 < args.count {
        app.setActivationPolicy(.accessory)
        delegate.settings.readOnly = true
        let model = SetupModel(settings: delegate.settings)
        model.readOnly = true
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let w = NSWindow(contentViewController: NSHostingController(rootView: SetupView(model: model)))
        w.appearance = SetupView.appearance
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.orderFrontRegardless()
        model.opened(at: .welcome)
        if i + 2 < args.count && args[i + 2] == "download" {
            Network.start()
            ModelStore.shared.download(SpeechModel.required)
        }
        @MainActor func shoot(_ step: Int) {
            guard let s = SetupModel.Step(rawValue: step) else { exit(0) }
            model.step = s
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                MainActor.assumeIsolated {
                    let v = w.contentView!
                    if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("setup-\(step).png"))
                    }
                    shoot(step + 1)
                }
            }
        }
        shoot(0)
        app.run()
    }
    if let i = args.firstIndex(of: "--intro-png"), i + 1 < args.count {
        app.setActivationPolicy(.accessory)
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if args.count > i + 2 && args[i + 2] == "live" {
            // the real thing in a window: pictures at 1 s and 3 s, and the moment it ends by itself
            let start = Date()
            let w = NSWindow(contentViewController: NSHostingController(rootView: IntroView {
                print(String(format: "finished after %.1f s", Date().timeIntervalSince(start)))
                exit(0)
            }.frame(width: 660, height: 540).background(Color.paper)))
            w.appearance = SetupView.appearance
            w.orderFrontRegardless()
            for t in [1.0, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                    let v = w.contentView!
                    if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("live-\(Int(t)).png"))
                    }
                }
            }
            app.run()
        }
        for t in [0.3, 1.0, 1.9, 2.3, 2.8, 3.5] {
            let v = NSHostingView(rootView: IntroView(at: t).frame(width: 660, height: 540).background(Color.paper))
            v.frame = NSRect(x: 0, y: 0, width: 660, height: 540)
            v.appearance = SetupView.appearance
            v.layoutSubtreeIfNeeded()
            if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(String(format: "intro-%.1f.png", t)))
            }
        }
        exit(0)
    }
    #if Updates
    if let i = args.firstIndex(of: "--update-test"), i + 1 < args.count {
        setvbuf(stdout, nil, _IOLBF, 0)
        app.setActivationPolicy(.accessory)
        let test = UpdateTest(feed: args[i + 1], expectRejected: args.contains("--expect-rejected"))
        DispatchQueue.main.async { test.run() }
        app.run()
    }
    #endif
    if args.contains("--permissions") {
        print("microphone: \(Permissions.microphone)")
        print("system audio: \(Permissions.systemAudio)")
        Permissions.refreshNotifications { n in
            print("notifications: \(n)")
            exit(0)
        }
        app.run()
    }
    if args.contains("--check-system-audio") {
        app.setActivationPolicy(.accessory)
        print("system audio before: \(Permissions.systemAudio)")
        SystemAudioCheck.run { heard in
            print(heard ? "heard the test sound" : "silence")
            print("system audio after: \(Permissions.systemAudio)")
            exit(heard ? 0 : 1)
        }
        app.run()
    }
    if args.contains("--models") {
        for m in SpeechModel.allCases {
            print("\(m.rawValue)\t\(m.isDownloaded ? "downloaded" : "missing")\t\(m.size) bytes (\(humanSize(Double(m.size))))"
                  + "\ton disk \(m.sizeOnDisk)\t\(m.folder.path)")
        }
        print("free: \(freeDiskSpace().map { humanSize(Double($0)) } ?? "?")")
        exit(0)
    }
    if let i = args.firstIndex(of: "--delete-model"), i + 1 < args.count {
        guard let m = SpeechModel(rawValue: args[i + 1]) else { print("models: recognizer, detector, voices, vocabulary"); exit(1) }
        ModelStore.shared.delete(m)
        print("deleted \(m.rawValue): \(m.isDownloaded ? "still there?" : "gone")")
        exit(0)
    }
    if args.contains("--mics") {
        let def = InputDevice.systemDefault?.uid
        for d in InputDevice.all() {
            print("\(d.uid)\t\(d.name)\t\(d.channels) ch" + (d.streams.count > 1 ? " (streams \(d.streams.map(String.init).joined(separator: "+")))" : "")
                  + "\t\(Int(d.sampleRate)) Hz" + (d.isAggregate ? "\taggregate: \(d.parts.joined(separator: ", "))" : "")
                  + (d.uid == def ? "\tdefault" : "") + (d.isMicrophone ? "" : "\tother device"))
        }
        exit(0)
    }
    if let i = args.firstIndex(of: "--wav-test"), i + 1 < args.count {
        exit(wavTest(URL(fileURLWithPath: args[i + 1])) ? 0 : 1)
    }
    if args.contains("--processes") {
        for p in audioProcesses() {
            let app = ownerApp(p)
            print("\(p.pid)\t\(p.bundleID.isEmpty ? "—" : p.bundleID)\t→ \(app?.localizedName ?? "service")"
                  + (p.output ? "\tplaying" : "") + (p.input ? "\tmic" : ""))
        }
        exit(0)
    }
    if let i = args.firstIndex(of: "--watch-calls"), i + 1 < args.count, let secs = Double(args[i + 1]) {
        setvbuf(stdout, nil, _IOLBF, 0)
        let watcher = CallWatcher()
        watcher.onSuggest = { bundle, name in print("would offer to record: \(name) (\(bundle))") }
        watcher.start(notifications: false)
        print("watching for \(Int(secs)) s")
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { exit(0) }
        withExtendedLifetime(watcher) { app.run() }
    }
    if let i = args.firstIndex(of: "--record-test"), i + 1 < args.count, let secs = Double(args[i + 1]) {
        setvbuf(stdout, nil, _IOLBF, 0)
        app.setActivationPolicy(args.contains("--regular") ? .regular : .accessory)
        let restartAt = args.firstIndex(of: "--restart-at").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        // the tracks: the saved choice, or what the command line says
        let micOn = value("--mic").map { $0 != "off" } ?? !MicChoice.off
        let swapAt = args.firstIndex(of: "--swap-tap-at").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }
        var system = SystemAudio.saved
        if let s = value("--system") ?? value("--source") {
            switch s {
            case "off": system = .off
            case "all": system = .all
            default:
                // the app's name, as the menu would show it
                system = .apps(s.split(separator: ",").map(String.init).map { b in
                    let name = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == b }?.localizedName
                        ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: b).map {
                            FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
                        }
                    return PickedApp(bundleID: b, name: name ?? b)
                })
            }
        }
        guard micOn || system != .off else {
            print("nothing to record: the microphone and system audio are both off. Turn one on (--mic default, --system all)")
            exit(1)
        }
        let withAccess: (@escaping @MainActor (Bool) -> Void) -> Void = micOn ? { withMicAccess($0) } : { $0(true) }
        withAccess { ok in
            guard ok else { print("no microphone access"); exit(1) }
            do {
                var quality = RecordingQuality.saved
                if let q = value("--quality") {
                    guard let parsed = RecordingQuality(rawValue: q) else { print("--quality: compact, high or lossless"); exit(1) }
                    quality = parsed
                }
                var mics = MicChoice.active
                if let m = value("--mic") {
                    mics = m == "off" ? [] : m.split(separator: ",").map(String.init).map { key in
                        if key == "default" { return MicPick.systemDefault }
                        guard let d = InputDevice.find(key) else { print("no input device \"\(key)\" (see --mics)"); exit(1) }
                        return MicPick(uid: d.uid, name: d.name)
                    }
                }
                var names: [String: String] = [:]
                for (i, a) in args.enumerated() where a == "--name" && i + 1 < args.count {
                    let kv = args[i + 1].split(separator: "=", maxSplits: 1).map(String.init)
                    if kv.count == 2 { names[kv[0]] = kv[1] }
                }
                let skip = Set((value("--skip") ?? "").split(separator: ",").map(String.init))
                var channels: InputChannels?
                if let c = value("--channels") {
                    guard let parsed = InputChannels(raw: c) else { print("--channels: mix, stereo, chN or each"); exit(1) }
                    channels = parsed
                }
                let volume = value("--volume").flatMap(Double.init).map { $0 / 100 }
                let rec = try CallRecording(mics: mics, system: system, quality: quality, channels: channels,
                                            names: names, skip: skip, volume: volume)
                try rec.start()
                let micList = rec.micTracks.map { "\($0.id) ← \($0.label)" + ($0.transcribe ? "" : " (not transcribed)") }
                print("recording \(Int(secs)) s into \(rec.dir.path), quality \(quality.rawValue), "
                      + "mic: \(micList.isEmpty ? "off" : micList.joined(separator: "; ")), system audio: \(system.logName)")
                if let swapAt {
                    DispatchQueue.main.asyncAfter(deadline: .now() + swapAt) {
                        MainActor.assumeIsolated { rec.swapTapForTest() }
                    }
                }
                if let v = value("--volume-at") {
                    let kv = v.split(separator: "=").compactMap { Double($0) }
                    guard kv.count == 2 else { print("--volume-at: SEC=PERCENT"); exit(1) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + kv[0]) {
                        MainActor.assumeIsolated { rec.setAllVolumesForTest(kv[1] / 100) }
                    }
                }
                if let restartAt {
                    DispatchQueue.main.asyncAfter(deadline: .now() + restartAt) {
                        MainActor.assumeIsolated { rec.restartForTest() }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
                    let doc = MainActor.assumeIsolated { rec.stop(reason: "user") }
                    print("recorded: \(rec.dir.path)")
                    if let note = MainActor.assumeIsolated({ rec.micSwitchNote }) { print("\(note.title): \(note.text)") }
                    if let (title, text) = silenceWarning(doc, system: system, micRecorded: micOn) {
                        print("the menu would warn: \(title) — \(text)")
                    }
                    if args.contains("--no-transcribe") { exit(0) }
                    // the same transcription as the menu's; if the app is transcribing now, wait for it
                    print("transcribing…")
                    Task.detached {
                        let lock = TranscribeLock()
                        lock.lock()
                        do {
                            let out = try await TranscriptionWork().transcribe("local:\(rec.dir.lastPathComponent)", force: false,
                                                                               step: { print("model: \($0)") }, progress: { _ in },
                                                                               notify: { print("notification: \($0) — \($1)") })
                            print("transcription finished: \(out.path)")
                            exit(0)
                        } catch {
                            print("transcription failed: \(error.localizedDescription)")
                            exit(1)
                        }
                    }
                }
            } catch {
                print("error: \(error.localizedDescription)")
                exit(1)
            }
        }
        app.run()
    }
    if runTranscriptionTool(args) { app.run() }
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

/// The transcription keys from the list at the top. true — one of them is running (the caller starts the run loop).
@MainActor
func runTranscriptionTool(_ args: [String]) -> Bool {
    func value(_ flag: String, _ n: Int = 1) -> String? { args.firstIndex(of: flag).flatMap { $0 + n < args.count ? args[$0 + n] : nil } }
    setvbuf(stdout, nil, _IOLBF, 0)
    Network.start()
    func run(_ body: @escaping () async throws -> Void) -> Bool {
        Task.detached {
            do { try await body(); exit(0) } catch { print("error: \(error.localizedDescription)"); exit(1) }
        }
        return true
    }
    // Settings for this run only
    for (flag, key) in [("--me", "me"), ("--other", "other"), ("--vocabulary", "vocabulary")] {
        if let v = value(flag) { TranscriptSettings.overrides[key] = v.replacingOccurrences(of: "\\n", with: "\n") }
    }
    if let v = value("--voices-threshold").flatMap(Double.init) { TranscriptSettings.overrides["voice_threshold"] = v }
    let notify: (String, String) -> Void = { print("notification: \($0) — \($1)") }
    if let i = args.firstIndex(of: "--refresh-names") {
        var dirs: [URL] = []
        var k = i + 1
        while k < args.count {
            if ["--me", "--other", "--vocabulary"].contains(args[k]) { k += 2; continue }
            dirs.append(URL(fileURLWithPath: args[k]))
            k += 1
        }
        SpeakerNames.refreshAll(dirs, settings: .load(), notify: notify)
        exit(0)
    }
    if let dir = value("--set-speakers"), let json = value("--set-speakers", 2) {
        // {"Speaker 1": "Anna"}, or as in speakers.json: {"speakers": {…}, "tracks": {"mic-2": "Bob"}}
        let o = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        let names: SpeakerNames.Names
        if let flat = o as? [String: String] {
            names = .init(speakers: flat)
        } else if let o, o["speakers"] == nil || o["speakers"] is [String: String], o["tracks"] == nil || o["tracks"] is [String: String] {
            names = .init(speakers: o["speakers"] as? [String: String] ?? [:], tracks: o["tracks"] as? [String: String] ?? [:])
        } else {
            print("--set-speakers DIR '{\"Speaker 1\": \"Name\"}' or '{\"speakers\": {…}, \"tracks\": {\"mic-2\": \"Name\"}}'")
            exit(1)
        }
        // a folder outside the app's transcripts (a test copy) is updated too
        SpeakerNames.set(URL(fileURLWithPath: dir), names, settings: .load(), notify: notify, anyFolder: true)
        exit(0)
    }
    let step: @Sendable (ModelStep) -> Void = { s in
        switch s {
        case .downloading(let f): print("downloading speech model… " + (f.map { "\(Int($0 * 100)) %" } ?? ""))
        case .preparing: print("getting the speech model ready…")
        }
    }
    if args.contains("--download-models") {
        return run {
            let t0 = Date()
            Network.start()
            try await ModelStore.shared.ensure(SpeechModel.required, step: step)
            print(String(format: "downloaded in %.1f s", Date().timeIntervalSince(t0)))
            _ = try await TranscriptionWork().ready(step: step)
            print(String(format: "ready in %.1f s: %@", Date().timeIntervalSince(t0), SpeechModels.dir.path))
        }
    }
    if let dir = value("--transcribe") {
        return run {
            let out = value("--out").map { URL(fileURLWithPath: $0) }
            let t0 = Date()
            let t = try await TranscriptionWork().ready(step: step)
            let loaded = Date()
            var last = -1
            let folder = try await t.process(URL(fileURLWithPath: dir), force: args.contains("--force"), outRoot: out,
                                             modelStep: step, progress: { f in
                let p = Int(f * 100) / 10 * 10
                if p != last { last = p; print("transcribing… \(p) %") }
            }, notify: notify)
            print(String(format: "done: %@ (models %.1f s, transcription %.1f s)", folder.path,
                         loaded.timeIntervalSince(t0), Date().timeIntervalSince(loaded)))
        }
    }
    if let file = value("--decode"), let out = value("--decode", 2) {
        return run {
            let audio = try TrackAudio.read(URL(fileURLWithPath: file))
            try audio.withUnsafeBufferPointer { try Data(buffer: $0).write(to: URL(fileURLWithPath: out)) }
            print("\(audio.count) samples at 16 kHz (\(String(format: "%.3f", Double(audio.count) / Double(asrRate))) s)")
        }
    }
    if let wav = value("--vad") {
        return run {
            let audio = try TrackAudio.read(URL(fileURLWithPath: wav))
            let t0 = Date()
            let detector = try await SpeechDetector()
            let probs = try await detector.probabilities(audio) { _ in }
            let regions = SpeechDetector.regions(probs, samples: audio.count)
            let out: [String: Any] = [
                "audio_s": round3(Double(audio.count) / Double(asrRate)), "vad_s": round3(Date().timeIntervalSince(t0)),
                "regions": regions.map { [round3($0.0), round3($0.1)] },
                "chunks": SpeechDetector.chunks(regions).map { [round3($0.0), round3($0.1)] },
            ]
            print(String(decoding: try jsonData(out), as: UTF8.self))
        }
    }
    if let wav = value("--voices"), let outPath = value("--voices", 2) {
        return run {
            let audio = try TrackAudio.read(URL(fileURLWithPath: wav))
            let thresholds = (value("--thresholds") ?? "\(VoiceTuning.defaultThreshold)").split(separator: ",").compactMap { Double($0) }
            var out: [String: Any] = ["audio_s": round3(Double(audio.count) / Double(asrRate))]
            var t0 = Date()
            let splitter = try await VoiceSplitter(step: step)
            print(String(format: "models %.1f s", Date().timeIntervalSince(t0)))
            t0 = Date()
            let results = try await splitter.sweep(audio, thresholds: thresholds)
            out["elapsed_s"] = round1(Date().timeIntervalSince(t0))
            out["results"] = zip(thresholds, results).map { th, r -> [String: Any] in
                let (found, raw, took) = r
                let name = String(format: "%.2f", th)
                print("\(name): \(found.count) voices (\(found.clusters) before the 20 s rule), clustering \(String(format: "%.1f", took)) s")
                return ["threshold": name, "voices": found.count, "clusters": found.clusters, "merged": found.merged,
                        "speech": Dictionary(uniqueKeysWithValues: found.speech.map { ("\($0.key)", round1($0.value)) }),
                        "raw": raw.map { [$0.0, round3($0.1), round3($0.2)] as [Any] },
                        "turns": found.turns.map { [round3($0.start), round3($0.end), $0.speaker] as [Any] }]
            }
            print(String(format: "all thresholds: %.1f s", Date().timeIntervalSince(t0)))
            if let dir = value("--sortformer") {
                // for the comparison only: Sortformer (up to 4 voices), its models in DIR
                let t1 = Date()
                let config = SortformerConfig.default
                let models = try await SortformerModels.loadFromHuggingFace(config: config, cacheDirectory: URL(fileURLWithPath: dir))
                let d = SortformerDiarizer(config: config)
                d.initialize(models: models)
                let t2 = Date()
                let timeline = try d.processComplete(audio, sourceSampleRate: Double(asrRate))
                var segs: [[Any]] = []
                for (i, sp) in timeline.speakers {
                    for s in sp.finalizedSegments { segs.append(["S\(i)", round3(Double(s.startTime)), round3(Double(s.endTime))]) }
                }
                out["sortformer"] = ["raw": segs, "elapsed_s": round1(Date().timeIntervalSince(t2)), "load_s": round1(t2.timeIntervalSince(t1))]
                print(String(format: "sortformer: %d voices, %.1f s", timeline.speakers.filter { !$0.value.finalizedSegments.isEmpty }.count,
                             Date().timeIntervalSince(t2)))
            }
            try jsonData(out).write(to: URL(fileURLWithPath: outPath))
        }
    }
    if let wav = value("--pieces-test"), let piecesPath = value("--pieces-test", 2), let outPath = value("--pieces-test", 3) {
        return run {
            let audio = try TrackAudio.read(URL(fileURLWithPath: wav))
            let pieces = (readJSON(URL(fileURLWithPath: piecesPath))["chunks"] as? [[Double]]) ?? []
            let t = try await TranscriptionWork().ready(step: step)
            let t0 = Date()
            var segments: [[String: Any]] = []
            var joinedSame = 0
            for p in pieces {
                let a = max(0, Int(p[0] * Double(asrRate))), b = min(audio.count, Int(p[1] * Double(asrRate)))
                guard b > a else { continue }
                let heard = try await t.engine.transcribe(Array(audio[a..<b]))
                let phrases = splitPhrases(heard, offset: p[0], end: p[1])
                // the phrases put back together are the recognizer's text (nothing lost or added by the splitting)
                if phrases.map(\.text).joined(separator: " ") == heard.text.split(whereSeparator: \.isWhitespace).joined(separator: " ") { joinedSame += 1 }
                segments += phrases.map { var j = $0.json; j["piece_text"] = heard.text; return j }
            }
            let elapsed = Date().timeIntervalSince(t0)
            try jsonData(["elapsed_s": round3(elapsed), "pieces": pieces.count, "pieces_text_same": joinedSame,
                          "segments": segments]).write(to: URL(fileURLWithPath: outPath))
            print("\(pieces.count) pieces, \(segments.count) phrases, text kept in \(joinedSame) pieces, \(String(format: "%.1f", elapsed)) s")
        }
    }
    if let secs = value("--run-queue").flatMap(Double.init) {
        let q = TranscriptionQueue.shared
        var last = ""
        q.onChange = {
            let line = queueStatusText(q).joined(separator: " | ")
            if line != last { last = line; print(line) }
        }
        q.notify = { title, text, folder in print("notification: \(title) — \(text)" + (folder.map { " [click opens \($0.path)]" } ?? "")) }
        ModelStore.shared.onChange = q.onChange
        ModelStore.shared.onDownloaded = { q.retryWaiting() }
        q.start()
        if let key = value("--again") { print("— again: \(key)"); q.reprocess(key) }
        if let at = value("--pause-at").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { MainActor.assumeIsolated { print("— pause"); q.pause() } }
        }
        if let at = value("--resume-at").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { MainActor.assumeIsolated { print("— resume"); q.resume() } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
            MainActor.assumeIsolated {
                print("— quit")
                q.stop()
                exit(0)
            }
        }
        return true
    }
    return false
}

/// --wav-test: the Lossless writer without a real recording. Writes a 1 kHz tone (2 s, 48 kHz, stereo) as
/// plain.wav; the same with the RF64 switch lowered to 100 KB (rf64.wav — checks the ds64 header without
/// writing 4 GB); and cut.wav — written without closing (as after kill -9) with the header two seconds
/// behind and half a frame at the end, then fixed by repair(). Check the files with ffprobe / afinfo.
func wavTest(_ dir: URL) -> Bool {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let rate = 48_000, seconds = 2
    let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 2)!
    func tone(_ w: WavWriter) throws {
        for s in 0..<seconds * 10 {
            let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(rate / 10))!
            b.frameLength = b.frameCapacity
            for i in 0..<Int(b.frameLength) {
                let v = Float(sin(2 * Double.pi * 1000 * Double(s * rate / 10 + i) / Double(rate)) * 0.5)
                b.floatChannelData![0][i] = v
                b.floatChannelData![1][i] = -v
            }
            try w.write(b)
        }
    }
    do {
        let plain = try WavWriter(url: dir.appendingPathComponent("plain.wav"), sampleRate: rate, channels: 2)
        try tone(plain)
        plain.close()
        let rf64 = try WavWriter(url: dir.appendingPathComponent("rf64.wav"), sampleRate: rate, channels: 2, rf64Above: 100_000)
        try tone(rf64)
        rf64.close()
        let cutURL = dir.appendingPathComponent("cut.wav")
        var cut: WavWriter? = try WavWriter(url: cutURL, sampleRate: rate, channels: 2)
        try tone(cut!)
        cut = nil   // no close(): the header still says what it said at the last update
        let h = try FileHandle(forWritingTo: cutURL)
        h.seekToEndOfFile()
        h.write(Data([1, 2, 3]))   // half a frame, as if the process died in the middle of a write
        try h.close()
        guard let fixed = WavWriter.repair(cutURL) else { print("repair failed"); return false }
        print("cut.wav repaired: \(fixed.frames) frames, \(fixed.sampleRate) Hz, \(fixed.channels) channels (expected \(rate * seconds))")
        routeTest(dir)
        print("wrote \(dir.path)/plain.wav, rf64.wav, cut.wav, route-*.wav")
        return fixed.frames == Int64(rate * seconds)
    } catch {
        print("error: \(error.localizedDescription)")
        return false
    }
}

/// The track writer with a made-up 3-channel device, 44.1 kHz: channel 1 — 440 Hz, channel 2 — 1000 Hz,
/// channel 3 — silence. route-<choice>.wav (Lossless, so 44.1 kHz stays) shows where each channel went.
func routeTest(_ dir: URL) {
    let rate = 44_100.0
    // more than two channels need a channel layout, like a sound card's format has
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: false,
                            channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3)!)
    let host = mach_absolute_time()
    for pick in [InputChannels.mix, .stereo, .channel(0), .channel(1), .channel(2)] {
        let sub = dir.appendingPathComponent("route-\(pick.raw)")
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let w = TrackWriter(name: "mic", dir: sub, sessionStartHost: host, quality: .lossless)
        w.deviceStarted(DeviceInfo(defaultDevice(kAudioHardwarePropertyDefaultInputDevice)), input: fmt, channels: pick)
        for k in 0..<10 {
            let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4410)!
            b.frameLength = 4410
            for i in 0..<4410 {
                let t = Double(k * 4410 + i) / rate
                b.floatChannelData![0][i] = Float(0.5 * sin(2 * .pi * 440 * t))
                b.floatChannelData![1][i] = Float(0.3 * sin(2 * .pi * 1000 * t))
                b.floatChannelData![2][i] = 0
            }
            w.append(b, hostTime: host + UInt64(k) * 1_000_000)
        }
        _ = w.summary(finish: true)
        try? FileManager.default.moveItem(at: sub.appendingPathComponent("mic.wav"), to: dir.appendingPathComponent("route-\(pick.raw).wav"))
        try? FileManager.default.removeItem(at: sub)
    }
}
