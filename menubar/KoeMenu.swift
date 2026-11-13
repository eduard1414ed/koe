// Koe — the menu bar icon: records calls and any other sound, and manages their transcription.
//
// App paths and names live in Identity.swift. The app:
//   - records the microphone and/or system audio into the inbox of its data folder — see Recorder.swift.
//     This needs the microphone and system audio recording permissions;
//   - transcribes recordings itself, one at a time, in a queue that survives quitting — see
//     TranscriptionQueue.swift (the pipeline: Transcriber.swift, the engine: Engine.swift);
//   - offers to record when some app takes the microphone (CallSources.swift) — needs notifications;
//   - shows the Settings window: General, Transcription, Transcripts, Help (SettingsWindow.swift);
//   - until setup is finished, opens the setup window at launch (Setup.swift); a permission that isn't given shows
//     as a card in the panel (permissionWarnings);
//   - the icon opens the panel (Panel.swift), a right click — a short menu (showShortMenu).
//
// Interface texts go through String(localized:) with the English text as the key: without a
// translation file the key itself is shown; a translation is one Localizable.strings per language.
import AppKit
import AVFoundation
import CoreAudio
import ServiceManagement
import SwiftUI
import UserNotifications

@discardableResult
func run(_ args: String...) -> (code: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

func readJSON(_ url: URL) -> [String: Any] {
    guard let d = try? Data(contentsOf: url),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return o
}

// ---------- formatting ----------

let iso = ISO8601DateFormatter()

/// A date in the user's format (language of the interface, region of the Mac): template "MMMdjjmm" → "Oct 28, 9:44 AM".
func formatDate(_ d: Date, _ template: String) -> String {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate(template)
    return f.string(from: d)
}

func humanTime(_ s: String?) -> String {
    guard let s, let d = iso.date(from: s) else { return "—" }
    let time = formatDate(d, "jjmm")
    return Calendar.current.isDateInToday(d) ? String(localized: "today at \(time)")
                                             : String(localized: "\(formatDate(d, "MMMd")) at \(time)")
}

/// "2026-10-28_0944" (a recording or meeting folder) → that date and time; nil if the name looks different.
func folderDate(_ name: String) -> Date? {
    let p = name.split(separator: "_")
    guard p.count >= 2, p[1].count == 4 else { return nil }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd_HHmm"
    return f.date(from: "\(p[0])_\(p[1])")
}

/// "2026-10-28_0944" → "Oct 28, 2026, 9:44 AM"; "2026-10-28_0944_2" → "… (2)"
func meetingTitle(_ folder: String) -> String {
    let name = (folder as NSString).lastPathComponent
    guard let d = folderDate(name) else { return name }
    let p = name.split(separator: "_")
    let suffix = p.count > 2 ? " (\(p[2]))" : ""
    return formatDate(d, "yMMMdjjmm") + suffix
}

/// recording "local:2026-10-28_1148" → "Oct 28, 11:48 AM"
func recordingTitle(_ key: String) -> String {
    let id = key.hasPrefix("local:") ? String(key.dropFirst(6)) : key
    return folderDate(id).map { formatDate($0, "MMMdjjmm") } ?? id
}

/// 754 s → "12:34", 4000 s → "1:06:40"
func clock(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}

/// Ask for microphone access if we haven't asked yet; the answer arrives on the main thread.
@MainActor
func withMicAccess(_ done: @escaping @MainActor (Bool) -> Void) {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: done(true)
    case .notDetermined:
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async { MainActor.assumeIsolated { done(ok) } }
        }
    default: done(false)
    }
}

func lastLogLine() -> String? {
    guard let h = try? FileHandle(forReadingFrom: Identity.pipelineLog) else { return nil }
    defer { try? h.close() }
    let size = (try? h.seekToEnd()) ?? 0
    try? h.seek(toOffset: size > 4096 ? size - 4096 : 0)
    let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
    guard let line = text.split(separator: "\n").last else { return nil }
    // "2026-10-28 10:34:43 INFO text" → "text"
    let bits = line.split(separator: " ", maxSplits: 3)
    return bits.count == 4 ? String(bits[3]) : String(line)
}

// ---------- the app ----------

@MainActor
final class App: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    lazy var panel = PanelModel(app: self)
    var panelTimers: [Timer] = []
    var timer: Timer?
    var recording: CallRecording? { didSet { panel.refresh() } }
    var stoppedBySleep: String?
    let watcher = CallWatcher()
    let settings = SettingsModel()
    let queue = TranscriptionQueue.shared
    var settingsWindow: NSWindow?
    var setupWindow: NSWindow?
    lazy var setup = SetupModel(settings: settings)
    // the menu bar ring: a 22 pt canvas (the asset pack uses 18, a bit small next to system icons;
    // there's still room for the animation), with the middle of the resting shape at the center of the image
    static let ringSize: CGFloat = 22
    let ringCenter = KoeRing.restCenter("menubar")
    lazy var restRing = KoeRing.restImage(preset: "menubar", size: App.ringSize, center: ringCenter)
    lazy var problemRing = KoeStates.markImage("problem", size: App.ringSize, center: ringCenter)
    let ring = KoeRing.Animator()
    var ringTimer: Timer?
    var ringLast = 0.0
    var linesTimer: Timer?
    var busySince: Double?

    func applicationDidFinishLaunching(_ n: Notification) {
        setUpPanel()
        CallRecording.recoverInterrupted()
        queue.onChange = { [unowned self] in self.queueChanged() }
        queue.notify = { [unowned self] title, text, folder in self.notify(title, text, folder: folder) }
        watcher.isRecording = { [unowned self] in self.recording != nil }
        watcher.onRecord = { [unowned self] in self.startRecording(forCall: true) }
        watcher.onOpenFolder = { NSWorkspace.shared.open(URL(fileURLWithPath: $0)) }
        watcher.start()
        // permissions are asked in the setup window; afterwards a missing one is a card in the panel
        Permissions.refreshNotifications()
        Network.start()
        let models = ModelStore.shared
        models.onChange = { [unowned self] in self.queueChanged() }
        models.onDownloaded = { [unowned self] in self.queue.retryWaiting() }
        // the app was quit in the middle of a transcription or recording — the queue continues now
        queue.start()
        // a model download the person started and didn't see through (the app was quit) goes on
        models.resumeIfWanted()
        if !SetupModel.done { showSetup() }
        settings.onSaved = { [unowned self] in self.queue.refreshNames() }
        settings.onSpeakers = { [unowned self] dir, names in
            self.queue.setSpeakers(dir, names)
            if self.queue.paused {
                self.alert(String(localized: "Transcription is paused"), String(localized: "Got it. The names will change as soon as you resume transcription."))
            }
        }
        // release only: Sparkle checks for updates on its own schedule (Settings → Other)
        Updates.shared.start()
        installEditMenu()
        watchInputDevices()
        StallWatch.start()
        refreshIcon()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated {
                self.refreshIcon()
                Permissions.refreshNotifications()   // may be turned on or off in System Settings
            }
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.macWillSleep() }
        }
        ws.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.finishRecording(reason: "quit") }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.macDidWake() }
        }
    }

    // quitting for any reason (menu, logging out): the recording is closed first,
    // transcription stops and continues on the next launch
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        finishRecording(reason: "quit")
        queue.stop()
        return .terminateNow
    }

    var registry: [String: [String: Any]] { Registry.recordings }

    /// The queue changed: the icon, and the panel if it's open right now.
    func queueChanged() {
        refreshIcon()
        if popover.isShown { panel.refresh() }
    }

    func refreshIcon() {
        if let rec = recording {
            // while recording, the ring (ringFrame) draws the image; here we only set the tooltip with the clock;
            // recording beats transcription — the lines wait
            item.button?.toolTip = String(localized: "\(Identity.appName): recording · \(clock(Date().timeIntervalSince(rec.startedAt)))")
            stopLines()
            return
        }
        let phase = queue.phase
        // the lines are for the speech model and transcription; updating names is quick, it gets no lines
        let busy = (queue.busy && phase != .names && phase != .paused) || ModelStore.shared.busy
        let failed = registry.values.contains { $0["status"] as? String == "failed" }
        let img: NSImage
        let tip: String
        // a paused transcription changes only the tooltip: a pause mark on the ring would look like recording is paused too
        switch phase {
        case _ where busy:
            img = restRing; tip = String(localized: "\(Identity.appName): transcribing")   // the lines draw the image (linesFrame)
        case _ where failed:
            img = problemRing; tip = String(localized: "\(Identity.appName): something went wrong")
        case .paused:
            img = restRing; tip = String(localized: "\(Identity.appName): transcription paused")
        default:
            img = restRing; tip = Identity.appName
        }
        // t for the lines is seconds since transcription started (busy only happens while the queue works, never when paused)
        if !busy { busySince = nil } else if busySince == nil { busySince = ProcessInfo.processInfo.systemUptime }
        item.button?.toolTip = tip
        // the water is still draining after a recording — don't interrupt the frames, ringFrame restores the icon itself
        guard ringTimer == nil else { stopLines(); return }
        if busy { startLines(); return }
        stopLines()
        img.isTemplate = true
        img.accessibilityDescription = tip
        item.button?.image = img
    }

    // ---------- the ring while recording ----------

    /// Recording started: water flows around the ring, 30 frames per second.
    func startRing() {
        stopLines()   // recording beats transcription: the two frame timers never run together
        ring.setRecording(true)
        guard ringTimer == nil else { return }   // the water was still draining after the last recording
        ringLast = ProcessInfo.processInfo.systemUptime
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated { self.ringFrame() }
        }
        RunLoop.main.add(t, forMode: .common)   // frames keep going while the panel is open
        ringTimer = t
        ringFrame()
    }

    /// One frame. After recording stops, the water drains into the resting shape and then the timer turns off.
    func ringFrame() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = now - ringLast
        ringLast = now
        ring.setLevel(recording?.level ?? 0)
        ring.tick(dt)
        guard ring.isActive() else {
            ringTimer?.invalidate()
            ringTimer = nil
            refreshIcon()
            return
        }
        let img = ring.image(preset: "menubar", size: App.ringSize, center: ringCenter)
        img.accessibilityDescription = item.button?.toolTip
        item.button?.image = img
    }

    // ---------- the lines while transcribing ----------

    /// Transcription is running: three lines float by, 30 frames per second. refreshIcon turns them on and off.
    func startLines() {
        guard linesTimer == nil, recording == nil, ringTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated { self.linesFrame() }
        }
        RunLoop.main.add(t, forMode: .common)   // frames keep going while the panel is open
        linesTimer = t
        linesFrame()
    }

    func stopLines() {
        linesTimer?.invalidate()
        linesTimer = nil
    }

    func linesFrame() {
        let now = ProcessInfo.processInfo.systemUptime
        let img = KoeStates.transcribingImage(t: now - (busySince ?? now), size: App.ringSize)
        img.accessibilityDescription = item.button?.toolTip
        item.button?.image = img
    }

    // ---------- the panel ----------

    /// Left click: the panel (a popover); right click: the short menu. The panel always opens dark.
    func setUpPanel() {
        item.button?.target = self
        item.button?.action = #selector(iconClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        let host = NSHostingController(rootView: PanelView(model: panel, settings: settings))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
    }

    @objc func iconClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            closePanel()
            showShortMenu()
        } else if popover.isShown {
            closePanel()
        } else {
            openPanel()
        }
    }

    func openPanel() {
        guard let button = item.button else { return }
        // the Names fields in the panel are the Settings window's: read them unless the window has them open
        if settingsWindow?.isVisible != true { settings.loadFields() }
        panel.reload()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        // the clock on the Stop button and the queue once a second; the level meters 15 times a second while recording
        let t = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { self.panel.refresh() } }
        let l = Timer(timeInterval: 1.0 / 15, repeats: true) { _ in MainActor.assumeIsolated { self.panel.levels.update(self.recording) } }
        for x in [t, l] { RunLoop.main.add(x, forMode: .common) }
        panelTimers = [t, l]
    }

    func closePanel() {
        if popover.isShown { popover.performClose(nil) }
    }

    func popoverDidClose(_ notification: Notification) {
        panelTimers.forEach { $0.invalidate() }
        panelTimers = []
        panel.levels.update(nil)
    }

    /// The right click: About, updates, Quit.
    func showShortMenu() {
        let m = NSMenu()
        func add(_ title: String, _ action: Selector, key: String = "") {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
            it.target = self
            m.addItem(it)
        }
        add(String(localized: "About \(Identity.appName)"), #selector(about))
        if Updates.supported {
            if let v = Updates.shared.pending {
                add(String(localized: "Update to \(Identity.appName) \(v)…"), #selector(checkForUpdates))
            } else {
                add(String(localized: "Check for Updates…"), #selector(checkForUpdates))
            }
        }
        m.addItem(.separator())
        add(String(localized: "Settings…"), #selector(openSettings), key: ",")
        add(String(localized: "Quit \(Identity.appName)"), #selector(quit), key: "q")
        item.menu = m
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc func pickCallFolder() {
        chooseFolder(String(localized: "Where should this recording's transcript go?"), start: CallFolder.current ?? CallFolder.defaultFolder) { p in
            CallFolder.current = p == CallFolder.defaultFolder ? nil : p
        }
    }

    // ---------- permissions ----------

    /// The permissions that aren't given, with the line for the panel. The microphone and system audio only matter while
    /// they're recorded (not off in the panel); notifications always (Transcript ready, the call suggestion).
    func permissionWarnings() -> [(Permission, PermissionState, String)] {
        var out: [(Permission, PermissionState, String)] = []
        let mic = Permissions.microphone
        if !MicChoice.off && mic != .allowed {
            out.append((.microphone, mic, mic == .denied ? String(localized: "Microphone isn't allowed") : String(localized: "Microphone: not allowed yet")))
        }
        let system = Permissions.systemAudio
        if SystemAudio.saved != .off && (system == .denied || system == .notAsked) {
            out.append((.systemAudio, system, system == .denied ? String(localized: "System audio isn't allowed") : String(localized: "System audio: not allowed yet")))
        }
        let notes = Permissions.notifications
        if notes == .denied || notes == .notAsked {
            out.append((.notifications, notes, String(localized: "Notifications are off")))
        }
        return out
    }

    /// Never asked — the setup window at that step (it explains and asks); turned off — its place in System Settings.
    func fixPermission(_ p: Permission, denied: Bool) {
        if denied { p.openSettings(); return }
        switch p {
        case .microphone: showSetup(at: .microphone)
        case .systemAudio: showSetup(at: .systemAudio)
        case .notifications: showSetup(at: .notifications)
        }
    }

    // ---------- the setup window ----------

    func showSetup(at step: SetupModel.Step = .welcome) {
        if setupWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SetupView(model: setup)))
            w.appearance = SetupView.appearance
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.title = String(localized: "Set Up \(Identity.appName)")
            w.isReleasedWhenClosed = false
            w.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [unowned self] _ in
                MainActor.assumeIsolated { self.setup.closed() }
            }
            setupWindow = w
            setup.window = w
        }
        setup.opened(at: step)
        recLog("setup window opened at step \(step)")
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in self?.setupWindow?.makeFirstResponder(nil) }
    }

    // ---------- the Settings window ----------

    @objc func openSettings() { showSettings(tab: 0) }

    func showSettings(tab: Int) {
        settings.load()
        settings.suggest = watcher.enabled
        settings.ignored = watcher.ignored
        settings.atLogin = SMAppService.mainApp.status == .enabled
        settings.actions = SettingsActions(
            pause: { [unowned self] in self.pause() },
            resume: { [unowned self] in self.resume() },
            reprocess: { [unowned self] key in self.reprocess(key) },
            openLog: { [unowned self] in self.openLog() },
            setUpAgain: { [unowned self] in self.showSetup() })
        settings.tab = tab
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: settings, watcher: watcher)))
            w.title = Identity.appName
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
            settings.window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        // without this the cursor lands in the "Your name" field with the text selected — any key would replace it
        DispatchQueue.main.async { [weak self] in self?.settingsWindow?.makeFirstResponder(nil) }
    }

    /// A microphone was connected or disconnected, or the default changed — the Settings window shows it right away.
    func watchInputDevices() {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var addr = propertyAddress(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, self.settingsWindow?.isVisible == true else { return }
                    self.settings.loadDevices()
                }
            }
        }
    }

    /// An app without a Dock icon has no menu of its own, and without an Edit menu ⌘C/⌘V/⌘Z don't work in text fields.
    func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: String(localized: "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: String(localized: "Edit"))
        edit.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    @objc func startRecording() { startRecording(forCall: false) }

    /// forCall — Record in the "Looks like a call started" notification: a call always gets the microphone
    /// (if it's off — the system default, for this recording only) and system audio (if it's off — all of it).
    /// The choice in the menu stays as it was.
    func startRecording(forCall: Bool) {
        guard recording == nil else { return }
        var mics = MicChoice.active
        var system = SystemAudio.saved
        if forCall {
            if mics.isEmpty { mics = [.systemDefault] }
            if system == .off { system = .all }
        }
        let micOn = !mics.isEmpty
        guard micOn || system != .off else { return }   // the Record item is inactive then
        let begin = {
            do {
                let rec = try CallRecording(mics: mics, system: system)
                try rec.start()
                self.recording = rec
                self.startRing()
            } catch {
                self.alert(String(localized: "Couldn't start recording"), error.localizedDescription)
            }
            self.refreshIcon()
        }
        // without the microphone there's nothing to ask permission for
        guard micOn else { begin(); return }
        withMicAccess { ok in
            guard ok else {
                if self.confirm(String(localized: "\(Identity.appName) can't use the microphone"),
                                String(localized: "Turn it on in System Settings → Privacy & Security → Microphone → \(Identity.appName)."),
                                ok: String(localized: "Open System Settings")),
                   let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
                return
            }
            begin()
        }
    }

    @objc func stopRecording() { finishRecording(reason: "user") }

    /// Stop the recording (if there is one), write session.json and start transcription.
    func finishRecording(reason: String) {
        guard let rec = recording else { return }
        recording = nil
        ring.setRecording(false)   // the water drains into the resting shape, then ringFrame restores the usual icon
        let doc = rec.stop(reason: reason)
        queue.add(recording: rec.dir)
        refreshIcon()
        if let note = rec.micSwitchNote { notify(note.title, note.text) }
        // sound on the system track — the permission works, whatever the privacy database says
        if let peak = ((doc["tracks"] as? [String: [String: Any]])?["system"]?["peak_db"] as? NSNumber)?.doubleValue, peak > -199 {
            Permissions.systemAudioHeard = true
        }
        if reason == "user", let (title, text) = silenceWarning(doc, system: rec.systemAudio, micRecorded: rec.hasMic) {
            alert(title, text)
        }
    }

    func macWillSleep() {
        guard let rec = recording else { return }
        let time = formatDate(Date(), "jjmm")
        stoppedBySleep = String(localized: "The recording from \(meetingTitle(rec.dir.lastPathComponent)) stopped at \(time) when your Mac went to sleep. Everything up to that point is saved and will be transcribed.")
        finishRecording(reason: "sleep")
    }

    func macDidWake() {
        guard let text = stoppedBySleep else { return }
        stoppedBySleep = nil
        alert(String(localized: "Recording stopped"), text)
    }

    @objc func openMeetings() {
        let path = CallFolder.defaultFolder
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc func openLog() {
        let url = Identity.pipelineLog
        if FileManager.default.fileExists(atPath: url.path),
           let console = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") {
            NSWorkspace.shared.open([url], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(Identity.logsDir)
        }
    }

    @objc func pause() {
        // the pause survives a restart; the current job stops right away
        if queue.current?.kind == .transcribe, let key = queue.current?.key {
            guard confirm(String(localized: "The recording from \(recordingTitle(key)) is being transcribed right now."),
                          String(localized: "It will stop and start over when you resume. Finished transcripts won't be affected."),
                          ok: String(localized: "Pause")) else { return }
        }
        queue.pause()
        refreshIcon()
    }

    /// The switch in the panel. The panel stays open; only the question (while something is being transcribed) has to
    /// be in front of it, so the panel steps aside for that and comes back with the answer on the switch.
    func pauseFromPanel() {
        let asks = queue.current?.kind == .transcribe
        if asks { closePanel() }
        pause()
        if asks { openPanel() }
    }

    @objc func resume() {
        queue.resume()
        refreshIcon()
    }

    /// Into the queue; if transcription is paused, say when it will happen.
    func enqueueAgain(_ key: String) {
        queue.reprocess(key)
        if queue.paused {
            alert(String(localized: "Transcription is paused"), String(localized: "Got it. This will happen as soon as you resume transcription."))
        }
    }

    @objc func checkForUpdates() { Updates.shared.checkNow() }

    /// About: the version, who made the speech models (their license, CC-BY-4.0, asks for this) and the software Koe
    /// is built with; "All licenses" opens THIRD_PARTY_NOTICES.md from the app.
    @objc func about() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSMutableAttributedString()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                                                   .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
        func text(_ s: String) { credits.append(NSAttributedString(string: s, attributes: base)) }
        func link(_ s: String, _ url: String) {
            var a = base
            a[.link] = URL(string: url)
            credits.append(NSAttributedString(string: s, attributes: a))
        }
        text(String(localized: "Records your calls and any other sound, and transcribes them right on your Mac.") + "\n\n")
        text(String(localized: "Speech recognition: ")); link("Parakeet TDT 0.6B v3", "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3")
        text(String(localized: " by NVIDIA, fine-tuned by moondream as ")); link("Parakeet Ultra", "https://huggingface.co/moondream/parakeet-ultra")
        text(String(localized: ". License: ")); link("CC BY 4.0", "https://creativecommons.org/licenses/by/4.0/")
        text(".\n")
        text(String(localized: "Speech detection: ")); link("Silero VAD", "https://github.com/snakers4/silero-vad")
        text(String(localized: " (MIT).") + "\n")
        text(String(localized: "Telling voices apart: ")); link("pyannote Community-1", "https://huggingface.co/pyannote/speaker-diarization-community-1")
        text(String(localized: " by pyannote, with WeSpeaker and BUT Speech@FIT. License: ")); link("CC BY 4.0", "https://creativecommons.org/licenses/by/4.0/")
        text(".\n")
        text(String(localized: "All of them run with ")); link("FluidAudio", "https://github.com/FluidInference/FluidAudio")
        text(" \(fluidAudioVersion) (Apache 2.0)")
        if Updates.supported {
            text(String(localized: ", updates come with ")); link("Sparkle", "https://sparkle-project.org")
            text(" (MIT)")
        }
        text(".\n\n")
        text(String(localized: "Koe is free and open source under the MIT License. "))
        if let notices = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") {
            link(String(localized: "All licenses"), notices.absoluteString)
        }
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    func reprocess(_ key: String) {
        let title = meetingTitle(registry[key]?["out_dir"] as? String ?? key)
        guard confirm(String(localized: "Retranscribe the recording from \(title)?"),
                      String(localized: "This rewrites transcript.md (and Koe's own files in the hidden .koe folder). If you edited transcript.md by hand, your version is kept next to it as transcript.edited-<date>.md. The audio and anything else in the folder aren't touched."),
                      ok: String(localized: "Retranscribe")) else { return }
        enqueueAgain(key)
    }

    func showFailure(_ key: String) {
        let rec = registry[key] ?? [:]
        let err = rec["last_error"] as? String ?? String(localized: "unknown reason")
        let attempts = rec["attempts"] as? Int ?? 0
        if confirm(String(localized: "Couldn't transcribe the recording from \(recordingTitle(key))"),
                   String(localized: "\(key)\n\nAttempts: \(attempts)\nError: \(err)\n\nThere's more in the log."),
                   ok: String(localized: "Try Again")) {
            enqueueAgain(key)
        }
    }


    @objc func quit() {
        if let rec = recording {
            guard confirm(String(localized: "Recording in progress (\(clock(Date().timeIntervalSince(rec.startedAt))))"),
                          String(localized: "Stop recording and quit? What's been recorded will be saved and transcribed."),
                          ok: String(localized: "Stop and Quit")) else { return }
            finishRecording(reason: "quit")
        }
        NSApp.terminate(nil)
    }

    /// A notification; if notifications are off for the app — an alert instead, so the message isn't lost
    /// ("Transcript ready" is the exception: without notifications it's simply not shown). folder — a click on the
    /// notification opens it.
    func notify(_ title: String, _ text: String, folder: URL? = nil) {
        UNUserNotificationCenter.current().getNotificationSettings { st in
            let allowed = [.authorized, .provisional].contains(st.authorizationStatus)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard allowed else {
                        if folder == nil { self.alert(title, text) }
                        return
                    }
                    let c = UNMutableNotificationContent()
                    c.title = title
                    c.body = text
                    if let folder { c.userInfo = ["folder": folder.path] }
                    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
                }
            }
        }
    }

    func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    func confirm(_ title: String, _ text: String, ok: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: ok)
        a.addButton(withTitle: String(localized: "Cancel"))
        return a.runModal() == .alertFirstButtonReturn
    }
}

/// What transcription is doing, as lines (for --run-queue).
@MainActor
func queueStatusText(_ queue: TranscriptionQueue) -> [String] {
    var out: [String]
    switch queue.phase {
    case .paused: out = [String(localized: "Paused · recording still works")]
    case .downloading(let f):
        out = [f.map { String(localized: "Downloading speech model… \(Int($0 * 100)) %") } ?? String(localized: "Downloading speech model…")]
    case .preparing: out = [String(localized: "Getting the speech model ready…")]
    case .transcribing(let f): out = [String(localized: "Transcribing… \(Int(f * 100)) %")]
    case .names: out = [String(localized: "Updating speaker names…")]
    case .idle:
        if let problem = queue.modelsProblem, queue.waiting > 0 {
            // the speech models can't be downloaded now (no internet, no space): the recordings wait
            out = [String(localized: "Waiting for the speech models"), problem]
        } else {
            switch ModelStore.shared.activity {
            case .downloading(let f):
                out = [f.map { String(localized: "Downloading speech models… \(Int($0 * 100)) %") } ?? String(localized: "Downloading speech models…")]
            case .preparing: out = [String(localized: "Getting the speech model ready…")]
            default: out = [String(localized: "On")]
            }
        }
    }
    if let key = queue.current?.key, queue.current?.kind == .transcribe {
        let when = recordingTitle(key)
        out.append(queue.current?.force == true ? String(localized: "Retranscribing: recording from \(when)") : String(localized: "Recording from \(when)"))
    }
    let waiting = queue.waiting
    if waiting > 0 { out.append(String(localized: "Waiting: \(waiting)")) }
    return out
}

/// After a recording: the system audio track came out silent — the title and text of the warning, or nil.
/// The system audio permission can't be checked in advance: without it, recording runs but captures silence.
func silenceWarning(_ doc: [String: Any], system: SystemAudio, micRecorded: Bool) -> (String, String)? {
    let tracks = doc["tracks"] as? [String: [String: Any]] ?? [:]
    let duration = (doc["duration_s"] as? NSNumber)?.doubleValue ?? 0
    guard let track = tracks["system"], duration > 20,
          ((track["peak_db"] as? NSNumber)?.doubleValue ?? 0) <= -199 else { return nil }
    let micFine = micRecorded ? " " + String(localized: "Your microphone was recorded fine.") : ""
    let settings = String(localized: "System Settings → Privacy & Security → Screen & System Audio Recording → \(Identity.appName)")
    if system.apps.isEmpty {
        return (String(localized: "System audio came out silent"),
                String(localized: "If you could hear sound from other apps, \(Identity.appName) probably isn't allowed to record it. Turn it on in \(settings).") + micFine)
    }
    return (String(localized: "No sound came from \(orList(system.apps.map(\.name)))"),
            String(localized: "If you could hear something, it probably came from a different app. Tick that app, or pick All system audio, in the menu under System audio. If that doesn't help, check the permission in \(settings).") + micFine)
}

/// Watchdog: if the app (menu, windows) doesn't respond for more than a second, it writes that to recorder.log
/// together with a snapshot of what it was busy with (`sample`), so there's something to dig into. At most one
/// snapshot every 10 minutes: taking one takes a couple of seconds.
enum StallWatch {
    static func start() {
        Thread.detachNewThread {
            var lastSample = Date.distantPast
            while true {
                let answered = DispatchSemaphore(value: 0)
                let t0 = Date()
                DispatchQueue.main.async { answered.signal() }
                if answered.wait(timeout: .now() + 1) == .timedOut {
                    var file: String?
                    if Date().timeIntervalSince(lastSample) > 600 {
                        lastSample = Date()
                        let f = DateFormatter()
                        f.dateFormat = "yyyy-MM-dd_HHmmss"
                        let path = Identity.logsDir.appendingPathComponent("stall-\(f.string(from: t0)).txt").path
                        run("/usr/bin/sample", "\(getpid())", "2", "-file", path)
                        file = path
                    }
                    answered.wait()
                    recLog(String(format: "app was unresponsive for %.1f s", Date().timeIntervalSince(t0)) + (file.map { ", sample: \($0)" } ?? ""))
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }
}
