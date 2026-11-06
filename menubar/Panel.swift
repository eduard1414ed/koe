// The panel that opens from the menu bar icon (docs/SPEC.md, 6.8; the mockup is docs/menu-panel.html): a popover with
// the Record button and four tabs — Microphone, System audio, Format, Transcription — and Transcripts, Settings and
// Quit at the bottom. A right click on the icon opens a short menu instead (About, updates, Quit): KoeMenu.swift.
//
// PanelModel builds what each tab shows as plain data (sections of rows, each row with its action); PanelView only
// draws it. The same data is printed by --dump and clicked by --click (main.swift), so the tests see what a person
// sees. Every size comes from PanelMetrics: the layout rules of the spec, in one place.
import AppKit
import SwiftUI

// ---------- the layout rules ----------

enum PanelMetrics {
    static let width: CGFloat = 328
    static let inset: CGFloat = 12          // inside the panel
    static let gap: CGFloat = 12            // between blocks
    static let headerGap: CGFloat = 8       // a section's header → its card
    static let header: CGFloat = 28
    static let record: CGFloat = 40
    static let tab: CGFloat = 30            // the tab bar is 38: a tab, 3 around it, 1 of border
    static let tabPadding: CGFloat = 3
    static let footer: CGFloat = 30
    static let rowV: CGFloat = 10           // a row: 10 above and below, 12 at the sides
    static let rowH: CGFloat = 12
    static let icon: CGFloat = 20           // the icon (tick, symbol) column, then 10 to the text
    static let iconGap: CGFloat = 10
    static var textLead: CGFloat { rowH + icon + iconGap }   // 42: where text and separators start
    static let line: CGFloat = 16           // a title line; icons and controls on the right line up with it
    static let lineGap: CGFloat = 2         // title → subtitle
    static let controlGap: CGFloat = 8      // text → a progress bar under it
    static let cardRadius: CGFloat = 12
    static let buttonRadius: CGFloat = 8
    static let smallRadius: CGFloat = 6     // controls up to 24 high
    static let titleSize: CGFloat = 13
    static let smallSize: CGFloat = 11
}

/// The panel is always dark (like the setup window), so these are fixed.
enum PanelColors {
    static let text = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.5)
    static let card = Color.white.opacity(0.07)
    static let border = Color.white.opacity(0.10)
    static let separator = Color.white.opacity(0.08)
    static let hover = Color.white.opacity(0.05)
    static let accent = Color(nsColor: .controlAccentColor)
    static let red = Color(nsColor: .systemRed)
    static let green = Color(nsColor: .systemGreen)
    static let orange = Color(nsColor: .systemOrange)
}

// ---------- what the panel shows ----------

/// One row of a card.
struct PanelItem: Identifiable {
    enum Lead {
        case symbol(String, Color = PanelColors.accent)
        case check(Bool)
        case radio(Bool)
    }
    enum Trail {
        case none
        case toggle(Bool)
        case value(String)
        case chevron
        case channels(InputDevice)          // the device's Input channels, as a small pop-up menu
        case meter(String)                  // the level of a track while recording: PanelLevels key
        case field(Binding<String>, String) // a text field and its placeholder
    }
    let id: String
    var title: String
    var subtitle: String? = nil
    var lead: Lead
    var trail: Trail = .none
    var appIcon: NSImage? = nil
    var progress: Double? = nil
    var volume: PanelVolume? = nil
    var accentTitle = false
    var enabled = true
    var action: (() -> Void)? = nil

    /// For --dump.
    var dumpLine: String {
        var mark = ""
        switch lead {
        case .check(let on), .radio(let on): mark = on ? "[x] " : "[ ] "
        case .symbol: break
        }
        var s = mark + title
        if let subtitle { s += " — " + subtitle }
        switch trail {
        case .toggle(let on): s += on ? "   (on)" : "   (off)"
        case .value(let v): s += "   " + v
        case .channels(let d): s += "   [" + InputChannels.saved(uid: d.uid, count: d.channels).title + "]"
        case .field(let b, let p): s += "   [" + (b.wrappedValue.isEmpty ? p : b.wrappedValue) + "]"
        default: break
        }
        if let progress { s += "   \(Int(progress * 100)) %" }
        if !enabled { s += "   (inactive)" }
        if let volume { s += "\n        volume " + TrackVolume.percent(TrackVolume.get(volume.key)) }
        return s
    }
}

/// A track's volume slider under a row: works while recording too, when the row itself is locked.
struct PanelVolume {
    let key: String                 // TrackVolume.key
    let set: (Double) -> Void
}

/// Folded rows under a section (Other devices).
struct PanelMore {
    let title: String
    let open: Bool
    let toggle: () -> Void
    let items: [PanelItem]
}

/// A header, a card of rows, and an optional line under it.
struct PanelSection: Identifiable {
    let id: String
    var title: String
    var note: String? = nil
    var warning = false             // an orange card: a permission that isn't given
    var items: [PanelItem]
    var more: PanelMore? = nil
    var footnote: String? = nil
}

/// The loudness of each track while recording, apart from the rest so only the meters redraw 15 times a second.
@MainActor
final class PanelLevels: ObservableObject {
    @Published var values: [String: Double] = [:]

    static func key(_ uid: String?) -> String { TrackVolume.key(uid) }

    func update(_ rec: CallRecording?) {
        guard let rec else { if !values.isEmpty { values = [:] }; return }
        var v: [String: Double] = [:]
        for p in MicChoice.active { if let l = rec.micLevel(p.uid) { v[PanelLevels.key(p.uid)] = l } }
        if let l = rec.systemLevel { v[TrackVolume.system] = l }
        values = v
    }
}

/// An app for the System audio tab.
struct AudioApp {
    let bundle: String
    let name: String
    let icon: NSImage?
    let note: String?
}

@MainActor
final class PanelModel: ObservableObject {
    enum Tab: Int, CaseIterable {
        case microphone, system, format, transcription

        var title: String {
            switch self {
            case .microphone: String(localized: "Microphone")
            case .system: String(localized: "System audio")
            case .format: String(localized: "Format")
            case .transcription: String(localized: "Transcription")
            }
        }

        var symbol: String {
            switch self {
            case .microphone: "mic"
            case .system: "speaker.wave.2"
            case .format: "waveform"
            case .transcription: "doc.text"
            }
        }
    }

    @Published var tab: Tab { didSet { UserDefaults.standard.set(tab.rawValue, forKey: "panelTab") } }
    @Published var showOthers = false
    private(set) var devices: [InputDevice] = []
    private(set) var apps: [AudioApp] = []
    let levels = PanelLevels()
    unowned let app: App

    init(app: App) {
        self.app = app
        tab = Tab(rawValue: UserDefaults.standard.integer(forKey: "panelTab")) ?? .microphone
    }

    /// The panel opens, or a device was connected: read the devices and the apps again.
    func reload() {
        devices = InputDevice.all()
        apps = audioApps()
        refresh()
    }

    /// Something changed (a choice, the queue, the clock): draw again.
    func refresh() { objectWillChange.send() }

    private func change(_ f: () -> Void) {
        f()
        refresh()
    }

    /// A volume slider: remembered for the next recordings and heard in the one that's going from now on.
    private func volume(_ key: String) -> PanelVolume {
        PanelVolume(key: key) { [unowned self] v in
            TrackVolume.set(key, v)
            self.app.recording?.setVolume(key, v)
        }
    }

    // ---------- the top of the panel ----------

    var recording: CallRecording? { app.recording }

    var micTracks: [MicTrack] { MicPlan.tracks(MicChoice.active, devices: devices) }

    var trackCount: Int { micTracks.count + (SystemAudio.saved == .off ? 0 : 1) }

    /// The pill in the header: what Koe is doing.
    var status: (text: String, color: Color) {
        if recording != nil { return (String(localized: "Recording"), PanelColors.red) }
        switch app.queue.phase {
        case .transcribing(let f): return ("\(Int(f * 100)) %", PanelColors.accent)
        case .downloading, .preparing: return (String(localized: "Getting ready"), PanelColors.accent)
        case .names: return (String(localized: "Updating names"), PanelColors.accent)
        case .paused: return (String(localized: "Paused"), PanelColors.secondary)
        case .idle: break
        }
        if case .downloading = ModelStore.shared.activity { return (String(localized: "Downloading"), PanelColors.accent) }
        if !failed.isEmpty { return (String(localized: "\(failed.count) failed"), PanelColors.orange) }
        return (String(localized: "Ready"), PanelColors.green)
    }

    /// The Record button: its title and the note on the right.
    var record: (title: String, note: String, canRecord: Bool) {
        if let rec = recording {
            return (String(localized: "Stop recording"), clock(Date().timeIntervalSince(rec.startedAt)), true)
        }
        let n = trackCount
        if n == 0 { return (String(localized: "Start recording"), String(localized: "Nothing to record"), false) }
        return (String(localized: "Start recording"), n == 1 ? String(localized: "1 track") : String(localized: "\(n) tracks"), true)
    }

    func recordClicked() {
        if recording != nil { app.stopRecording() } else if record.canRecord { app.startRecording() }
        refresh()
    }

    /// A tab with something to fix gets a dot on its icon.
    func needsAttention(_ tab: Tab) -> Bool {
        let w = app.permissionWarnings().map(\.0)
        switch tab {
        case .microphone: return w.contains(.microphone)
        case .system: return w.contains(.systemAudio)
        case .format: return false
        case .transcription: return w.contains(.notifications) || !failed.isEmpty
        }
    }

    // ---------- the tabs ----------

    func sections(_ tab: Tab) -> [PanelSection] {
        switch tab {
        case .microphone: micSections()
        case .system: systemSections()
        case .format: formatSections()
        case .transcription: transcriptionSections()
        }
    }

    private func warnings(_ p: Permission) -> [PanelSection] {
        app.permissionWarnings().filter { $0.0 == p }.map { _, state, title in
            PanelSection(id: "warning-\(p.rawValue)", title: "", warning: true, items: [
                PanelItem(id: "fix-\(p.rawValue)", title: title,
                          subtitle: state == .denied ? String(localized: "Turn it on in System Settings") : String(localized: "Allow it in a moment"),
                          lead: .symbol("exclamationmark.triangle", PanelColors.orange), trail: .chevron) { [unowned self] in
                    self.app.closePanel()
                    self.app.fixPermission(p, denied: state == .denied)
                },
            ])
        }
    }

    private func micSections() -> [PanelSection] {
        let off = MicChoice.off
        let locked = recording != nil
        let tracks = micTracks
        var out = [PanelSection(id: "mic", title: String(localized: "Microphone"), items: [
            PanelItem(id: "mic-on", title: String(localized: "Record the microphone"),
                      subtitle: off ? String(localized: "Off: no microphone track")
                          : tracks.count == 1 ? String(localized: "1 track")
                          : String(localized: "\(tracks.count) tracks · each microphone is its own track"),
                      lead: .symbol("mic"), trail: .toggle(!off), enabled: !locked) { [unowned self] in
                self.change { off ? MicChoice.turnOn() : MicChoice.turnOff() }
            },
        ])]
        out += warnings(.microphone)

        let defaultDevice = InputDevice.systemDefault
        func item(_ pick: MicPick, device: InputDevice?, title: String, subtitle: String?) -> PanelItem {
            let ticked = MicChoice.isTicked(pick.uid)
            var sub = subtitle
            var trail = PanelItem.Trail.none
            if locked {
                if ticked { trail = .meter(PanelLevels.key(pick.uid)) }
            } else if ticked, let device, device.channels > 1 {
                trail = .channels(device)
            }
            if ticked, let device, device.channels > 1 {
                let ch = InputChannels.saved(uid: device.uid, count: device.channels).title
                sub = sub.map { "\($0) · \(ch)" } ?? ch
            }
            return PanelItem(id: "dev-" + (pick.uid ?? "default"), title: title, subtitle: sub, lead: .check(ticked),
                             trail: trail, volume: ticked ? volume(TrackVolume.key(pick.uid)) : nil,
                             enabled: !locked) { [unowned self] in
                self.change { MicChoice.toggle(pick) }
            }
        }
        var items = [item(.systemDefault, device: defaultDevice, title: String(localized: "System default"),
                          subtitle: defaultDevice?.name ?? String(localized: "No microphone connected"))]
        let others = devices.filter { !$0.isMicrophone && !MicChoice.isTicked($0.uid) }
        for d in devices where !others.contains(d) {
            items.append(item(MicPick(uid: d.uid, name: d.name), device: d, title: d.name, subtitle: nil))
        }
        // ticked devices that aren't connected stay in the list, so they can be unticked
        for p in MicChoice.picks where !off && p.uid != nil && !devices.contains(where: { $0.uid == p.uid }) {
            items.append(item(p, device: nil, title: p.name ?? p.uid ?? "?", subtitle: String(localized: "Not connected")))
        }
        let more = others.isEmpty ? nil : PanelMore(
            title: String(localized: "Other devices"), open: showOthers, toggle: { [unowned self] in self.showOthers.toggle() },
            items: others.map { item(MicPick(uid: $0.uid, name: $0.name), device: $0, title: $0.name, subtitle: nil) })
        var foot: String? = locked ? nil : String(localized: "Applies to the next recording.")
        let stereo = MicChoice.active.contains { p in
            let d = p.uid == nil ? defaultDevice : devices.first { $0.uid == p.uid }
            return d.map { InputChannels.saved(uid: $0.uid, count: $0.channels) == .stereo } ?? false
        }
        if !locked, stereo, RecordingQuality.saved == .compact {
            foot = String(localized: "Compact records in mono: channels 1 and 2 are mixed together.")
        }
        out.append(PanelSection(id: "devices", title: String(localized: "Devices"),
                                note: locked ? String(localized: "Locked while recording") : String(localized: "Tick one or more"),
                                items: items, more: more, footnote: foot))
        return out
    }

    private func systemSections() -> [PanelSection] {
        let sys = SystemAudio.saved
        let locked = recording != nil
        let ticked = Set(sys.apps.map(\.bundleID))
        let summary: String
        switch sys {
        case .off: summary = String(localized: "Off: no system audio track")
        case .all: summary = String(localized: "All apps, on one track")
        case .apps(let a): summary = a.map(\.name).joined(separator: ", ")
        }
        var out = [PanelSection(id: "system", title: String(localized: "System audio"), items: [
            PanelItem(id: "system-on", title: String(localized: "Record system audio"), subtitle: summary,
                      lead: .symbol("speaker.wave.2"), trail: locked ? .meter(TrackVolume.system) : .toggle(sys != .off),
                      volume: sys == .off ? nil : volume(TrackVolume.system), enabled: !locked) { [unowned self] in
                self.change { SystemAudio.saved = sys == .off ? .all : .off }
            },
        ])]
        out += warnings(.systemAudio)
        var items = [PanelItem(id: "all", title: String(localized: "All apps"), lead: .radio(sys == .all), enabled: !locked) { [unowned self] in
            self.change { SystemAudio.saved = .all }
        }]
        for a in apps {
            items.append(PanelItem(id: "app-" + a.bundle, title: a.name, subtitle: a.note, lead: .check(ticked.contains(a.bundle)),
                                   appIcon: a.icon, enabled: !locked) { [unowned self] in
                self.change { SystemAudio.saved = SystemAudio.saved.toggling(PickedApp(bundleID: a.bundle, name: a.name)) }
            })
        }
        out.append(PanelSection(id: "apps", title: String(localized: "Apps"),
                                note: locked ? String(localized: "Locked while recording") : String(localized: "Apps making sound go first"),
                                items: items,
                                footnote: locked ? nil : String(localized: "Applies to the next recording. The ticked apps go on one track.")))
        return out
    }

    private func formatSections() -> [PanelSection] {
        let quality = RecordingQuality.saved
        let items = RecordingQuality.allCases.map { q in
            PanelItem(id: "quality-" + q.rawValue, title: q.title, subtitle: q.explanation, lead: .radio(q == quality)) { [unowned self] in
                self.change { RecordingQuality.saved = q }
            }
        }
        let n = trackCount
        let size = n == 0 ? String(localized: "Nothing to record")
            : String(localized: "≈ \(humanSize(bytesPerHour(quality, mics: micTracks, systemOn: SystemAudio.saved != .off))) per hour")
        return [
            PanelSection(id: "quality", title: String(localized: "Quality"),
                         note: recording != nil ? String(localized: "For the next recording") : nil, items: items),
            PanelSection(id: "next", title: String(localized: "Next recording"), items: [
                PanelItem(id: "tracks", title: String(localized: "Tracks"), lead: .symbol("rectangle.stack"), trail: .value("\(n)")),
                PanelItem(id: "size", title: String(localized: "Size"), lead: .symbol("internaldrive"), trail: .value(size)),
            ], footnote: String(localized: "No noise reduction and no automatic level: only the volume you set for each track.")),
        ]
    }

    /// Recordings that couldn't be transcribed: key and folder, newest first.
    var failed: [String] {
        Registry.recordings.filter { ["failed", "error"].contains($0.value["status"] as? String ?? "") }.keys.sorted(by: >)
    }

    private func transcriptionSections() -> [PanelSection] {
        let q = app.queue
        var items = [PanelItem(id: "auto", title: String(localized: "Transcribe automatically"),
                               subtitle: q.paused ? String(localized: "Paused · recording still works") : String(localized: "Right after each recording"),
                               lead: .symbol("bolt"), trail: .toggle(!q.paused)) { [unowned self] in
            if q.paused { self.app.resume() } else { self.app.pauseFromPanel() }
            self.refresh()
        }]
        if let s = queueRow() { items.append(s) }
        for key in failed.prefix(3) {
            items.append(PanelItem(id: "failed-" + key, title: String(localized: "Recording from \(recordingTitle(key))"),
                                   subtitle: String(localized: "Couldn't transcribe · details"),
                                   lead: .symbol("exclamationmark.circle", PanelColors.red), trail: .chevron) { [unowned self] in
                self.app.closePanel()
                self.app.showFailure(key)
            })
        }
        if failed.count > 3 {
            items.append(PanelItem(id: "failed-more", title: String(localized: "\(failed.count - 3) more failed"),
                                   lead: .symbol("ellipsis", PanelColors.red), trail: .chevron) { [unowned self] in
                self.app.closePanel()
                self.app.showSettings(tab: SettingsModel.Tab.transcripts)
            })
        }
        var out = [PanelSection(id: "transcription", title: String(localized: "Transcription"), items: items)]
        out += warnings(.notifications)

        let current = CallFolder.current
        let fallback = CallFolder.defaultFolder
        var folders = [PanelItem(id: "folder-default", title: folderTitle(fallback), lead: .radio(current == nil),
                                 trail: .value(String(localized: "Default"))) { [unowned self] in
            self.change { CallFolder.current = nil }
        }]
        for path in CallFolder.recent where path != fallback {
            folders.append(PanelItem(id: "folder-" + path, title: folderTitle(path), lead: .radio(current == path)) { [unowned self] in
                self.change { CallFolder.current = path }
            })
        }
        folders.append(PanelItem(id: "folder-choose", title: String(localized: "Choose Folder…"), lead: .symbol("folder.badge.plus"),
                                 accentTitle: true) { [unowned self] in
            self.app.closePanel()
            self.app.pickCallFolder()
        })
        out.append(PanelSection(id: "folders", title: String(localized: "Save to"),
                                note: recording != nil ? String(localized: "For this recording") : nil, items: folders))

        let s = app.settings
        out.append(PanelSection(id: "names", title: String(localized: "Names"), items: [
            PanelItem(id: "me", title: String(localized: "You"), lead: .symbol("mic"),
                      trail: .field(Binding(get: { s.me }, set: { s.me = $0 }), SettingsModel.defaultMe)),
            PanelItem(id: "other", title: String(localized: "Others"), lead: .symbol("person.2"),
                      trail: .field(Binding(get: { s.other }, set: { s.other = $0 }), SettingsModel.defaultOther)),
        ], footnote: String(localized: "How the microphone and the other side are labeled in transcripts.")))
        return out
    }

    /// What transcription is doing right now, as one row, or nil when there's nothing to say.
    private func queueRow() -> PanelItem? {
        let q = app.queue
        let waiting = q.waiting
        let more = waiting > 0 ? String(localized: "Waiting: \(waiting)") : nil
        let symbol = PanelItem.Lead.symbol("arrow.triangle.2.circlepath")
        var title: String?
        var progress: Double?
        switch q.phase {
        case .transcribing(let f):
            if let key = q.current?.key {
                title = q.current?.force == true ? String(localized: "Retranscribing: recording from \(recordingTitle(key))")
                                                 : String(localized: "Recording from \(recordingTitle(key))")
            } else {
                title = String(localized: "Transcribing…")
            }
            progress = f
        case .downloading(let f):
            title = String(localized: "Downloading speech model…")
            progress = f
        case .preparing: title = String(localized: "Getting the speech model ready…")
        case .names: title = String(localized: "Updating speaker names…")
        case .paused, .idle:
            if let problem = q.modelsProblem, waiting > 0 {
                return PanelItem(id: "status", title: String(localized: "Waiting for the speech models"), subtitle: problem,
                                 lead: .symbol("clock", PanelColors.orange))
            }
            if case .downloading(let f) = ModelStore.shared.activity {
                title = String(localized: "Downloading speech models…")
                progress = f
            } else if case .preparing = ModelStore.shared.activity {
                title = String(localized: "Getting the speech model ready…")
            } else if waiting > 0 {
                return PanelItem(id: "status", title: String(localized: "Waiting: \(waiting)"), lead: .symbol("clock"))
            }
        }
        guard let title else { return nil }
        return PanelItem(id: "status", title: title, subtitle: more, lead: symbol,
                         trail: progress.map { .value("\(Int($0 * 100)) %") } ?? .none, progress: progress)
    }

    // ---------- apps for system audio ----------

    /// Running apps: the ones making sound go first, with a note; ticked apps that aren't running stay, at the top.
    private func audioApps() -> [AudioApp] {
        var busy: [String: String] = [:]
        for p in audioProcesses() where p.input || p.output {
            guard let b = ownerApp(p)?.bundleIdentifier else { continue }
            busy[b] = p.input ? String(localized: "Using the mic") : (busy[b] ?? String(localized: "Playing"))
        }
        var list = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }.map { AudioApp(bundle: $0.bundleIdentifier!, name: $0.localizedName ?? $0.bundleIdentifier!, icon: $0.icon, note: busy[$0.bundleIdentifier!]) }
        list.sort { ($0.note == nil ? 1 : 0, $0.name.lowercased()) < ($1.note == nil ? 1 : 0, $1.name.lowercased()) }
        for a in SystemAudio.saved.apps.reversed() where !list.contains(where: { $0.bundle == a.bundleID }) {
            list.insert(AudioApp(bundle: a.bundleID, name: a.name, icon: nil, note: String(localized: "Not running")), at: 0)
        }
        return list
    }

    // ---------- for testing: --dump and --click ----------

    /// Everything the panel shows, tab by tab, as text.
    func dump() -> String {
        var lines = [Identity.appName + " · " + status.text, "Record: " + record.title + " · " + record.note + (record.canRecord ? "" : "   (inactive)")]
        for t in Tab.allCases {
            lines.append("")
            lines.append("== " + t.title + (needsAttention(t) ? " •" : ""))
            for s in sections(t) {
                lines.append(s.warning ? "  ⚠︎" : "  " + s.title.uppercased() + (s.note.map { "   (\($0))" } ?? ""))
                for i in s.items { lines.append("    " + i.dumpLine) }
                if let m = s.more {
                    lines.append("    ▸ \(m.title) (\(m.items.count))")
                    for i in m.items { lines.append("        " + i.dumpLine) }
                }
                if let f = s.footnote { lines.append("    · " + f) }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// "Record", or "Tab/Row": a row's title or its start, in that tab — as a click on it; "Tab/Row=PERCENT" — moves
    /// the row's volume slider there. false if there's no such row, or it's inactive, or it has no slider.
    func click(_ path: String) -> Bool {
        if path == "Record" || path == "Stop" { recordClicked(); return true }
        var parts = path.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let t = Tab.allCases.first(where: { $0.title == parts[0] }) else { return false }
        var percent: Double?
        if let eq = parts[1].lastIndex(of: "="), let v = Double(parts[1][parts[1].index(after: eq)...]) {
            percent = v
            parts[1] = String(parts[1][..<eq])
        }
        let items = sections(t).flatMap { $0.items + ($0.more?.items ?? []) }
        guard let it = items.first(where: { $0.title == parts[1] }) ?? items.first(where: { $0.title.hasPrefix(parts[1]) })
        else { return false }
        if let percent {
            guard let v = it.volume else { return false }
            v.set(min(TrackVolume.range.upperBound, max(TrackVolume.range.lowerBound, percent / 100)))
            return true
        }
        guard it.enabled, let action = it.action else { return false }
        action()
        return true
    }
}

// ---------- drawing ----------

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var settings: SettingsModel
    /// Drawn into an image (--panel-png): the popover's own background isn't there, so the panel paints one.
    var opaque = false

    @State private var contentHeight: CGFloat = 300

    private typealias M = PanelMetrics

    /// The tab's part of the panel stops growing here: the screen minus the header, Record, tabs, footer and a margin.
    private var maxContent: CGFloat { (NSScreen.main?.visibleFrame.height ?? 800) - 260 }

    var body: some View {
        VStack(spacing: M.gap) {
            header
            recordButton
            tabBar
            // a long list (many apps running) scrolls instead of growing past the screen
            ScrollView {
                VStack(spacing: M.gap) {
                    ForEach(model.sections(model.tab)) { PanelSectionView(section: $0, levels: model.levels) }
                }
                .background(GeometryReader { Color.clear.preference(key: ContentHeight.self, value: $0.size.height) })
            }
            .scrollIndicators(.automatic)
            .frame(height: min(contentHeight, maxContent))
            .onPreferenceChange(ContentHeight.self) { contentHeight = $0 }
            footer
        }
        .padding(M.inset)
        .frame(width: M.width)
        .foregroundStyle(PanelColors.text)
        .font(.system(size: M.titleSize))
        .background(opaque ? Color(white: 0.12) : Color.clear)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        ZStack {
            KoeWordmark(color: .white).frame(width: 46, height: 24)
            HStack {
                Spacer()
                let s = model.status
                HStack(spacing: 6) {
                    Circle().fill(s.color).frame(width: 6, height: 6)
                    Text(s.text).font(.system(size: M.smallSize)).monospacedDigit()
                }
                .foregroundStyle(s.color)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(s.color.opacity(0.15)))
            }
        }
        .frame(height: M.header)
    }

    private var recordButton: some View {
        let r = model.record
        let recording = model.recording != nil
        // green to start, red to stop, gray when there's nothing to record
        let tint: Color? = recording ? PanelColors.red : r.canRecord ? PanelColors.green : nil
        return Button { model.recordClicked() } label: {
            HStack(spacing: 10) {
                if recording {
                    RoundedRectangle(cornerRadius: 3).fill(.white).frame(width: 12, height: 12)
                } else {
                    Circle().fill(r.canRecord ? PanelColors.green : PanelColors.secondary).frame(width: 12, height: 12)
                }
                Text(r.title).font(.system(size: M.titleSize, weight: .semibold))
                Spacer(minLength: 8)
                Text(r.note)
                    .font(.system(size: recording ? M.titleSize : M.smallSize))
                    .monospacedDigit()
                    .foregroundStyle(recording ? PanelColors.text : PanelColors.secondary)
            }
            .padding(.horizontal, M.rowH)
            .frame(height: M.record)
            .background(RoundedRectangle(cornerRadius: M.buttonRadius)
                .fill(tint.map { $0.opacity(recording ? 0.30 : 0.15) } ?? Color.white.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: M.buttonRadius)
                .strokeBorder(tint.map { $0.opacity(recording ? 0.55 : 0.35) } ?? Color.white.opacity(0.16), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: M.buttonRadius))
            .opacity(r.canRecord ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .help(r.canRecord ? "" : String(localized: "Turn on the microphone or system audio"))
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(PanelModel.Tab.allCases, id: \.self) { t in
                let active = model.tab == t
                Button { model.tab = t } label: {
                    Image(systemName: t.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: M.tab)
                        .overlay(alignment: .topTrailing) {
                            if model.needsAttention(t) {
                                Circle().fill(PanelColors.orange).frame(width: 6, height: 6).offset(x: -18, y: 6)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: M.buttonRadius))
                }
                .buttonStyle(.plain)
                .foregroundStyle(active ? PanelColors.accent : PanelColors.secondary)
                .background(RoundedRectangle(cornerRadius: M.buttonRadius).fill(active ? PanelColors.accent.opacity(0.22) : .clear))
                .help(t.title)
                .accessibilityLabel(t.title)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(M.tabPadding)
        .background(RoundedRectangle(cornerRadius: M.cardRadius).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: M.cardRadius).strokeBorder(PanelColors.border, lineWidth: 1))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            footerButton(String(localized: "Transcripts"), "folder") { model.app.closePanel(); model.app.openMeetings() }
            footerButton(String(localized: "Settings"), "gearshape") { model.app.closePanel(); model.app.openSettings() }
            footerButton(String(localized: "Quit"), "power") { model.app.quit() }
        }
    }

    private func footerButton(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(title).font(.system(size: 12))
            }
            .frame(maxWidth: .infinity)
            .frame(height: M.footer)
            .contentShape(RoundedRectangle(cornerRadius: M.buttonRadius))
        }
        .buttonStyle(PanelPressStyle(radius: M.buttonRadius, fill: PanelColors.card, border: PanelColors.border))
        .foregroundStyle(Color.white.opacity(0.7))
    }
}

private struct ContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PanelSectionView: View {
    let section: PanelSection
    let levels: PanelLevels

    private typealias M = PanelMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: M.headerGap) {
            if !section.warning { SectionHeader(title: section.title, note: section.note) }
            card(section.items)
            if let more = section.more {
                Button(action: more.toggle) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(more.open ? 90 : 0))
                        Text(more.title.uppercased()).tracking(0.6)
                        Spacer()
                        Text("\(more.items.count)").foregroundStyle(PanelColors.accent)
                    }
                    .font(.system(size: M.smallSize, weight: .semibold))
                    .foregroundStyle(PanelColors.secondary)
                    .frame(height: M.line)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if more.open { card(more.items) }
            }
            if let f = section.footnote {
                Text(f).font(.system(size: M.smallSize)).foregroundStyle(Color.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func card(_ items: [PanelItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                PanelRow(item: item, levels: levels)
                    .overlay(alignment: .top) {
                        if i > 0 {
                            Rectangle().fill(PanelColors.separator).frame(height: 1).padding(.leading, M.textLead)
                        }
                    }
            }
        }
        .background(RoundedRectangle(cornerRadius: M.cardRadius).fill(section.warning ? PanelColors.orange.opacity(0.12) : PanelColors.card))
        .overlay(RoundedRectangle(cornerRadius: M.cardRadius)
            .strokeBorder(section.warning ? PanelColors.orange.opacity(0.35) : PanelColors.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: M.cardRadius))
    }
}

struct SectionHeader: View {
    let title: String
    let note: String?

    var body: some View {
        HStack {
            Text(title.uppercased()).font(.system(size: PanelMetrics.smallSize, weight: .semibold)).tracking(0.6)
            Spacer()
            if let note { Text(note).font(.system(size: PanelMetrics.smallSize)) }
        }
        .foregroundStyle(PanelColors.secondary)
        .frame(height: PanelMetrics.line)
        .padding(.horizontal, 4)
    }
}

/// A row: the icon column, the text (title, subtitle, a progress bar), and the control on the right. Everything lines
/// up with the title line, not with the middle of the row.
struct PanelRow: View {
    let item: PanelItem
    let levels: PanelLevels

    private typealias M = PanelMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                if let action = item.action {
                    Button(action: action) { main.contentShape(Rectangle()) }
                        .buttonStyle(PanelPressStyle(radius: 0, fill: .clear, border: .clear))
                        .disabled(!item.enabled)
                } else {
                    main
                }
                trail.frame(minHeight: M.line).padding(.vertical, M.rowV).padding(.trailing, M.rowH)
            }
            .opacity(item.enabled ? 1 : 0.55)
            // apart from the row's button, so it can be dragged, and not dimmed: it works while the row is locked
            if let v = item.volume {
                VolumeSlider(volume: v)
                    .padding(.leading, M.textLead)
                    .padding(.trailing, M.rowH)
                    .padding(.top, M.controlGap - M.rowV)
                    .padding(.bottom, M.rowV)
            }
        }
    }

    private var main: some View {
        HStack(alignment: .top, spacing: M.iconGap) {
            lead.frame(width: M.icon, height: M.line)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    if let icon = item.appIcon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                    Text(item.title)
                        .font(.system(size: M.titleSize, weight: item.accentTitle ? .regular : .semibold))
                        .foregroundStyle(item.accentTitle ? PanelColors.accent : PanelColors.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(minHeight: M.line)
                if let s = item.subtitle {
                    Text(s).font(.system(size: M.smallSize)).foregroundStyle(PanelColors.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, M.lineGap)
                        .padding(.leading, item.appIcon == nil ? 0 : 24)
                }
                if let p = item.progress {
                    ProgressBar(value: p).padding(.top, M.controlGap)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, M.rowH)
        .padding(.trailing, 8)
        .padding(.vertical, M.rowV)
    }

    @ViewBuilder private var lead: some View {
        switch item.lead {
        case .symbol(let name, let color):
            Image(systemName: name).font(.system(size: 14)).foregroundStyle(color)
        case .check(let on):
            RoundedRectangle(cornerRadius: 4)
                .fill(on ? PanelColors.accent : .clear)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? PanelColors.accent : Color.white.opacity(0.3), lineWidth: 1))
                .overlay { if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) } }
                .frame(width: 16, height: 16)
                .accessibilityAddTraits(on ? .isSelected : [])
        case .radio(let on):
            Circle()
                .fill(on ? PanelColors.accent : .clear)
                .overlay(Circle().strokeBorder(on ? PanelColors.accent : Color.white.opacity(0.3), lineWidth: 1))
                .overlay { if on { Circle().fill(.white).frame(width: 6, height: 6) } }
                .frame(width: 16, height: 16)
                .accessibilityAddTraits(on ? .isSelected : [])
        }
    }

    @ViewBuilder private var trail: some View {
        switch item.trail {
        case .none: EmptyView()
        case .toggle(let on):
            Switch(on: on).disabled(!item.enabled).onTapGesture { if item.enabled { item.action?() } }
        case .value(let v):
            Text(v).font(.system(size: M.smallSize)).monospacedDigit().foregroundStyle(Color.white.opacity(0.55))
        case .chevron:
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.white.opacity(0.35))
        case .channels(let d):
            ChannelsMenu(device: d)
        case .meter(let key):
            LevelBars(levels: levels, key: key)
        case .field(let text, let placeholder):
            TextField("", text: text, prompt: Text(verbatim: placeholder).foregroundStyle(Color.white.opacity(0.35)))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .frame(width: 128, height: 22)
                .background(RoundedRectangle(cornerRadius: M.smallRadius).fill(Color.black.opacity(0.25)))
                .overlay(RoundedRectangle(cornerRadius: M.smallRadius).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                .padding(.vertical, -3)   // 22 high, but it takes the title line's 16, like the other controls
        }
    }
}

/// A switch drawn to the panel's sizes (32×18); the row's click toggles it.
struct Switch: View {
    let on: Bool

    var body: some View {
        Capsule()
            .fill(on ? PanelColors.accent : Color.white.opacity(0.2))
            .frame(width: 32, height: 18)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 14, height: 14).padding(2)
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(on ? Text("On") : Text("Off"))
    }
}

struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(PanelColors.accent).frame(width: g.size.width * max(0, min(1, value)))
            }
        }
        .frame(height: 4)
    }
}

/// Koe's volume of a track, 0–200 %: a speaker, the slider and the value, from where the row's text starts. 100 % is
/// in the middle, marked, and the knob sticks to it; above 100 % the slider is orange (loud parts can be cut).
/// A click on the value puts it back to 100 %.
struct VolumeSlider: View {
    let volume: PanelVolume
    @State private var value: Double

    init(volume: PanelVolume) {
        self.volume = volume
        _value = State(initialValue: TrackVolume.get(volume.key))
    }

    private typealias M = PanelMetrics

    var body: some View {
        let loud = value > 1
        let tint = loud ? PanelColors.orange : PanelColors.accent
        HStack(spacing: 8) {
            Image(systemName: value == 0 ? "speaker.slash" : "speaker.wave.2")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.45))
                .frame(width: 16)
            GeometryReader { g in
                let w = g.size.width
                let x = w * value / TrackVolume.range.upperBound
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12)).frame(height: 4)
                    Capsule().fill(tint).frame(width: x, height: 4)
                    Rectangle().fill(Color.white.opacity(0.35)).frame(width: 1, height: 8).offset(x: w / 2)
                    Circle().fill(.white).frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                        .offset(x: x - 7)
                }
                .frame(width: w, height: M.line)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { set($0.location.x / w * TrackVolume.range.upperBound) })
            }
            .frame(height: M.line)
            Text(TrackVolume.percent(value))
                .font(.system(size: M.smallSize))
                .monospacedDigit()
                .foregroundStyle(loud ? PanelColors.orange : Color.white.opacity(0.55))
                .frame(width: 40, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture { set(1) }
                .help(String(localized: "Back to 100 %"))
        }
        .frame(height: M.line)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Volume"))
        .accessibilityValue(Text(verbatim: TrackVolume.percent(value)))
        .accessibilityAdjustableAction { d in
            switch d {
            case .increment: set(value + 0.1)
            case .decrement: set(value - 0.1)
            @unknown default: break
            }
        }
    }

    private func set(_ v: Double) {
        var v = (min(TrackVolume.range.upperBound, max(TrackVolume.range.lowerBound, v)) * 100).rounded() / 100
        if abs(v - 1) < 0.04 { v = 1 }   // 100 % — the sound as is — is easy to hit
        guard v != value else { return }
        value = v
        volume.set(v)
    }
}

/// Five bars: how loud a track is right now.
struct LevelBars: View {
    @ObservedObject var levels: PanelLevels
    let key: String

    var body: some View {
        let lit = Int(((levels.values[key] ?? 0) * 5).rounded())
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < lit ? PanelColors.green : Color.white.opacity(0.15))
                    .frame(width: 3, height: CGFloat(4 + 2 * i))
            }
        }
        .frame(height: 12)
        .padding(.top, 2)
    }
}

/// Input channels of a device with several inputs, as a small pop-up menu on its row.
struct ChannelsMenu: View {
    let device: InputDevice

    var body: some View {
        let current = InputChannels.saved(uid: device.uid, count: device.channels)
        Menu {
            ForEach(InputChannels.options(count: device.channels), id: \.self) { c in
                Button {
                    InputChannels.save(c, uid: device.uid)
                } label: {
                    if c == current { Label(c.title, systemImage: "checkmark") } else { Text(c.title) }
                }
            }
        } label: {
            Text(current.shortTitle).font(.system(size: PanelMetrics.smallSize))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: PanelMetrics.smallRadius).fill(Color.white.opacity(0.10)))
        .padding(.top, -2)
        .help(String(localized: "Input channels"))
    }
}

extension InputChannels {
    /// For the small pop-up menu on a row.
    var shortTitle: String {
        switch self {
        case .mix: String(localized: "Mono")
        case .stereo: String(localized: "Stereo")
        case .channel(let n): String(localized: "Ch \(n + 1)")
        case .each: String(localized: "Each")
        }
    }
}

/// Buttons in the panel: a light fill on hover and while pressed.
struct PanelPressStyle: ButtonStyle {
    let radius: CGFloat
    let fill: Color
    let border: Color

    func makeBody(configuration: Configuration) -> some View {
        Hovered(radius: radius, fill: fill, border: border, pressed: configuration.isPressed) { configuration.label }
    }

    private struct Hovered<Label: View>: View {
        let radius: CGFloat
        let fill: Color
        let border: Color
        let pressed: Bool
        @ViewBuilder let label: () -> Label
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            label()
                .background(RoundedRectangle(cornerRadius: radius).fill(fill))
                .background(RoundedRectangle(cornerRadius: radius).fill(enabled && (hover || pressed) ? PanelColors.hover : .clear))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(border, lineWidth: 1))
                .onHover { hover = $0 }
        }
    }
}
