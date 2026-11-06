// Whose audio goes on the system audio track, and how to notice that a call has started.
//
// Core Audio (macOS 14.2+) knows every process that has played or recorded audio: each has a
// pid, a bundle ID and "playing now" / "recording from the mic now" flags. Audio from browsers and
// Electron apps comes from helper processes (Google Chrome Helper, com.apple.WebKit.WebContent for
// Safari), so a process is attributed to the app that is "responsible" for it in the system — the
// same app macOS asks for microphone permission.
import AppKit
import CoreAudio
import UserNotifications

struct AudioProcess {
    let id: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let input: Bool    // recording from the mic right now
    let output: Bool   // playing audio right now
}

private func readUInt32(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var addr = propertyAddress(selector)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

func audioProcesses() -> [AudioProcess] {
    let sys = AudioObjectID(kAudioObjectSystemObject)
    var addr = propertyAddress(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).compactMap { id in
        guard let pid = readUInt32(id, kAudioProcessPropertyPID).map({ pid_t(bitPattern: $0) }), pid > 0 else { return nil }
        let bundle = deviceString(id, kAudioProcessPropertyBundleID)
        return AudioProcess(id: id, pid: pid, bundleID: bundle == "?" ? "" : bundle,
                            input: readUInt32(id, kAudioProcessPropertyIsRunningInput) == 1,
                            output: readUInt32(id, kAudioProcessPropertyIsRunningOutput) == 1)
    }
}

// The "responsible" process is an undocumented but long-standing libsystem function; if it's missing, we do without it
private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
private let responsibleFn: ResponsibleFn? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), // RTLD_DEFAULT
                                                  "responsibility_get_pid_responsible_for_pid")
    .map { unsafeBitCast($0, to: ResponsibleFn.self) }

/// The windowed app (one in the Dock) an audio process belongs to; nil means a system service.
func ownerApp(_ p: AudioProcess) -> NSRunningApplication? {
    for pid in [responsibleFn?(p.pid) ?? -1, p.pid] where pid > 0 {
        if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular { return app }
    }
    // fallback: "com.google.Chrome.helper" → "com.google.Chrome"
    guard !p.bundleID.isEmpty else { return nil }
    return NSWorkspace.shared.runningApplications.first {
        $0.activationPolicy == .regular && ($0.bundleIdentifier.map { p.bundleID.hasPrefix($0 + ".") } ?? false)
    }
}

/// Audio processes of these apps (helpers included).
func audioProcessIDs(of bundleIDs: [String]) -> [AudioObjectID] {
    let wanted = Set(bundleIDs)
    return audioProcesses().filter { p in
        wanted.contains(p.bundleID) || bundleIDs.contains { p.bundleID.hasPrefix($0 + ".") }
            || ownerApp(p)?.bundleIdentifier.map(wanted.contains) == true
    }.map(\.id)
}

/// "Zoom", "Zoom or Telegram", "Zoom, Telegram or Safari".
func orList(_ names: [String]) -> String {
    guard let last = names.last else { return "" }
    guard names.count > 1 else { return last }
    return String(localized: "\(names.dropLast().joined(separator: ", ")) or \(last)")
}

// ---------- what goes on the system audio track ----------

/// An app ticked under System audio. The name is kept to show it while the app isn't running.
struct PickedApp: Equatable {
    let bundleID: String
    let name: String
}

/// Whose audio goes on the system track: none, all of it, or the ticked apps' (mixed into one track).
/// The choice is kept in the app's defaults and applies to the next recording.
enum SystemAudio: Equatable {
    case off
    case all
    case apps([PickedApp])   // never empty: unticking the last app turns system audio off

    static var saved: SystemAudio {
        get {
            let d = UserDefaults.standard
            switch d.string(forKey: "systemAudio") {
            case "off": return .off
            case "all": return .all
            case "apps":
                let apps = (d.array(forKey: "systemApps") as? [[String: String]] ?? []).compactMap { a in
                    a["bundle_id"].map { PickedApp(bundleID: $0, name: a["name"] ?? $0) }
                }
                return apps.isEmpty ? .off : .apps(apps)
            default:
                // before stage 4 there was one app or all system audio
                guard let b = d.string(forKey: "sourceBundleID") else { return .all }
                return .apps([PickedApp(bundleID: b, name: d.string(forKey: "sourceName") ?? b)])
            }
        }
        set {
            let d = UserDefaults.standard
            d.set(newValue.key, forKey: "systemAudio")
            d.set(newValue.apps.map { ["bundle_id": $0.bundleID, "name": $0.name] }, forKey: "systemApps")
            d.removeObject(forKey: "sourceBundleID")
            d.removeObject(forKey: "sourceName")
        }
    }

    var key: String {
        switch self {
        case .off: "off"
        case .all: "all"
        case .apps: "apps"
        }
    }

    var apps: [PickedApp] {
        if case .apps(let a) = self { return a }
        return []
    }

    /// Tick or untick an app. Ticking one under Off or All system audio means "only the ticked apps";
    /// unticking the last one turns system audio off.
    func toggling(_ app: PickedApp) -> SystemAudio {
        var list = apps
        if let i = list.firstIndex(where: { $0.bundleID == app.bundleID }) {
            list.remove(at: i)
        } else {
            list.append(app)
        }
        return list.isEmpty ? .off : .apps(list)
    }

    /// For the log.
    var logName: String {
        switch self {
        case .off: "off"
        case .all: "all system audio"
        case .apps(let a): a.map { "\($0.name) (\($0.bundleID))" }.joined(separator: ", ")
        }
    }

    /// For session.json.
    var json: [String: Any] {
        switch self {
        case .off: ["type": "off"]
        case .all: ["type": "all"]
        case .apps(let a): ["type": "apps", "apps": a.map { ["bundle_id": $0.bundleID, "name": $0.name] }]
        }
    }
}

/// At least one track has to be on, or there's nothing to record.
var nothingToRecord: Bool { MicChoice.off && SystemAudio.saved == .off }

// ---------- the "Looks like a call started" suggestion ----------

/// Watches which app holds the microphone. Held longer than holdS — a notification with a Record button.
/// One suggestion per app per call: we suggest again after it lets go of the microphone
/// for forgetS (the call ended) and takes it again.
@MainActor
final class CallWatcher: NSObject, UNUserNotificationCenterDelegate {
    let holdS = 4.0
    let forgetS = 300.0
    var onRecord: (() -> Void)?
    /// A click on a notification with a folder ("Transcript ready") — open it.
    var onOpenFolder: ((String) -> Void)?
    var isRecording: () -> Bool = { false }
    /// For testing from the command line: called instead of a notification.
    var onSuggest: ((String, String) -> Void)?
    private(set) var notificationsAllowed = true
    private var timer: Timer?
    private var since: [String: Date] = [:]      // app → when it took the microphone
    private var lastSeen: [String: Date] = [:]   // app → when it last had the microphone
    private var suggested: Set<String> = []
    private var ticks = 0

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "suggestRecording") as? Bool ?? Identity.suggestCallsByDefault }
        set { UserDefaults.standard.set(newValue, forKey: "suggestRecording") }
    }

    /// Apps for which "Don't offer for this app" was clicked: bundle ID → name.
    var ignored: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "suggestIgnored") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "suggestIgnored") }
    }

    func start(notifications: Bool = true) {
        if notifications {
            let c = UNUserNotificationCenter.current()
            c.delegate = self
            c.setNotificationCategories([UNNotificationCategory(
                identifier: "call",
                actions: [UNNotificationAction(identifier: "record", title: String(localized: "Record")),
                          UNNotificationAction(identifier: "ignore", title: String(localized: "Don't offer for this app"))],
                intentIdentifiers: [])])
            if enabled { askPermission() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// The first time, macOS asks whether Koe may show notifications.
    func askPermission(_ done: (@MainActor (Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, error in
            if let error { recLog("notifications: \(error.localizedDescription)") }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.notificationsAllowed = ok
                    done?(ok)
                }
            }
        }
    }

    /// Notifications may have been turned on or off in System Settings — check every 10 s.
    private func refreshPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { st in
            let ok = [.authorized, .provisional].contains(st.authorizationStatus)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.notificationsAllowed = ok } }
        }
    }

    private func tick() {
        guard enabled else { return }
        ticks += 1
        if onSuggest == nil && ticks % 5 == 1 { refreshPermission() }
        let now = Date()
        var active: [String: String] = [:]   // bundle ID → name
        for p in audioProcesses() where p.input {
            // Koe itself never gets here: it has no Dock icon, so to the system it's a service
            guard let app = ownerApp(p), let b = app.bundleIdentifier else { continue }
            active[b] = app.localizedName ?? b
        }
        let recording = isRecording()
        for (b, name) in active {
            lastSeen[b] = now
            let start = since[b] ?? now
            since[b] = start
            if recording {
                // the call is already being recorded — no reminder about it after recording stops
                suggested.insert(b)
                withdraw(b)
            } else if now.timeIntervalSince(start) >= holdS, !suggested.contains(b), ignored[b] == nil {
                suggested.insert(b)
                suggest(b, name)
            }
        }
        for b in Array(since.keys) where active[b] == nil { since[b] = nil }
        for b in suggested where now.timeIntervalSince(lastSeen[b] ?? .distantPast) > 60 {
            withdraw(b)   // the microphone was released — the suggestion is out of date
            if now.timeIntervalSince(lastSeen[b] ?? .distantPast) > forgetS { suggested.remove(b) }
        }
    }

    private func suggest(_ bundle: String, _ name: String) {
        recLog("suggestion: \(name) (\(bundle)) is holding the microphone — offering to record")
        if let onSuggest { onSuggest(bundle, name); return }
        let c = UNMutableNotificationContent()
        c.title = String(localized: "Looks like a call started")
        c.body = String(localized: "\(name) is using the microphone. Record the call?")
        c.categoryIdentifier = "call"
        c.userInfo = ["bundle": bundle, "name": name]
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "call.\(bundle)", content: c, trigger: nil))
    }

    private func withdraw(_ bundle: String) {
        guard onSuggest == nil else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["call.\(bundle)"])
    }

    private func handle(_ action: String, _ bundle: String, _ name: String) {
        switch action {
        case "record", UNNotificationDefaultActionIdentifier:   // the button or a click on the notification
            onRecord?()
        case "ignore":
            ignored[bundle] = name
            recLog("suggestion: don't offer for \(name) any more")
        default: break
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        let bundle = info["bundle"] as? String ?? ""
        let name = info["name"] as? String ?? bundle
        let folder = info["folder"] as? String
        let isCall = response.notification.request.content.categoryIdentifier == "call"
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let folder {
                    self.onOpenFolder?(folder)
                } else if isCall {
                    self.handle(action, bundle, name)
                }
            }
        }
        done()
    }

    // show the notification even if Koe is "active" right now (for example, its window is open)
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}
