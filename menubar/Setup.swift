// The setup window: from opening the app to the first recording without a terminal.
//
// Steps: what Koe does → the microphone (permission and a level meter) → system audio (why, the permission and a
// check that it works) → notifications → the transcripts folder → your name → the speech models (sizes, progress,
// can go on in the background) → "Koe lives in the menu bar". Any step can be skipped; a permission that isn't given
// reminds of itself with a line in the menu (App.permissionWarnings).
//
// It opens at launch until setup is finished once (setupDone in the app's defaults), and again from
// Settings → Set Up Again…, or from a menu warning at its step. Closing the window midway doesn't finish setup, but
// a model download keeps going: it belongs to ModelStore, not to the window.
//
// In the style of the logo (koe-logo/README.md): paper and ink, the water ring, light type.
import AppKit
import ServiceManagement
import SwiftUI

extension Color {
    /// The logo's colors: ink on paper (#1A1A1C on #EFEBE3), in dark mode the ring's light ink on near-black.
    static let ink = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.949, green: 0.937, blue: 0.910, alpha: 1)
                                                          : NSColor(srgbRed: 0.102, green: 0.102, blue: 0.110, alpha: 1)
    })
    static let paper = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0.110, green: 0.110, blue: 0.118, alpha: 1)
                                                          : NSColor(srgbRed: 0.937, green: 0.922, blue: 0.890, alpha: 1)
    })
}

@MainActor
final class SetupModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome, microphone, systemAudio, notifications, folder, name, models, done
    }

    /// The system audio check (SystemAudioCheck): not done yet, going, the sound came through, only silence.
    enum Check { case notChecked, checking, heard, silent }

    /// Setup was finished once: the window doesn't open by itself any more.
    static var done: Bool {
        get { UserDefaults.standard.bool(forKey: "setupDone") }
        set { UserDefaults.standard.set(newValue, forKey: "setupDone") }
    }

    @Published var step: Step = .welcome { didSet { if step != oldValue { stepChanged() } } }
    @Published private(set) var mic: PermissionState = .unknown
    @Published private(set) var system: PermissionState = .unknown
    @Published private(set) var check: Check = .notChecked
    @Published private(set) var notifications: PermissionState = .unknown
    @Published var atLogin = false
    /// The intro (ring → wordmark) plays when the window opens at the first step.
    @Published var intro = false
    let level = MicLevel()
    let settings: SettingsModel
    weak var window: NSWindow?
    /// For drawing the window from the command line (--setup-png): no permissions are asked, nothing starts.
    var readOnly = false
    private var poll: Timer?

    init(settings: SettingsModel) {
        self.settings = settings
    }

    /// The window opened (at a step): read everything fresh, and keep the permissions fresh while it's open —
    /// they may be changed in System Settings meanwhile.
    func opened(at step: Step) {
        settings.load()
        if !readOnly && !(window?.isVisible ?? false) { intro = step == .welcome }
        self.step = step
        refresh()
        stepChanged()
        guard !readOnly else { return }
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { self.refresh() } }
    }

    func closed() {
        poll?.invalidate()
        poll = nil
        level.stop()
        if !readOnly { settings.flush() }
        if step == .done { finish(close: false) }
    }

    func refresh() {
        let wasMic = mic, wasSystem = system
        mic = Permissions.microphone
        system = Permissions.systemAudio
        atLogin = SMAppService.mainApp.status == .enabled
        Permissions.refreshNotifications { self.notifications = $0 }
        if step == .microphone && mic == .allowed && wasMic != .allowed { level.start() }
        // turned on in System Settings after a silent check — check again, so the ✓ is real
        if step == .systemAudio && system == .allowed && wasSystem != .allowed && check == .silent { checkSystemAudio() }
    }

    private func stepChanged() {
        if step == .microphone && !readOnly { level.start() } else { level.stop() }
    }

    // ---------- moving between steps ----------

    var isFirst: Bool { step == .welcome }

    func next() {
        if step == .folder { makeFolder() }
        if let n = Step(rawValue: step.rawValue + 1) { step = n }
    }

    func back() {
        if let p = Step(rawValue: step.rawValue - 1) { step = p }
    }

    /// The step's own action is done, so the button says Continue rather than Skip.
    var stepDone: Bool {
        switch step {
        case .microphone: mic == .allowed
        case .systemAudio: check == .heard
        case .notifications: notifications == .allowed
        case .models: ModelStore.shared.missingRequired.isEmpty
        default: true
        }
    }

    func finish(close: Bool = true) {
        if !Self.done { recLog("setup finished; not set up: \(skipped.isEmpty ? "nothing" : skipped.joined(separator: ", "))") }
        Self.done = true
        if close { window?.close() }
    }

    // ---------- the steps' actions ----------

    func askMicrophone() {
        if mic == .denied { Permission.microphone.openSettings(); return }
        withMicAccess { _ in self.refresh() }
    }

    func checkSystemAudio() {
        guard check != .checking else { return }
        check = .checking
        SystemAudioCheck.run { heard in
            self.check = heard ? .heard : .silent
            self.refresh()
        }
    }

    func askNotifications() {
        if notifications == .denied { Permission.notifications.openSettings(); return }
        Permissions.askNotifications { self.notifications = $0 }
    }

    func pickFolder() {
        chooseFolder(String(localized: "Where should transcripts go?"), start: settings.meetingsFolder, in: window) {
            self.settings.meetingsFolder = $0
        }
    }

    /// The folder is made right away, so if macOS asks about Documents, it asks now, while the text explains why.
    private func makeFolder() {
        guard !readOnly else { return }
        try? FileManager.default.createDirectory(atPath: settings.meetingsFolder, withIntermediateDirectories: true)
    }

    func setAtLogin(_ on: Bool) {
        atLogin = on
        guard !readOnly else { return }
        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        atLogin = SMAppService.mainApp.status == .enabled
    }

    /// What was skipped, for the last step: "system audio, notifications".
    var skipped: [String] {
        var out: [String] = []
        if mic != .allowed { out.append(String(localized: "the microphone")) }
        if system == .denied || system == .notAsked || (system == .unknown && check != .heard) { out.append(String(localized: "system audio")) }
        if notifications != .allowed { out.append(String(localized: "notifications")) }
        return out
    }
}

// ---------- the window ----------

struct SetupView: View {
    @ObservedObject var model: SetupModel
    @ObservedObject var settings: SettingsModel
    @ObservedObject var store = ModelStore.shared
    @ObservedObject var level: MicLevel

    /// The setup window is always dark, whatever the system's appearance: light ink on near-black, like the intro.
    static let appearance = NSAppearance(named: .darkAqua)

    init(model: SetupModel) {
        self.model = model
        settings = model.settings
        level = model.level
    }

    var body: some View {
        ZStack {
            steps.opacity(model.intro ? 0 : 1)
            if model.intro {
                IntroView { withAnimation(.easeInOut(duration: 0.7)) { model.intro = false } }
                    .transition(.opacity)
            }
        }
        .frame(width: 660, height: 540)
        .background(Color.paper)
        .foregroundStyle(Color.ink)
        .tint(Color.ink)
    }

    var steps: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 36) {
                RingView(motion: ringMotion)
                    .frame(width: 112, height: 112)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 44)
            .padding(.top, 52)
            Spacer(minLength: 0)
            footer
        }
    }

    /// The ring flows on every step, and on the microphone step it moves with your voice.
    var ringMotion: RingView.Motion {
        model.step == .microphone && level.running ? .level(level.level) : .flow
    }

    @ViewBuilder var content: some View {
        switch model.step {
        case .welcome: welcome
        case .microphone: microphone
        case .systemAudio: systemAudio
        case .notifications: notifications
        case .folder: folder
        case .name: name
        case .models: models
        case .done: done
        }
    }

    func title(_ s: String) -> some View {
        Text(s).font(.system(size: 28, weight: .light)).fixedSize(horizontal: false, vertical: true)
    }

    func para(_ s: String) -> some View {
        Text(s).font(.system(size: 14)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }

    func note(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(Color.ink.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
    }

    func ok(_ s: String) -> some View {
        Label(s, systemImage: "checkmark.circle.fill").font(.system(size: 14, weight: .medium))
    }

    func problem(_ s: String) -> some View {
        Label(s, systemImage: "exclamationmark.triangle").font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
    }

    // ---------- steps ----------

    var welcome: some View {
        Group {
            title(String(localized: "Welcome"))
            para(String(localized: "\(Identity.appName) is a helpful tool to record your calls, podcasts, and everything else on your Mac. And turn it into text with timestamps."))
            VStack(alignment: .leading, spacing: 10) {
                bullet("lock", String(localized: "Everything stays on this Mac. No servers, no account, no tracking."))
                bullet("arrow.down.circle", String(localized: "It goes online only once: to download its speech models."))
                bullet("forward", String(localized: "Setup takes a minute. You can skip any step and come back to it later."))
            }
            .padding(.top, 6)
        }
    }

    func bullet(_ icon: String, _ s: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).frame(width: 18)
            para(s)
        }
    }

    var microphone: some View {
        Group {
            title(String(localized: "Your microphone"))
            para(String(localized: "\(Identity.appName) records your voice from the microphone. macOS will ask whether that's OK."))
            switch model.mic {
            case .allowed:
                ok(String(localized: "Microphone allowed"))
                VStack(alignment: .leading, spacing: 6) {
                    LevelBar(level: level.level).frame(height: 8)
                    note(level.running || model.readOnly ? String(localized: "Listening through: \(level.running ? level.device : DeviceInfo.input.name). Say something: the bar and the ring should move.")
                                                         : String(localized: "Couldn't open the microphone right now."))
                }
                .padding(.top, 4)
                note(String(localized: "To use another microphone, pick it later in the menu under Microphone."))
            case .denied:
                problem(String(localized: "\(Identity.appName) isn't allowed to use the microphone. Turn it on in System Settings → Privacy & Security → Microphone."))
                Button(String(localized: "Open System Settings")) { model.askMicrophone() }.buttonStyle(InkButton())
            default:
                Button(String(localized: "Allow Microphone")) { model.askMicrophone() }.buttonStyle(InkButton(prominent: true))
            }
        }
    }

    var systemAudio: some View {
        Group {
            title(String(localized: "Sound from other apps"))
            para(String(localized: "To hear the other people on a call, in Zoom, Telegram, FaceTime or your browser, \(Identity.appName) records the sound your Mac plays. macOS calls this permission Screen & System Audio Recording."))
            switch model.check {
            case .heard:
                ok(String(localized: "\(Identity.appName) can hear your Mac's sound"))
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    para(String(localized: "Checking… If macOS asks, click Allow."))
                }
            case .silent:
                problem(model.system == .denied
                        ? String(localized: "\(Identity.appName) isn't allowed to record system audio. Turn it on in System Settings → Privacy & Security → Screen & System Audio Recording, under System Audio Recording Only.")
                        : String(localized: "\(Identity.appName) didn't hear the test sound. If macOS asked, click Allow and check again. If it didn't ask, turn \(Identity.appName) on in System Settings → Privacy & Security → Screen & System Audio Recording."))
                HStack {
                    Button(String(localized: "Open System Settings")) { Permission.systemAudio.openSettings() }.buttonStyle(InkButton())
                    Button(String(localized: "Check Again")) { model.checkSystemAudio() }.buttonStyle(InkButton(prominent: true))
                }
            case .notChecked:
                Button(String(localized: "Allow System Audio")) { model.checkSystemAudio() }.buttonStyle(InkButton(prominent: true))
                note(String(localized: "You'll hear a short sound: that's \(Identity.appName) checking that it can hear your Mac."))
            }
        }
    }

    var notifications: some View {
        Group {
            title(String(localized: "Notifications"))
            para(String(localized: "\(Identity.appName) lets you know when a transcript is ready, and can offer to record when a call starts."))
            switch model.notifications {
            case .allowed:
                ok(String(localized: "Notifications are on"))
            case .denied:
                problem(String(localized: "Notifications are off for \(Identity.appName). Turn them on in System Settings → Notifications."))
                Button(String(localized: "Open System Settings")) { model.askNotifications() }.buttonStyle(InkButton())
            default:
                Button(String(localized: "Allow Notifications")) { model.askNotifications() }.buttonStyle(InkButton(prominent: true))
            }
        }
    }

    var folder: some View {
        Group {
            title(String(localized: "Where to keep transcripts"))
            para(String(localized: "Each recording gets its own folder: the transcript, and the audio next to it."))
            HStack(spacing: 10) {
                Image(systemName: "folder")
                Text(shortPath(settings.meetingsFolder)).font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Button(String(localized: "Change…")) { model.pickFolder() }.buttonStyle(InkButton())
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).stroke(Color.ink.opacity(0.25)))
            if settings.meetingsFolder.hasPrefix(home.appendingPathComponent("Documents").path) {
                note(String(localized: "If macOS asks whether \(Identity.appName) may use your Documents folder, click Allow: that's where the transcripts go."))
            }
            note(String(localized: "For a single recording you can pick another folder in the menu under Save to."))
        }
    }

    var name: some View {
        Group {
            title(String(localized: "Your name"))
            para(String(localized: "In transcripts, your lines from the microphone are labeled with this name. Other people are Speaker 1, Speaker 2…, and you can name them after a recording."))
            TextField(String(localized: "Name"), text: $settings.me, prompt: Text(verbatim: SettingsModel.defaultMe))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 15))
                .frame(width: 240)
            note(String(localized: "Example: [00:01:12] \(settings.me.trimmingCharacters(in: .whitespaces).isEmpty ? SettingsModel.defaultMe : settings.me.trimmingCharacters(in: .whitespaces)): Shall we start?"))
        }
    }

    var models: some View {
        let _ = store.revision
        let missing = store.missingRequired
        let total = SpeechModel.required.reduce(Int64(0)) { $0 + $1.size }
        return Group {
            title(String(localized: "Speech models"))
            para(String(localized: "\(Identity.appName) turns speech into text right on your Mac. For that it needs three models, a one-time download:"))
            VStack(spacing: 6) {
                ForEach(SpeechModel.required) { m in
                    HStack {
                        Image(systemName: m.isDownloaded ? "checkmark.circle.fill" : "circle").frame(width: 16)
                        Text(m.title).font(.system(size: 13))
                        Spacer()
                        Text(humanSize(Double(m.size))).font(.system(size: 13)).monospacedDigit().foregroundStyle(Color.ink.opacity(0.7))
                    }
                }
                Divider()
                HStack {
                    Text("Total").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text(humanSize(Double(total))).font(.system(size: 13, weight: .medium)).monospacedDigit()
                }
            }
            .frame(maxWidth: 360)
            if missing.isEmpty {
                ok(String(localized: "All set: the models are on this Mac"))
            } else if store.busy {
                VStack(alignment: .leading, spacing: 6) {
                    switch store.activity {
                    case .downloading(let f):
                        ProgressView(value: f ?? 0).frame(maxWidth: 360)
                        note(f.map { String(localized: "Downloading… \(Int($0 * 100)) %") } ?? String(localized: "Starting the download…"))
                    default:
                        ProgressView().frame(maxWidth: 360)
                        note(String(localized: "Getting the models ready for this Mac…"))
                    }
                    note(String(localized: "You can continue setup or close this window: the download goes on in the background."))
                }
            } else {
                if case .failed(let why) = store.activity { problem(why) }
                HStack(spacing: 12) {
                    Button(store.activity == .idle ? String(localized: "Download") : String(localized: "Try Again")) {
                        ModelStore.shared.download(SpeechModel.required)
                    }
                    .buttonStyle(InkButton(prominent: true))
                    if let free = freeDiskSpace() { note(String(localized: "\(humanSize(Double(free))) free on this Mac")) }
                }
                note(String(localized: "If you skip this, \(Identity.appName) downloads them the first time it transcribes something."))
            }
        }
    }

    var done: some View {
        Group {
            title(String(localized: "\(Identity.appName) lives in the menu bar"))
            para(String(localized: "Look for the ring at the top right of your screen. Click it to start a recording, choose microphones and apps, or open your transcripts."))
            MenuBarPicture().padding(.vertical, 4)
            Toggle(String(localized: "Open \(Identity.appName) at login"), isOn: Binding(get: { model.atLogin }, set: { model.setAtLogin($0) }))
                .toggleStyle(.checkbox)
            if store.busy {
                note(String(localized: "The speech models are still downloading. That goes on after you close this window."))
            }
            if !model.skipped.isEmpty {
                note(String(localized: "Not set up yet: \(model.skipped.joined(separator: ", ")). The menu will remind you."))
            }
        }
    }

    // ---------- the bottom row ----------

    var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                ForEach(SetupModel.Step.allCases, id: \.self) { s in
                    Circle().fill(Color.ink.opacity(s == model.step ? 0.9 : 0.2)).frame(width: 6, height: 6)
                }
            }
            Spacer()
            if !model.isFirst && model.step != .done {
                Button(String(localized: "Back")) { model.back() }.buttonStyle(InkButton(plain: true))
            }
            switch model.step {
            case .welcome:
                Button(String(localized: "Get Started")) { model.next() }.buttonStyle(InkButton(prominent: true)).keyboardShortcut(.defaultAction)
            case .done:
                Button(String(localized: "Done")) { model.finish() }.buttonStyle(InkButton(prominent: true)).keyboardShortcut(.defaultAction)
            case .models where store.busy:
                Button(String(localized: "Continue in Background")) { model.next() }.buttonStyle(InkButton(prominent: true))
            default:
                if model.stepDone {
                    Button(String(localized: "Continue")) { model.next() }.buttonStyle(InkButton(prominent: true)).keyboardShortcut(.defaultAction)
                } else {
                    Button(String(localized: "Skip")) { model.next() }.buttonStyle(InkButton())
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }
}

/// Buttons in ink: prominent — filled, the rest — outlined; plain — just the text.
struct InkButton: ButtonStyle {
    var prominent = false
    var plain = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: prominent ? .semibold : .regular))
            .padding(.horizontal, plain ? 6 : 16)
            .padding(.vertical, 7)
            .foregroundStyle(prominent ? Color.paper : Color.ink)
            .background {
                if prominent { Capsule().fill(Color.ink) }
                else if !plain { CapsuleOutline().fill(Color.ink.opacity(0.35), style: FillStyle(eoFill: true)) }
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// A 1-point capsule outline drawn as a filled ring: a stroked Capsule comes out broken at the sides when the window
/// is drawn into a picture (--setup-png).
struct CapsuleOutline: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(roundedRect: r, cornerRadius: r.height / 2)
        let i = r.insetBy(dx: 1, dy: 1)
        p.addRoundedRect(in: i, cornerSize: CGSize(width: i.height / 2, height: i.height / 2))
        return p
    }
}

/// The microphone's loudness, 0…1.
struct LevelBar: View {
    let level: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.ink.opacity(0.12))
                Capsule().fill(Color.ink).frame(width: max(4, g.size.width * level))
            }
        }
        .frame(maxWidth: 360)
        .animation(.linear(duration: 0.08), value: level)
    }
}

/// The water ring, drawn with the same code as in the menu bar (KoeRing): resting, flowing, or flowing with a level.
struct RingView: View {
    enum Motion: Equatable { case rest, flow, level(Double) }
    let motion: Motion
    @State private var state = RingState()

    final class RingState {
        let animator = KoeRing.Animator()
        var last: Double?
        let center = KoeRing.restCenter("icon")
    }

    var body: some View {
        TimelineView(.animation) { ctx in
            Canvas { gc, size in
                let s = state
                let now = ctx.date.timeIntervalSinceReferenceDate
                let dt = s.last.map { now - $0 } ?? 0
                s.last = now
                switch motion {
                case .rest: s.animator.setRecording(false)
                case .flow:
                    s.animator.setRecording(true)
                    s.animator.setLevel(0.35 + 0.15 * sin(now * 0.9))
                case .level(let l):
                    s.animator.setRecording(true)
                    s.animator.setLevel(l)
                }
                s.animator.tick(dt)
                let side = min(size.width, size.height)
                // cgPath draws for AppKit (Y up); the canvas has Y down
                let path = KoeRing.cgPath(s.animator.contours("icon", 24), size: side, center: s.center)
                let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: side)
                gc.fill(Path(path).applying(flip), with: .color(.ink), style: FillStyle(eoFill: true))
            }
        }
    }
}

/// A drawing of the top right corner of the screen with Koe's ring among the other icons.
struct MenuBarPicture: View {
    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 16) {
                Image(nsImage: KoeRing.restImage(preset: "menubar", size: 18, center: KoeRing.restCenter("menubar")))
                    .renderingMode(.template)
                    .padding(5)
                    .background(Circle().stroke(Color.ink, lineWidth: 1.5))
                    .overlay(alignment: .bottom) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up")
                            Text(verbatim: Identity.appName)
                        }
                        .font(.system(size: 12, weight: .medium))
                        .fixedSize()
                        .offset(y: 30)
                    }
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Image(systemName: "magnifyingglass")
                Image(systemName: "switch.2")
                Text(formatDate(Date(), "EEEjjmm")).font(.system(size: 13))
            }
            .font(.system(size: 14))
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.ink.opacity(0.07)))
        }
        .padding(.bottom, 24)
        .fixedSize()
    }
}
