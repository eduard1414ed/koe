// The three permissions Koe asks for (stage 9): the microphone, system audio ("Screen & System Audio Recording") and
// notifications — what each one is now, asking for it, and the place in System Settings where it's turned on.
//
// System audio has no public way to ask "is it allowed?". So:
//   - asking is honest: SystemAudioCheck starts a short capture of all system audio (the first time, that's what makes
//     macOS ask), plays a short sound from Koe itself and listens for it. Heard — the permission works; silence — it
//     doesn't (without the permission a capture runs, but only gets silence);
//   - for the warning in the menu the state is read from macOS's privacy database with TCCAccessPreflight — a private
//     function that only reads, the same one other audio capture apps use. If it's missing in some macOS version,
//     the state is unknown and the menu says nothing (the warning after a silent recording still works). Sound
//     actually heard (systemAudioHeard) wins over its "never asked": that answer isn't always right.
import AppKit
import AVFoundation
import CoreAudio
import os
import UserNotifications

enum Permission: String {
    case microphone, systemAudio, notifications

    /// Its place in System Settings → Privacy & Security (notifications: the app's own page in Notifications).
    var settingsURL: URL? {
        switch self {
        case .microphone: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .systemAudio: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .notifications: URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Identity.bundleID)")
        }
    }

    func openSettings() {
        if let settingsURL { NSWorkspace.shared.open(settingsURL) }
    }
}

enum PermissionState: Equatable {
    case allowed, denied, notAsked, unknown
}

@MainActor
enum Permissions {
    static var microphone: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private static let preflight: Preflight? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let sym = dlsym(h, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: Preflight.self)
    }()

    /// What macOS's privacy database says about system audio recording (see the top of the file). The database
    /// can say "never asked" even though recording works (seen with the dev build), so sound actually heard — by the
    /// check or in a recording — counts as allowed; only an explicit "denied" beats it.
    static var systemAudio: PermissionState {
        guard let preflight else { return systemAudioHeard ? .allowed : .unknown }
        switch preflight("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .allowed
        case 1: return .denied
        default: return systemAudioHeard ? .allowed : .notAsked
        }
    }

    /// The last proof that system audio recording works: the check heard its sound (false if the check got only
    /// silence), or a recording's system track had sound.
    static var systemAudioHeard: Bool {
        get { UserDefaults.standard.bool(forKey: "systemAudioHeard") }
        set { UserDefaults.standard.set(newValue, forKey: "systemAudioHeard") }
    }

    /// Notifications: the answer comes later, so the last one is kept here (refreshNotifications updates it).
    private(set) static var notifications: PermissionState = .unknown

    static func refreshNotifications(_ done: (@MainActor (PermissionState) -> Void)? = nil) {
        UNUserNotificationCenter.current().getNotificationSettings { st in
            let state: PermissionState = switch st.authorizationStatus {
            case .authorized, .provisional, .ephemeral: .allowed
            case .notDetermined: .notAsked
            default: .denied
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    notifications = state
                    done?(state)
                }
            }
        }
    }

    static func askNotifications(_ done: @escaping @MainActor (PermissionState) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { recLog("notifications: \(error.localizedDescription)") }
            DispatchQueue.main.async { MainActor.assumeIsolated { refreshNotifications(done) } }
        }
    }
}

/// The system audio check: a short capture of all system audio, with a short sound played by Koe in the middle of it.
/// done(true) — the sound came through, so system audio recording works.
@MainActor
final class SystemAudioCheck {
    private var tap: SystemTap?
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let peak = OSAllocatedUnfairLock(initialState: Float(0))
    private let ioQueue = DispatchQueue(label: "koe.check.io", qos: .userInitiated)

    /// The whole check takes about two seconds.
    static func run(_ done: @escaping @MainActor (Bool) -> Void) {
        let check = SystemAudioCheck()
        do {
            try check.start()
        } catch {
            recLog("system audio check: \(error.localizedDescription)")
            check.stop()
            done(false)
            return
        }
        // a moment for the capture to start, then the sound, then listen a bit longer than it plays
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSSound(named: "Tink")?.play()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            MainActor.assumeIsolated {
                let p = check.peak.withLock { $0 }
                check.stop()
                let heard = p > 0.0005   // -66 dB: anything at all; without the permission it's exact zeros
                recLog(String(format: "system audio check: peak %.1f dB — %@", 20 * log10(Double(p) + 1e-9), heard ? "heard" : "silence"))
                Permissions.systemAudioHeard = heard
                done(heard)
            }
        }
    }

    private func start() throws {
        let tap = try SystemTap(source: .all, stereo: false)
        self.tap = tap
        let fmt = try tap.format()
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Koe check",
            kAudioAggregateDeviceUIDKey: privateDevicePrefix + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tap.uuid, kAudioSubTapDriftCompensationKey: true]],
        ]
        try check(AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggregateID), "aggregate device")
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [peak] _, inData, _, _, _ in
            guard let b = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: inData, deallocator: nil),
                  let d = b.floatChannelData else { return }
            var m: Float = 0
            for c in 0..<Int(b.format.channelCount) { for i in 0..<Int(b.frameLength) { m = max(m, abs(d[c][i])) } }
            let loudest = m
            peak.withLock { $0 = max($0, loudest) }
        }, "IOProc")
        try check(AudioDeviceStart(aggregateID, procID), "start")
    }

    private func stop() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tap?.destroy()
        tap = nil
    }
}

/// How loud the microphone is right now (the system default input): for the setup window, so the person sees that
/// they're heard and through which microphone.
@MainActor
final class MicLevel: ObservableObject {
    @Published private(set) var level = 0.0      // 0…1, the same scale as the ring in the menu bar
    @Published private(set) var device = ""
    private var engine: AVAudioEngine?
    private let box = OSAllocatedUnfairLock(initialState: 0.0)
    private var timer: Timer?

    var running: Bool { engine != nil }

    func start() {
        guard engine == nil, Permissions.microphone == .allowed else { return }
        let e = AVAudioEngine()
        let input = e.inputNode
        let fmt = input.inputFormat(forBus: 0)
        guard fmt.channelCount > 0, fmt.sampleRate > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [box] buf, _ in
            guard let d = buf.floatChannelData, buf.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buf.frameLength) { sum += d[0][i] * d[0][i] }
            let db = 20 * log10(Double((sum / Float(buf.frameLength)).squareRoot()) + 1e-9)
            box.withLock { $0 = max(0, min(1, (db + 50) / 40)) }
        }
        do {
            try e.start()
        } catch {
            recLog("mic level: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            return
        }
        engine = e
        device = DeviceInfo.input.name
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.level = self.box.withLock { $0 }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        level = 0
    }
}
