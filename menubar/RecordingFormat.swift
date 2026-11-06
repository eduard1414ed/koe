// How a recording is written: the Recording quality preset, the microphones and their input channels,
// and how they're laid out into tracks (MicPlan): one track per ticked device, or one per input with
// Each channel separately.
//
// The choices live in the app's defaults (UserDefaults): only the recorder reads them, and transcription
// finds everything it needs about each track (file, format, sample rate, channels, encoder delay)
// in session.json. They apply to the next recording: a recording keeps what it started with.
import CoreAudio
import Foundation

enum RecordingQuality: String, CaseIterable, Identifiable {
    case compact, high, lossless
    var id: String { rawValue }

    static var saved: RecordingQuality {
        get { UserDefaults.standard.string(forKey: "recordingQuality").flatMap(RecordingQuality.init) ?? .compact }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "recordingQuality") }
    }

    var title: String {
        switch self {
        case .compact: String(localized: "Compact")
        case .high: String(localized: "High")
        case .lossless: String(localized: "Lossless")
        }
    }

    var explanation: String {
        switch self {
        case .compact: String(localized: "AAC, mono, 48 kHz. Small files, good for calls.")
        case .high: String(localized: "AAC at 256 kbps, at the microphone's sample rate. Good sound without huge files.")
        case .lossless: String(localized: "WAV, 24-bit, at the microphone's sample rate. For podcasts, interviews and music.")
        }
    }

    var fileExtension: String { self == .lossless ? "wav" : "aac" }
    var aacBitRate: Int { self == .high ? 256_000 : 64_000 }

    /// The file's sample rate for a device running at `device` Hz. Apple's AAC encoder stops at 48 kHz,
    /// and at 256 kbps it needs 44.1 or 48 kHz — anything else is resampled to 48 kHz.
    func fileRate(device: Double) -> Double {
        switch self {
        case .compact: 48_000
        case .high: [44_100, 48_000].contains(device) ? device : 48_000
        case .lossless: device > 0 ? device : 48_000
        }
    }

    /// How many channels the file gets from a device with `count` channels and this channel choice.
    func fileChannels(_ pick: InputChannels, count: Int) -> Int {
        self == .compact ? 1 : pick.fileChannels(count: count)
    }

    func bytesPerSecond(rate: Double, channels: Int) -> Double {
        self == .lossless ? fileRate(device: rate) * 3 * Double(channels) : Double(aacBitRate) / 8
    }
}

/// Which of the device's channels go into the file. Matters for sound cards where the microphone
/// is plugged into one input.
enum InputChannels: Hashable {
    case mix            // all channels mixed to mono
    case stereo         // channels 1 and 2
    case channel(Int)   // one channel, counting from 0
    case each           // every channel on its own mono track

    init?(raw: String) {
        switch raw {
        case "mix": self = .mix
        case "stereo": self = .stereo
        case "each": self = .each
        default:
            guard raw.hasPrefix("ch"), let n = Int(raw.dropFirst(2)), n >= 1 else { return nil }
            self = .channel(n - 1)
        }
    }

    var raw: String {
        switch self {
        case .mix: "mix"
        case .stereo: "stereo"
        case .channel(let n): "ch\(n + 1)"
        case .each: "each"
        }
    }

    var title: String {
        switch self {
        case .mix: String(localized: "Mix to mono")
        case .stereo: String(localized: "Stereo (1+2)")
        case .channel(let n): String(localized: "Channel \(n + 1)")
        case .each: String(localized: "Each channel separately")
        }
    }

    func fileChannels(count: Int) -> Int { self == .stereo && count >= 2 ? 2 : 1 }

    static func options(count: Int) -> [InputChannels] {
        count > 1 ? [.mix, .stereo] + (0..<count).map { .channel($0) } + [.each] : [.mix]
    }

    /// The choice for one device, remembered by its UID. Doesn't fit the device (fewer channels now) — Mix to mono.
    static func saved(uid: String, count: Int) -> InputChannels {
        let all = UserDefaults.standard.dictionary(forKey: "inputChannels") as? [String: String] ?? [:]
        guard let pick = all[uid].flatMap(InputChannels.init(raw:)), options(count: count).contains(pick) else { return .mix }
        return pick
    }

    static func save(_ pick: InputChannels, uid: String) {
        var all = UserDefaults.standard.dictionary(forKey: "inputChannels") as? [String: String] ?? [:]
        all[uid] = pick.raw
        UserDefaults.standard.set(all, forKey: "inputChannels")
    }
}

/// Koe's own volume of a track, 0…2 (1 — the sound as is): for each ticked microphone, by the device's UID
/// ("default" — System default, whatever device that is), and for system audio. Unlike the other choices it also
/// applies to the recording that's going: CallRecording.setVolume.
enum TrackVolume {
    static let system = "system"
    static let range = 0.0...2.0

    static func key(_ uid: String?) -> String { uid ?? "default" }

    static func get(_ key: String) -> Double {
        let all = UserDefaults.standard.dictionary(forKey: "trackVolume") as? [String: Double] ?? [:]
        return all[key].map { min(range.upperBound, max(range.lowerBound, $0)) } ?? 1
    }

    static func set(_ key: String, _ value: Double) {
        var all = UserDefaults.standard.dictionary(forKey: "trackVolume") as? [String: Double] ?? [:]
        all[key] = value == 1 ? nil : value
        UserDefaults.standard.set(all, forKey: "trackVolume")
    }

    /// "100 %", for the panel and --dump.
    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded())) %" }
}

/// A ticked microphone: a device by UID, or System default (uid nil) — it follows the system
/// (AirPods connect — the recording moves to them). The name is kept to show the device while it isn't connected.
struct MicPick: Equatable, Hashable {
    let uid: String?
    let name: String?
    static let systemDefault = MicPick(uid: nil, name: nil)
}

/// The microphones ticked in the menu or Settings; each one is its own track (or several, with Each channel
/// separately). Off — the recording has no microphone track; the ticked list stays for when it's turned back on.
enum MicChoice {
    static var picks: [MicPick] {
        let d = UserDefaults.standard
        guard let list = d.array(forKey: "micInputs") as? [[String: String]] else {
            // before stage 4b there was one microphone: micUID (nil — System default)
            return [MicPick(uid: d.string(forKey: "micUID"), name: d.string(forKey: "micName"))]
        }
        let picks = list.map { MicPick(uid: $0["uid"], name: $0["name"]) }
        return picks.isEmpty ? [.systemDefault] : picks
    }

    static var off: Bool { UserDefaults.standard.bool(forKey: "micOff") }

    /// What the next recording gets: the ticked microphones, or nothing if the microphone is off.
    static var active: [MicPick] { off ? [] : picks }

    private static func save(_ picks: [MicPick], off: Bool) {
        let d = UserDefaults.standard
        d.set(picks.map { p in ["uid": p.uid, "name": p.name].compactMapValues { $0 } }, forKey: "micInputs")
        d.set(off, forKey: "micOff")
        d.removeObject(forKey: "micUID")
        d.removeObject(forKey: "micName")
    }

    /// Tick or untick a microphone. Ticking one while the microphone is off means "only this one";
    /// unticking the last one turns the microphone off (and remembers it for when it's turned back on).
    static func toggle(_ pick: MicPick) {
        if off { save([pick], off: false); return }
        var list = picks
        if let i = list.firstIndex(where: { $0.uid == pick.uid }) {
            list.remove(at: i)
            if list.isEmpty { save([pick], off: true); return }
        } else {
            list.append(pick)
        }
        save(list, off: false)
    }

    /// No microphone track. The ticked list stays for when it's turned back on.
    static func turnOff() { save(picks, off: true) }

    /// The microphone back on, with the microphones ticked before it was turned off.
    static func turnOn() { save(picks, off: false) }

    static func isTicked(_ uid: String?) -> Bool { !off && picks.contains { $0.uid == uid } }
}

/// One microphone track of a recording, as the ticked microphones and their Input channels lay them out.
struct MicTrack: Identifiable {
    let id: String              // the track in session.json and its file: "mic", "mic-2", "mic-3"…
    let pick: MicPick
    let device: InputDevice?    // nil — not connected right now
    /// Which channels of the device: the device's own choice (nil — decided when capture starts, from
    /// the device it actually gets) or one channel, with Each channel separately.
    let channels: InputChannels?
    /// Under which key its name and Transcribe are remembered: the device's UID ("default" for System
    /// default), plus "#N" for input N with Each channel separately.
    let key: String
    let label: String           // for Settings → Inputs
    let defaultName: String?    // nil — the first track: it's called by "Your name" (Me)
    var name: String?           // the name typed in Settings → Inputs, if any
    var transcribe: Bool

    /// The name in the transcript, with "Your name" for the first track.
    func displayName(me: String) -> String { name ?? defaultName ?? me }
}

/// Names and Transcribe of input tracks, remembered by device UID and input number (MicTrack.key).
enum InputTracks {
    static var all: [String: [String: Any]] {
        get { UserDefaults.standard.dictionary(forKey: "inputTracks") as? [String: [String: Any]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "inputTracks") }
    }

    static func set(_ key: String, name: String?, transcribe: Bool) {
        var a = all
        var e: [String: Any] = ["transcribe": transcribe]
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { e["name"] = name.trimmingCharacters(in: .whitespaces) }
        a[key] = e
        all = a
    }
}

enum MicPlan {
    /// The tracks for these microphones. devices — what's connected now. channels — overrides the saved
    /// Input channels of every device where it fits (for --record-test). A device ticked twice (System
    /// default is the same device as a ticked one) gets one track.
    static func tracks(_ picks: [MicPick], devices: [InputDevice] = InputDevice.all(),
                       channels: InputChannels? = nil) -> [MicTrack] {
        let saved = InputTracks.all
        let defaultUID = InputDevice.systemDefault?.uid
        var seen = Set<String>()
        var raw: [(pick: MicPick, device: InputDevice?, channels: InputChannels?, key: String, label: String, each: Bool)] = []
        for pick in picks {
            let device = pick.uid == nil ? devices.first { $0.uid == defaultUID } : devices.first { $0.uid == pick.uid }
            let uidNow = pick.uid ?? defaultUID ?? "default"
            guard seen.insert(uidNow).inserted else { continue }
            let deviceName = device?.name ?? pick.name ?? pick.uid ?? "?"
            let title = pick.uid == nil ? String(localized: "System default (\(device?.name ?? "none"))")
                : device == nil ? String(localized: "\(deviceName) (not connected)") : deviceName
            let key = pick.uid ?? "default"
            var choice = channels.flatMap { c in device.map { InputChannels.options(count: $0.channels).contains(c) } == true ? c : nil }
            if choice == nil, let device { choice = InputChannels.saved(uid: device.uid, count: device.channels) }
            if let device, choice == .each {
                for k in 0..<device.channels {
                    raw.append((pick, device, .channel(k), "\(key)#\(k + 1)", String(localized: "\(title) · input \(k + 1)"), true))
                }
            } else {
                // a device that isn't connected: its channel choice is decided when it comes back
                raw.append((pick, device, channels != nil ? choice : nil, key, title, false))
            }
        }
        let names = raw.map { $0.device?.name ?? $0.pick.name ?? "" }
        return raw.enumerated().map { i, r in
            let e = saved[r.key]
            // the first track is called by "Your name"; the others by the device, or "Mic N" when the device
            // name doesn't tell them apart (inputs of one device, two devices with the same name)
            let byDevice = names[i].isEmpty || r.each || names.filter({ $0 == names[i] }).count > 1 ? "Mic \(i + 1)" : names[i]
            return MicTrack(id: i == 0 ? "mic" : "mic-\(i + 1)", pick: r.pick, device: r.device, channels: r.channels,
                            key: r.key, label: r.label, defaultName: i == 0 ? nil : byDevice,
                            name: e?["name"] as? String, transcribe: (e?["transcribe"] as? Bool) ?? true)
        }
    }
}

// ---------- input devices ----------

struct InputDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    /// Channels of each input stream. A USB microphone or a sound card usually has one stream with every
    /// input; aggregate devices and some interfaces have several.
    let streams: [Int]
    let sampleRate: Double
    /// An aggregate device (Audio MIDI Setup): the UIDs of its own devices, in its order; empty for a regular device.
    let parts: [String]
    var isAggregate: Bool { !parts.isEmpty }
    /// How it's connected (kAudioDeviceTransportType…): built in, USB, Bluetooth, an iPhone, virtual, aggregate.
    let transport: UInt32
    /// A real microphone: not a virtual device made by an app (BlackHole, Zoom, Krisp) and not an aggregate device.
    /// The rest go to "Other devices" in the menu and in Settings.
    var isMicrophone: Bool {
        !isAggregate && ![kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
                          kAudioDeviceTransportTypeAutoAggregate].contains(transport)
    }
    /// Every input of every stream.
    var channels: Int { streams.reduce(0, +) }
    /// AVAudioEngine records only the first stream, and an aggregate device used as a microphone keeps system audio
    /// from recording: everything else goes through Koe's own aggregate device (InputsCapture).
    var engineCanRecord: Bool { !isAggregate && streams.count == 1 }

    init?(_ id: AudioObjectID) {
        let streams = inputStreams(id)
        guard streams.reduce(0, +) > 0 else { return nil }
        self.id = id
        self.streams = streams
        uid = deviceString(id, kAudioDevicePropertyDeviceUID)
        name = deviceString(id, kAudioObjectPropertyName)
        sampleRate = deviceSampleRate(id)
        parts = aggregateParts(id)
        var addr = propertyAddress(kAudioDevicePropertyTransportType)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        transport = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t) == noErr ? t : 0
    }

    /// Every device that can record, in the system's order.
    static func all() -> [InputDevice] {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var addr = propertyAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        // Koe's own private aggregate devices (while recording) aren't microphones to pick, nor is the one macOS
        // makes inside the app for AVAudioEngine (CADefaultDeviceAggregate-<pid>-<n>)
        return ids.compactMap(InputDevice.init).filter {
            !$0.uid.hasPrefix(privateDevicePrefix) && !$0.uid.hasPrefix("CADefaultDeviceAggregate")
        }
    }

    static var systemDefault: InputDevice? { InputDevice(defaultDevice(kAudioHardwarePropertyDefaultInputDevice)) }

    static func find(uid: String) -> InputDevice? { all().first { $0.uid == uid } }

    /// For --record-test --mic: a UID or a name (any case).
    static func find(_ key: String) -> InputDevice? {
        all().first { $0.uid == key } ?? all().first { $0.name.lowercased() == key.lowercased() }
    }
}

/// The UIDs of Koe's own aggregate devices start with this.
let privateDevicePrefix = "koe.private."

/// Channels of each input stream of a device; [] — it can't record.
func inputStreams(_ id: AudioObjectID) -> [Int] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                          mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, list) == noErr else { return [] }
    return UnsafeMutableAudioBufferListPointer(list).map { Int($0.mNumberChannels) }
}

/// An aggregate device's own devices (UIDs); [] — it's not an aggregate device.
func aggregateParts(_ id: AudioObjectID) -> [String] {
    var addr = propertyAddress(kAudioObjectPropertyClass)
    var cls: AudioClassID = 0
    var size = UInt32(MemoryLayout<AudioClassID>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cls) == noErr, cls == kAudioAggregateDeviceClassID else { return [] }
    var laddr = propertyAddress(kAudioAggregateDevicePropertyFullSubDeviceList)
    var list: Unmanaged<CFArray>?
    size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
    guard AudioObjectGetPropertyData(id, &laddr, 0, nil, &size, &list) == noErr, let list else { return [] }
    return (list.takeRetainedValue() as? [String]) ?? []
}

func deviceSampleRate(_ id: AudioObjectID) -> Double {
    var addr = propertyAddress(kAudioDevicePropertyNominalSampleRate)
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr ? rate : 0
}

/// About how much one hour of recording takes on disk: the microphone tracks plus the system audio track (if it's on).
func bytesPerHour(_ quality: RecordingQuality, mics: [MicTrack], systemOn: Bool) -> Double {
    let micBytes = mics.reduce(0.0) { sum, t in
        let pick = t.channels ?? t.device.map { InputChannels.saved(uid: $0.uid, count: $0.channels) } ?? .mix
        return sum + quality.bytesPerSecond(rate: t.device?.sampleRate ?? 48_000,
                                            channels: quality.fileChannels(pick, count: t.device?.channels ?? 1))
    }
    let outRate = deviceSampleRate(defaultDevice(kAudioHardwarePropertyDefaultOutputDevice))
    let system = quality.bytesPerSecond(rate: outRate > 0 ? outRate : 48_000, channels: quality == .compact ? 1 : 2)
    return (micBytes + (systemOn ? system : 0)) * 3600
}

/// 1.04e9 → "1.0 GB", 5.8e7 → "58 MB"
func humanSize(_ bytes: Double) -> String {
    bytes >= 1e9 ? "\((bytes / 1e9).formatted(.number.precision(.fractionLength(1)))) GB"
                 : "\(Int((bytes / 1e6).rounded())) MB"
}
