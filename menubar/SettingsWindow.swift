// The Settings window: General, Transcription, Transcripts (speaker names, retranscribing) and Help. What's changed
// before a recording — microphones, system audio, quality, the folder for one recording, names — is in the panel
// (Panel.swift).
//
// Most of it lives in settings.json in the app's data folder (Identity.settingsFile): only SettingsModel writes it (the
// panel's Names fields go through it too), and transcription reads it. Changes are saved right away, like in macOS System Settings.
// The microphone tracks are the exception: they're only for the recorder and live in the app's defaults
// (RecordingFormat.swift). The language isn't chosen: it's detected on each track (an old "language" in
// settings.json is ignored).
//
// Speaker names for a recording live in speakers.json in its transcript folder (in the hidden .koe, MeetingFolder.swift). The Transcripts tab lists every transcript
// (Meetings.withSpeakers); a picked one shows its microphone tracks and the voices of system audio (Meetings.nameRows),
// each with how long they talked and a few seconds of their speech to listen to. New names go to the transcription
// queue as a job.
//
// SwiftUI texts written as literals (Text("…"), Button("…")) are localized the same way as
// String(localized:): the English text is the key.
import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

/// "~/Documents/Koe Dev" instead of the full path.
func shortPath(_ path: String) -> String {
    path.hasPrefix(home.path) ? "~" + path.dropFirst(home.path.count) : path
}

/// "Documents/Koe Dev" — for the menu: the last folder alone isn't enough, different projects may use the same name.
func folderTitle(_ path: String) -> String {
    let parts = URL(fileURLWithPath: path).pathComponents.suffix(2)
    return parts.joined(separator: "/")
}

/// Pick a folder. From the Settings window it's a sheet on that window, without a separate modal loop:
/// that way the panel doesn't get lost behind the window, and the app doesn't freeze while it's open.
@MainActor
func chooseFolder(_ title: String, start: String?, in window: NSWindow? = nil, done: @escaping (String) -> Void) {
    NSApp.activate(ignoringOtherApps: true)
    let panel = NSOpenPanel()
    panel.message = title
    panel.prompt = String(localized: "Choose")
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    if let start { panel.directoryURL = URL(fileURLWithPath: start) }
    let finish: (NSApplication.ModalResponse) -> Void = { r in
        if r == .OK, let p = panel.url?.path { done(p) }
    }
    // SwiftUI buttons call us in the middle of handling the click — open the panel after that
    DispatchQueue.main.async {
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }
}

// ---------- the folder for recordings (menu → Save to) ----------

/// Where the next recording's transcript goes. nil means the default folder from Settings.
/// The choice is written to session.json when recording stops, so it can be changed during the recording too.
enum CallFolder {
    static var current: String? {
        get { UserDefaults.standard.string(forKey: "callFolder") }
        set {
            UserDefaults.standard.set(newValue, forKey: "callFolder")
            if let newValue { recent = [newValue] + recent.filter { $0 != newValue } }
        }
    }

    static var recent: [String] {
        get { Array((UserDefaults.standard.stringArray(forKey: "recentFolders") ?? []).prefix(5)) }
        set { UserDefaults.standard.set(Array(newValue.prefix(5)), forKey: "recentFolders") }
    }

    /// The default folder: from Settings, and until something is chosen there — ~/Documents/<app name>.
    static var defaultFolder: String {
        readJSON(Identity.settingsFile)["meetings_folder"] as? String ?? Identity.defaultMeetingsFolder
    }
}

// ---------- window data ----------

/// A row of the Names tab: a microphone track (renamed for this recording only) or a voice of system audio.
struct SpeakerRow: Identifiable {
    enum Kind { case track, voice }
    var id: String { (kind == .track ? "track:" : "voice:") + key }
    let kind: Kind
    let key: String           // the track ("mic-2") or the voice's label ("Speaker 1")
    let title: String
    let detail: String?       // the device
    let placeholder: String   // the name when the field is empty
    let speech: Double        // seconds
    let clip: VoiceClip?
    var name: String
}

/// A few seconds of someone's speech in a track's file.
struct VoiceClip {
    let file: URL
    let start: Double   // in the file
    let length: Double

    static let length = 5.0

    /// The phrase nearest to clipLength (longer ones first), from the timeline to the file (shift).
    static func pick(_ phrases: [(Double, Double)], file: URL, shift: Double) -> VoiceClip? {
        let best = phrases.filter { $0.1 - $0.0 >= 0.8 }.min { a, b in
            let (da, db) = (a.1 - a.0, b.1 - b.0)
            return (da >= 3 ? 0 : 1, abs(da - length)) < (db >= 3 ? 0 : 1, abs(db - length))
        }
        guard let best else { return nil }
        return VoiceClip(file: file, start: max(0, best.0 + shift - 0.2), length: min(max(best.1 - best.0 + 0.5, 2), length + 2))
    }
}

struct MeetingItem: Identifiable, Hashable {
    let id: String      // the recording's key in the registry: local:…
    let outDir: String
}

/// What the window asks the app to do: pause transcription, transcribe again, open files.
struct SettingsActions {
    var pause: () -> Void = {}
    var resume: () -> Void = {}
    var reprocess: (String) -> Void = { _ in }
    var openLog: () -> Void = {}
    var setUpAgain: () -> Void = {}
}

struct CallNames: Identifiable {
    var id: String { outDir }
    let outDir: String
    var rows: [SpeakerRow]? = nil              // read when the recording is picked
    var saved = SpeakerNames.Names()           // what the rows had when read — so only changed recordings are sent

    /// The rows as speakers.json has them: voices by label, renamed tracks by track.
    var names: SpeakerNames.Names {
        var n = SpeakerNames.Names()
        for r in rows ?? [] {
            let name = r.name.trimmingCharacters(in: .whitespaces)
            switch r.kind {
            case .voice: n.speakers[r.key] = name
            case .track: if !name.isEmpty { n.tracks[r.key] = name }
            }
        }
        return n
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    /// The window's tabs.
    enum Tab {
        static let general = 0
        static let transcription = 1
        static let transcripts = 2
        static let help = 3
    }
    @Published var tab = Tab.general
    @Published var me = SettingsModel.defaultMe { didSet { changed() } }
    @Published var other = SettingsModel.defaultOther { didSet { changed() } }
    @Published var meetingsFolder = "" { didSet { changed() } }
    @Published var vocabulary = "" { didSet { changed() } }
    @Published var threshold = VoiceTuning.defaultThreshold { didSet { changed() } }
    @Published var calls: [CallNames] = []
    @Published var selectedCall = "" { didSet { loadRows() } }
    @Published var playing: String?   // the row whose speech is playing
    @Published var namesNote = ""
    // these three don't live in settings.json: the call suggestion is in the app's defaults, login items are in the system
    @Published var suggest = Identity.suggestCallsByDefault
    @Published var ignored: [String: String] = [:]
    @Published var atLogin = false
    @Published var paused = false
    @Published var meetings: [MeetingItem] = []
    @Published var reprocessKey = ""
    // Recording: saved to the app's defaults right away; applies to the next recording
    @Published var quality = RecordingQuality.compact {
        didSet { if !loading && !readOnly { RecordingQuality.saved = quality } }
    }
    /// The ticked microphones and Off (MicChoice), the devices connected now, and the tracks they make (MicPlan).
    @Published var micOff = false
    @Published var micPicks: [MicPick] = []
    @Published var inputDevices: [InputDevice] = []
    @Published var micTracks: [MicTrack] = []
    /// System audio isn't off (it's chosen in the menu) — for the size estimate and the "nothing to record" note.
    @Published var systemOn = true
    var actions = SettingsActions()
    /// For drawing the window from the command line (--settings-png): don't save anything.
    var readOnly = false
    /// The names changed (you, the other side) — the queue updates them in finished transcripts.
    /// Folders and the threshold only affect future recordings: transcription reads them itself.
    var onSaved: (() -> Void)?
    /// The Settings window — for the folder picker.
    weak var window: NSWindow?
    /// Send a call's speaker names to the queue.
    var onSpeakers: ((String, SpeakerNames.Names) -> Void)?
    private var raw: [String: Any] = [:]
    private var loading = false
    private var pending: DispatchWorkItem?
    /// Default labels in transcripts. They're data, not interface: a transcript keeps them whatever the interface language.
    nonisolated static let defaultMe = "Me"
    nonisolated static let defaultOther = "Speaker"

    func load() {
        loadFields()
        loadDevices()
        loadAgent()
        loadNames()
    }

    /// What settings.json has, and the recording quality. The panel calls this too: it shows the names.
    func loadFields() {
        loading = true
        defer { loading = false }
        raw = readJSON(Identity.settingsFile)
        me = raw["me"] as? String ?? SettingsModel.defaultMe
        other = raw["other"] as? String ?? SettingsModel.defaultOther
        meetingsFolder = raw["meetings_folder"] as? String ?? CallFolder.defaultFolder
        vocabulary = raw["vocabulary"] as? String ?? ""
        threshold = (raw["voice_threshold"] as? NSNumber)?.doubleValue ?? VoiceTuning.defaultThreshold
        quality = .saved
        systemOn = SystemAudio.saved != .off
    }

    /// Input devices and the microphone choice; also called when a device is connected or disconnected.
    func loadDevices() {
        inputDevices = InputDevice.all()
        micOff = MicChoice.off
        micPicks = MicChoice.picks
        micTracks = MicPlan.tracks(MicChoice.active, devices: inputDevices)
    }

    var micOn: Bool { !micOff }

    func isTicked(_ uid: String?) -> Bool { !micOff && micPicks.contains { $0.uid == uid } }

    /// Tick or untick a microphone (unticking the last one turns the microphone off, as in the menu).
    func toggleMic(_ pick: MicPick) {
        guard !readOnly else { return }
        MicChoice.toggle(pick)
        loadDevices()
    }

    /// The ticked devices that are connected and have more than one input — they get an Input channels choice.
    var multiChannel: [InputDevice] {
        let defaultUID = InputDevice.systemDefault?.uid
        var seen = Set<String>()
        return micPicks.compactMap { p in
            guard !micOff, let d = inputDevices.first(where: { $0.uid == (p.uid ?? defaultUID) }), d.channels > 1,
                  seen.insert(d.uid).inserted else { return nil }
            return d
        }
    }

    func channels(_ d: InputDevice) -> InputChannels { InputChannels.saved(uid: d.uid, count: d.channels) }

    func setChannels(_ pick: InputChannels, _ d: InputDevice) {
        guard !readOnly else { return }
        InputChannels.save(pick, uid: d.uid)
        loadDevices()
    }

    /// A track's name or Transcribe changed in Settings → Inputs: remembered by device and input (MicTrack.key).
    func setTrack(_ i: Int, name: String? = nil, transcribe: Bool? = nil) {
        guard !readOnly, micTracks.indices.contains(i) else { return }
        if let name { micTracks[i].name = name.isEmpty ? nil : name }
        if let transcribe { micTracks[i].transcribe = transcribe }
        InputTracks.set(micTracks[i].key, name: micTracks[i].name, transcribe: micTracks[i].transcribe)
    }

    /// The pause and finished transcripts — from the queue and the registry.
    func loadAgent() {
        paused = TranscriptionQueue.shared.paused
        meetings = Registry.recordings.compactMap { key, r in
            guard r["status"] as? String == "done", let dir = r["out_dir"] as? String else { return nil }
            return MeetingItem(id: key, outDir: dir)
        }.sorted { ($0.outDir as NSString).lastPathComponent > ($1.outDir as NSString).lastPathComponent }
        if !meetings.contains(where: { $0.id == reprocessKey }) { reprocessKey = meetings.first?.id ?? "" }
    }

    func loadNames() {
        calls = Meetings.withSpeakers()
        if !calls.contains(where: { $0.outDir == selectedCall }) { selectedCall = calls.first?.outDir ?? "" }
        loadRows()
        namesNote = ""
    }

    /// The picked recording's rows, read the first time it's picked.
    private func loadRows() {
        stopPlaying()
        guard let i = calls.firstIndex(where: { $0.outDir == selectedCall }), calls[i].rows == nil else { return }
        calls[i].rows = Meetings.nameRows(URL(fileURLWithPath: selectedCall))
        calls[i].saved = calls[i].names
    }

    // ---------- listening to a bit of someone's speech ----------

    private var player: AVAudioPlayer?
    private var stopWork: DispatchWorkItem?

    func play(_ row: SpeakerRow) {
        let was = playing
        stopPlaying()
        guard was != row.id, let clip = row.clip else { return }
        do {
            let p = try AVAudioPlayer(contentsOf: clip.file)
            p.currentTime = min(clip.start, max(0, p.duration - 0.5))
            p.play()
            player = p
            playing = row.id
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.stopPlaying() } }
            stopWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + clip.length, execute: work)
        } catch {
            namesNote = String(localized: "Couldn't play \(clip.file.lastPathComponent)")
        }
    }

    func stopPlaying() {
        stopWork?.cancel()
        stopWork = nil
        player?.stop()
        player = nil
        playing = nil
    }

    private func changed() {
        guard !loading, !readOnly else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.save() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func save() {
        pending?.cancel()
        var d = raw
        let me = me.trimmingCharacters(in: .whitespaces), other = other.trimmingCharacters(in: .whitespaces)
        d["me"] = me.isEmpty ? SettingsModel.defaultMe : me
        d["other"] = other.isEmpty ? SettingsModel.defaultOther : other
        if !meetingsFolder.isEmpty { d["meetings_folder"] = meetingsFolder }
        d["vocabulary"] = vocabulary
        d["voice_threshold"] = round3(threshold)
        try? FileManager.default.createDirectory(at: Identity.settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        writeJSON(d, Identity.settingsFile)
        let names: ([String: Any]) -> NSDictionary = { NSDictionary(dictionary: $0.filter { ["me", "other"].contains($0.key) }) }
        let namesChanged = !names(raw).isEqual(names(d))
        raw = d
        if namesChanged { onSaved?() }
    }

    /// Write what's waiting to be saved now (the setup window is closing).
    func flush() {
        guard !readOnly, !loading else { return }
        save()
    }

    /// The Save button on the Names tab: changed calls go to the pipeline.
    func saveNames() {
        for i in calls.indices where calls[i].rows != nil {
            let names = calls[i].names
            guard names != calls[i].saved else { continue }
            onSpeakers?(calls[i].outDir, names)
            calls[i].saved = names
        }
        namesNote = TranscriptionQueue.shared.busy ? String(localized: "Saved. It'll apply once the current transcription finishes.")
                                                   : String(localized: "Saved")
    }
}

// ---------- the view ----------

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    let watcher: CallWatcher

    var body: some View {
        TabView(selection: $model.tab) {
            GeneralTab(model: model, watcher: watcher)
                .tabItem { Text("General") }.tag(SettingsModel.Tab.general)
            TranscriptionTab(model: model)
                .tabItem { Text("Transcription") }.tag(SettingsModel.Tab.transcription)
            TranscriptsTab(model: model)
                .tabItem { Text("Transcripts") }.tag(SettingsModel.Tab.transcripts)
            HelpTab(model: model)
                .tabItem { Text("Help") }.tag(SettingsModel.Tab.help)
        }
        .padding(.top, 8)
        .frame(width: 600, height: 620)
    }
}

/// What's set once: the call suggestion, the default folder, login and updates. What's changed before a recording
/// (microphones, system audio, quality, names) is in the panel.
struct GeneralTab: View {
    @ObservedObject var model: SettingsModel
    let watcher: CallWatcher

    var body: some View {
        Form {
            Section {
                Toggle("Offer to record calls", isOn: $model.suggest)
                    .onChange(of: model.suggest) { _, on in
                        watcher.enabled = on
                        if on { watcher.askPermission() }
                    }
                if !model.ignored.isEmpty {
                    HStack {
                        Text("Not offered for: \(model.ignored.values.sorted().joined(separator: ", "))")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Offer Again") {
                            watcher.ignored = [:]
                            model.ignored = [:]
                        }
                    }
                }
            } header: {
                Text("Recording")
            } footer: {
                Text("Microphones, system audio, quality and names are in the panel: click the \(Identity.appName) icon in the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                LabeledContent("Save transcripts to") {
                    HStack {
                        Text(shortPath(model.meetingsFolder)).lineLimit(1).truncationMode(.middle)
                        Button("Change…") {
                            chooseFolder(String(localized: "Where should transcripts go by default?"), start: model.meetingsFolder,
                                         in: model.window) { model.meetingsFolder = $0 }
                        }
                    }
                }
            } header: {
                Text("Folders")
            } footer: {
                Text("The default. For one recording, pick another folder in the panel under Transcription → Save to.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("Other") {
                Toggle("Open at login", isOn: $model.atLogin)
                    .onChange(of: model.atLogin) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    }
                if Updates.supported { UpdatesToggle() }
            }
        }
        .formStyle(.grouped)
    }
}

/// How transcription works: language, vocabulary, telling voices apart, the microphone tracks and the speech models.
struct TranscriptionTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Transcription") {
                LabeledContent("Language") {
                    Text("Detected automatically on each track")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Vocabulary")
                    TextEditor(text: $model.vocabulary)
                        .font(.body)
                        .frame(height: 64)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
                    Text("Helps with English names and terms, one per line: products, brands, unusual names. Only words in Latin letters are used, and it rarely helps in other languages. It downloads one more model (~100 MB) and makes transcription about three times slower.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Telling voices apart")
                    Slider(value: $model.threshold, in: VoiceTuning.range, step: 0.05) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("more people").font(.caption)
                    } maximumValueLabel: {
                        Text("fewer people").font(.caption)
                    }
                    Text("How readily system audio is split into different people. Applies to new recordings; for an old one, retranscribe it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            TrackNamesSection(model: model)

            ModelsSection(model: model)
        }
        .formStyle(.grouped)
    }
}

/// Set Up Again, the log, the recordings' audio, the version.
struct HelpTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Setup") {
                    Button("Set Up Again…") { model.actions.setUpAgain() }
                }
                LabeledContent("What \(Identity.appName) did") {
                    Button("Open Log") { model.actions.openLog() }
                }
                LabeledContent("Audio of recordings") {
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: Identity.inboxDir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Identity.inboxDir)
                    }
                }
            } footer: {
                Text("If something doesn't work, the log says what happened. Recordings stay there until they're transcribed.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                LabeledContent("Version") {
                    Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings → General → Other → Check for updates automatically (release only). Sparkle keeps the choice itself.
struct UpdatesToggle: View {
    @ObservedObject var updates = Updates.shared

    var body: some View {
        Toggle("Check for updates automatically", isOn: Binding(get: { updates.automaticallyChecks },
                                                                set: { updates.automaticallyChecks = $0 }))
    }
}

/// Settings → Speech models: each model, its size, whether it's on this Mac, Delete / Download.
/// A deleted model is downloaded again the next time it's needed.
struct ModelsSection: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var store = ModelStore.shared

    var body: some View {
        let _ = store.revision
        // a model can't be deleted while it's downloading or transcription has it loaded
        let inUse = store.busy || TranscriptionQueue.shared.busy
        Section {
            ForEach(SpeechModel.allCases) { m in
                let there = m.isDownloaded
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.title)
                        Text(m.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(there ? humanSize(Double(m.sizeOnDisk)) : String(localized: "\(humanSize(Double(m.size))), not downloaded"))
                        .monospacedDigit().foregroundStyle(.secondary)
                    if there {
                        Button("Delete") {
                            if model.readOnly { return }
                            let ok = confirmAlert(String(localized: "Delete \(m.title)?"),
                                                  String(localized: "It frees \(humanSize(Double(m.sizeOnDisk))). \(Identity.appName) downloads it again the next time it's needed."),
                                                  ok: String(localized: "Delete"))
                            if ok { store.delete(m) }
                        }
                        .disabled(inUse)
                    } else {
                        Button("Download") { if !model.readOnly { store.download([m]) } }
                            .disabled(store.busy)
                    }
                }
            }
            switch store.activity {
            case .downloading(let f):
                ProgressView(value: f ?? 0) { Text(f.map { String(localized: "Downloading… \(Int($0 * 100)) %") } ?? String(localized: "Starting the download…")) }
            case .preparing:
                ProgressView { Text("Getting the models ready for this Mac…") }
            case .failed(let why):
                Text(why).font(.caption).foregroundStyle(.secondary)
            case .idle:
                EmptyView()
            }
        } header: {
            Text("Speech models")
        } footer: {
            Text(inUse && !store.busy ? String(localized: "Models can't be deleted while transcription is running.")
                 : String(localized: "They live in the app's data folder. A deleted model is downloaded again the next time it's needed.")
                 + (freeDiskSpace().map { " " + String(localized: "\(humanSize(Double($0))) free on this Mac.") } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// An alert with OK and Cancel; true — OK.
@MainActor
func confirmAlert(_ title: String, _ text: String, ok: String) -> Bool {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    a.addButton(withTitle: ok)
    a.addButton(withTitle: String(localized: "Cancel"))
    return a.runModal() == .alertFirstButtonReturn
}

/// Settings → Transcription → Microphone tracks: every track the ticked microphones make, its name in the transcript
/// and whether to transcribe it. The microphones themselves are ticked in the panel.
struct TrackNamesSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        if !model.micTracks.isEmpty {
            Section {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    ForEach(Array(model.micTracks.enumerated()), id: \.element.id) { i, t in
                        GridRow {
                            Text(t.label).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                                .frame(maxWidth: 200, alignment: .leading)
                            TextField("Name", text: Binding(get: { t.name ?? "" }, set: { model.setTrack(i, name: $0) }),
                                      prompt: Text(verbatim: t.defaultName ?? model.me))
                                .labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.leading).frame(width: 130)
                            Toggle("Transcribe", isOn: Binding(get: { t.transcribe }, set: { model.setTrack(i, transcribe: $0) }))
                        }
                    }
                }
            } header: {
                Text("Microphone tracks")
            } footer: {
                Text("The name is how the track is labeled in the transcript. Turn off Transcribe for an instrument: its track is still recorded.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Finished transcripts: open the latest, retranscribe one, name the people in it.
struct TranscriptsTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let last = model.meetings.first {
                    Section("Transcripts") {
                        LabeledContent("Latest") {
                            HStack {
                                Text(meetingTitle(last.outDir))
                                Button("Open") {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: last.outDir).appendingPathComponent("transcript.md"))
                                }
                            }
                        }
                        HStack {
                            Picker("Retranscribe", selection: $model.reprocessKey) {
                                ForEach(model.meetings) { m in Text(meetingTitle(m.outDir)).tag(m.id) }
                            }
                            Button("Start") { model.actions.reprocess(model.reprocessKey) }
                                .disabled(model.reprocessKey.isEmpty)
                        }
                    }
                }
                Section {
                    if model.calls.isEmpty {
                        Text("No transcripts yet").foregroundStyle(.secondary)
                    } else {
                        Picker("Recording", selection: $model.selectedCall) {
                            ForEach(model.calls) { c in Text(meetingTitle(c.outDir)).tag(c.outDir) }
                        }
                        if let i = model.calls.firstIndex(where: { $0.outDir == model.selectedCall }), model.calls[i].rows != nil {
                            if model.calls[i].rows!.isEmpty {
                                Text("Nothing to name: no track of this recording was transcribed").foregroundStyle(.secondary)
                            }
                            ForEach(Binding(get: { model.calls[i].rows ?? [] }, set: { model.calls[i].rows = $0 })) { $row in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(row.title)
                                        Text(row.detail.map { "\($0) · " } ?? "").font(.caption).foregroundStyle(.secondary)
                                            + Text("talked for \(clock(row.speech))").font(.caption).foregroundStyle(.secondary)
                                    }
                                    .frame(width: 190, alignment: .leading)
                                    Button {
                                        model.play(row)
                                    } label: {
                                        Image(systemName: model.playing == row.id ? "stop.fill" : "play.fill").frame(width: 14)
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(row.clip == nil)
                                    .help(row.clip == nil ? String(localized: "No audio to play") : String(localized: "Listen to a few seconds"))
                                    TextField("Name", text: $row.name, prompt: Text(verbatim: row.placeholder))
                                        .labelsHidden().textFieldStyle(.roundedBorder)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Recordings")
                } footer: {
                    Text("Same name on two rows means it's the same person: their lines are merged. A microphone renamed here is renamed in this recording only.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Text(model.namesNote).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save") { model.saveNames() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .onDisappear { model.stopPlaying() }
    }
}
