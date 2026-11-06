// A recording: microphone tracks (one per ticked microphone, or one per input with Each channel separately —
// see MicPlan in RecordingFormat.swift) and a system audio track (all of it, or the audio of the ticked apps
// mixed together). The microphone or system audio can be off, but not both.
//
// Two ways to capture:
//   - one microphone that is a plain device (System default or a chosen one, one input stream) — AVAudioEngine
//     (MicCapture), and system audio separately through a Core Audio process tap (SystemCapture), as before
//     stage 4b;
//   - anything else (several microphones, an aggregate device from Audio MIDI Setup, a device with several
//     input streams) — one private aggregate device of Koe's own (InputsCapture): every microphone's device, plus
//     the process tap in the same device, one IOProc, channels sorted into tracks. Everything runs on one clock
//     (the first microphone's; the rest are drift-compensated), so tracks don't drift apart over hours.
// The process tap (macOS 14.2+) delivers a mix of everything apps are playing (or only the ticked apps — see
// CallSources.swift), with no virtual drivers. Nothing is done to the sound: voice processing (echo cancellation, noise reduction,
// automatic level) stays off — it also has its own duplex mode that gives silence instead of the microphone
// on some devices. Echo is removed during transcription, by comparing text.
//
// The format is the Recording quality preset. Compact and High are AAC in an ADTS stream (.aac): every
// frame stands on its own, so a crash loses only the last fraction of a second. AAC in CAF can't do that:
// the packet table is written on close, and without it the file can't be read at all. Lossless is WAV
// from our own writer (WavWriter.swift), which survives a crash too. session.json says, for each track,
// which file it is, its format, sample rate, channels and encoder delay.
//
// Time: every buffer carries a system clock stamp (host time). It tells where each track starts on
// the session's shared timeline, and after a capture restart (the device changed) the missing time
// is filled with silence — the track stays continuous and in step with the clock.
import AVFoundation
import CoreAudio
import os

let aacPrimingFrames = 2112   // how much silence the AAC encoder puts at the start of the file (at any sample rate)

struct RecorderError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw RecorderError(String(localized: "\(what) (code \(status))")) }
}

private let logQueue = DispatchQueue(label: "koe.recorder.log")

func recLog(_ text: String) {
    let stamp = Date()
    logQueue.async {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = Data("\(f.string(from: stamp)) \(text)\n".utf8)
        try? FileManager.default.createDirectory(at: Identity.logsDir, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: Identity.recorderLog) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            try? line.write(to: Identity.recorderLog)
        }
    }
}

func isoLocal(_ d: Date) -> String {
    let f = ISO8601DateFormatter()
    f.timeZone = .current
    return f.string(from: d)
}

func hostSeconds(_ host: UInt64) -> Double { AVAudioTime.seconds(forHostTime: host) }

/// A number with three decimals that looks like 28.993 in JSON too, not 28.992999999999999.
func round3(_ x: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), x)) }

// ---------- Core Audio devices ----------

func propertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                               mElement: kAudioObjectPropertyElementMain)
}

func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID {
    var addr = propertyAddress(selector)
    var id = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
    return id
}

func deviceString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var addr = propertyAddress(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let value else { return "?" }
    return value.takeRetainedValue() as String
}

struct DeviceInfo {
    let id: AudioObjectID
    let name: String
    let uid: String
    init(_ id: AudioObjectID) {
        self.id = id
        name = deviceString(id, kAudioObjectPropertyName)
        uid = deviceString(id, kAudioDevicePropertyDeviceUID)
    }
    static var input: DeviceInfo { DeviceInfo(defaultDevice(kAudioHardwarePropertyDefaultInputDevice)) }
    static var output: DeviceInfo { DeviceInfo(defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)) }
}

extension AVAudioPCMBuffer {
    /// A copy of the buffer: the original only lives inside the capture callback.
    func koeCopy() -> AVAudioPCMBuffer? {
        guard frameLength > 0, let c = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        c.frameLength = frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(c.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            guard let from = s.mData, let to = d.mData else { continue }
            memcpy(to, from, Int(min(s.mDataByteSize, d.mDataByteSize)))
        }
        return c
    }
}

// ---------- writing one track to a file ----------

/// Takes buffers from the device, picks or mixes its channels, brings them to the file's sample rate
/// and writes them in the preset's format: AAC (Compact, High) or WAV (Lossless).
/// The file opens when capture starts for the first time: its sample rate and channels come from that
/// device and the preset, and stay for the whole recording — audio from a device that comes later is converted.
/// Everything except the "mailbox" calls runs on its own queue.
final class TrackWriter: @unchecked Sendable {
    let name: String
    let fileName: String
    let quality: RecordingQuality
    private let url: URL
    private let sessionStartHost: UInt64
    private let queue: DispatchQueue
    private var format: AVAudioFormat?   // the file's: Float32, its sample rate and channels
    private var aac: AVAudioFile?
    private var wav: WavWriter?
    private var pick = InputChannels.mix
    private var converter: AVAudioConverter?
    private var startHost: UInt64?
    private var frames: Int64 = 0
    private var peak: Float = 0
    private let levelBox = OSAllocatedUnfairLock(initialState: 0.0)
    private var resyncReason: String?
    private var gaps: [[String: Any]] = []
    private var devices: [[String: Any]] = []
    private var errors: [String] = []
    // Koe's volume (TrackVolume): what's applied now and what was asked for; a change slides over one buffer,
    // so it doesn't click. volumes — every change, for session.json
    private var gain: Float
    private var targetGain: Float
    private var volumes: [[String: Any]]

    init(name: String, dir: URL, sessionStartHost: UInt64, quality: RecordingQuality, volume: Double = 1) {
        self.name = name
        self.quality = quality
        self.sessionStartHost = sessionStartHost
        gain = Float(volume)
        targetGain = Float(volume)
        volumes = [["from_s": 0, "percent": Int((volume * 100).rounded())]]
        fileName = "\(name).\(quality.fileExtension)"
        url = dir.appendingPathComponent(fileName)
        queue = DispatchQueue(label: "koe.writer.\(name)")
    }

    private var fileRate: Double { format?.sampleRate ?? 48_000 }

    private var startOffset: Double? {
        startHost.map { hostSeconds($0) - hostSeconds(sessionStartHost) }
    }

    /// Capture started (or started again) on this device, delivering `input`; `pick` — which of its channels to keep.
    func deviceStarted(_ dev: DeviceInfo, input: AVAudioFormat, channels pick: InputChannels) {
        let at = hostSeconds(mach_absolute_time()) - hostSeconds(sessionStartHost)
        queue.async {
            self.devices.append(["name": dev.name, "uid": dev.uid, "from_s": round3(at),
                                 "sample_rate": Int(input.sampleRate), "channels": Int(input.channelCount),
                                 "input_channels": pick.raw])
            self.pick = pick
            if self.format == nil { self.open(input) }
        }
    }

    private func open(_ input: AVAudioFormat) {
        let rate = quality.fileRate(device: input.sampleRate)
        let channels = quality.fileChannels(pick, count: Int(input.channelCount))
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels)) else { return }
        do {
            if quality == .lossless {
                wav = try WavWriter(url: url, sampleRate: Int(rate), channels: channels)
            } else {
                // AAC in an ADTS stream: every frame stands on its own (see the top of the file)
                aac = try AVAudioFile(forWriting: url, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: rate,
                    AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: quality.aacBitRate,
                ], commonFormat: .pcmFormatFloat32, interleaved: false)
            }
            format = fmt
        } catch {
            errors.append("can't create \(fileName): \(error.localizedDescription)")
        }
    }

    /// Capture is restarting: the next buffer goes where the clock says, and the gap is filled with silence.
    func captureRestarting(reason: String) {
        queue.async { self.resyncReason = reason }
    }

    func noteError(_ text: String) {
        queue.async { self.errors.append(text) }
    }

    /// The volume changed (the panel's slider): from this moment on. A slider sends many values while it's dragged:
    /// changes less than half a second apart are one entry in session.json.
    func setVolume(_ value: Double) {
        let at = hostSeconds(mach_absolute_time()) - hostSeconds(sessionStartHost)
        queue.async {
            self.targetGain = Float(value)
            let entry: [String: Any] = ["from_s": round3(at), "percent": Int((value * 100).rounded())]
            if let last = self.volumes.last?["from_s"] as? NSDecimalNumber, at - last.doubleValue < 0.5, self.volumes.count > 1 {
                self.volumes[self.volumes.count - 1] = entry
            } else {
                self.volumes.append(entry)
            }
        }
    }

    /// Called from the capture thread; the buffer is already copied.
    func append(_ buf: AVAudioPCMBuffer, hostTime: UInt64) {
        queue.async { self.write(buf, hostTime) }
    }

    private func write(_ buf: AVAudioPCMBuffer, _ hostTime: UInt64) {
        guard let format else { return }
        if startHost == nil {
            startHost = hostTime
            resyncReason = nil   // a restart before the first sound leaves no gap: the track start is set by the clock anyway
        } else if let reason = resyncReason, let startHost {
            resyncReason = nil
            converter?.reset()
            let expected = Int64((hostSeconds(hostTime) - hostSeconds(startHost)) * fileRate)
            let missing = max(0, expected - frames)
            let from = (startOffset ?? 0) + Double(frames) / fileRate
            // a restart that lost nothing (a tap swap often doesn't) isn't a gap
            if missing > 0 {
                gaps.append(["track": name, "from_s": round3(from),
                             "to_s": round3(from + Double(missing) / fileRate), "reason": reason])
            }
            writeSilence(missing)
        }
        guard let mapped = mapChannels(buf, to: Int(format.channelCount)) else { return }
        var out = mapped
        if mapped.format.sampleRate != format.sampleRate {
            if converter?.inputFormat != mapped.format {
                converter = AVAudioConverter(from: mapped.format, to: format)
                converter?.sampleRateConverterQuality = AVAudioQuality.max.rawValue
                if converter == nil { errors.append("can't convert format \(mapped.format)") }
            }
            guard let converter else { return }
            let cap = AVAudioFrameCount(Double(mapped.frameLength) * format.sampleRate / mapped.format.sampleRate) + 64
            guard let res = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return }
            var given = false
            var err: NSError?
            let status = converter.convert(to: res, error: &err) { _, st in
                if given { st.pointee = .noDataNow; return nil }
                given = true
                st.pointee = .haveData
                return mapped
            }
            if status == .error {
                if errors.count < 20 { errors.append("audio conversion error: \(err?.localizedDescription ?? "?")") }
                return
            }
            out = res
        }
        guard out.frameLength > 0, let d = out.floatChannelData else { return }
        applyGain(out)
        var sum: Float = 0
        for c in 0..<Int(out.format.channelCount) {
            for i in 0..<Int(out.frameLength) { peak = max(peak, abs(d[c][i])) }
        }
        for i in 0..<Int(out.frameLength) { sum += d[0][i] * d[0][i] }
        // loudness for the menu bar ring — same as in koe-logo/reference/preview.html
        let db = 20 * log10(Double((sum / Float(out.frameLength)).squareRoot()) + 1e-9)
        levelBox.withLock { $0 = max(0, min(1, (db + 50) / 40)) }
        do {
            if let wav { try wav.write(out) } else { try aac?.write(from: out) }
            frames += Int64(out.frameLength)
        } catch {
            if errors.count < 20 { errors.append("write error: \(error.localizedDescription)") }
        }
    }

    /// Koe's volume, in place (the buffer is the writer's own: mapped or converted). Above 100 % loud parts can go
    /// past full scale: they're cut at it, as the WAV writer would do anyway, so AAC and WAV sound the same.
    private func applyGain(_ b: AVAudioPCMBuffer) {
        guard gain != 1 || targetGain != 1, let d = b.floatChannelData else { gain = targetGain; return }
        let n = Int(b.frameLength), from = gain, to = targetGain
        for c in 0..<Int(b.format.channelCount) {
            let x = d[c]
            for i in 0..<n {
                let g = from == to ? to : from + (to - from) * Float(i + 1) / Float(n)
                x[i] = max(-1, min(1, x[i] * g))
            }
        }
        gain = to
    }

    /// The device's channels → the file's: one channel, a mix of all of them, or channels 1 and 2.
    /// A mono source in a stereo file goes to both sides. Nothing else is done to the sound.
    private func mapChannels(_ buf: AVAudioPCMBuffer, to channels: Int) -> AVAudioPCMBuffer? {
        let n = Int(buf.frameLength), inCount = Int(buf.format.channelCount)
        guard let src = buf.floatChannelData, inCount > 0,
              let fmt = AVAudioFormat(standardFormatWithSampleRate: buf.format.sampleRate, channels: AVAudioChannelCount(channels)),
              let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: buf.frameLength), let dst = out.floatChannelData else {
            if errors.count < 20 { errors.append("unsupported input format \(buf.format)") }
            return nil
        }
        out.frameLength = buf.frameLength
        let interleaved = buf.format.isInterleaved, stride = buf.stride
        // which input channels feed each output channel
        let sources: [[Int]]
        switch pick {
        case .channel(let k): sources = Array(repeating: [min(k, inCount - 1)], count: channels)
        case .stereo where channels == 2: sources = [[0], [min(1, inCount - 1)]]
        case .stereo: sources = Array(repeating: Array(0..<min(2, inCount)), count: channels)
        case .mix, .each: sources = Array(repeating: Array(0..<inCount), count: channels)
        }
        for (c, from) in sources.enumerated() {
            let d = dst[c], scale = 1 / Float(from.count)
            for i in 0..<n {
                var s: Float = 0
                for k in from { s += interleaved ? src[0][i * stride + k] : src[k][i] }
                d[i] = s * scale
            }
        }
        return out
    }

    private func writeSilence(_ count: Int64) {
        guard count > 0, let format else { return }
        if let wav {
            do { try wav.writeSilence(frames: count); frames += count } catch {
                if errors.count < 20 { errors.append("write error: \(error.localizedDescription)") }
            }
            return
        }
        var left = count
        while left > 0 {
            let n = AVAudioFrameCount(min(left, 48_000))
            guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { return }
            b.frameLength = n
            for c in 0..<Int(format.channelCount) { memset(b.floatChannelData![c], 0, Int(n) * MemoryLayout<Float>.size) }
            try? aac?.write(from: b)
            frames += Int64(n)
            left -= Int64(n)
        }
    }

    /// The track's description for session.json. finish: true — flush and close the file.
    func summary(finish: Bool = false) -> [String: Any] {
        queue.sync {
            if finish {
                if #available(macOS 15.0, *) { aac?.close() }
                aac = nil
                wav?.close()
                wav = nil
            }
            var d: [String: Any] = [
                "file": fileName,
                "format": quality == .lossless ? "wav" : "aac-adts",
                "quality": quality.rawValue,
                // how much silence the encoder put at the start of the file, in the file's frames
                "encoder_delay_frames": quality == .lossless ? 0 : aacPrimingFrames,
                "frames": frames,
                "duration_s": round3(Double(frames) / fileRate),
                "peak_db": peak > 0 ? round3(20 * log10(Double(peak))) : -200,
                "devices": devices,
                // Koe's volume: at the start, then every change (from_s — seconds from the start of the recording)
                "volume": volumes,
            ]
            d["sample_rate"] = format.map { Int($0.sampleRate) } ?? NSNull()
            d["channels"] = format.map { Int($0.channelCount) } ?? NSNull()
            if quality == .lossless { d["bits_per_sample"] = 24 } else { d["bit_rate"] = quality.aacBitRate }
            d["start_offset_s"] = startOffset.map(round3) ?? NSNull()
            if !errors.isEmpty { d["errors"] = errors }
            return d
        }
    }

    var gapList: [[String: Any]] { queue.sync { gaps } }

    /// Loudness of the last buffer, 0…1. Computed on the writer queue, not on the capture thread.
    var level: Double { levelBox.withLock { $0 } }
}

// ---------- capture ----------

protocol Capture: AnyObject {
    var onChange: ((String) -> Void)? { get set }
    var device: DeviceInfo { get }
    /// The tracks it writes: a restart leaves a gap in each of them.
    var writers: [TrackWriter] { get }
    /// The device the next start() will use.
    func nextDevice() -> DeviceInfo
    func start() throws
    func stop()
}

/// Microphone: the device chosen in the menu (by UID), or the system default input, through AVAudioEngine.
/// With System default it follows the system. With a chosen device it doesn't; if that device is gone,
/// it records from the system default until the device comes back (fallback).
/// One device, but it may feed several tracks: with Each channel separately, one per input.
final class MicCapture: Capture {
    struct Output {
        let writer: TrackWriter
        /// Which channels go to this track; nil — the device's saved Input channels.
        let channels: InputChannels?
    }
    private let outputs: [Output]
    let chosenUID: String?
    let chosenName: String?
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    var onChange: ((String) -> Void)?
    private(set) var device = DeviceInfo.input
    var writers: [TrackWriter] { outputs.map(\.writer) }
    /// A device was chosen, but it isn't connected: recording from the system default instead.
    private(set) var onFallback = false
    var followsSystem: Bool { chosenUID == nil || onFallback }

    init(outputs: [Output], uid: String?, name: String?) {
        self.outputs = outputs
        chosenUID = uid
        chosenName = name
    }

    /// The chosen device if it's connected, otherwise the system default.
    private func resolve() -> (DeviceInfo, chosen: Bool) {
        if let uid = chosenUID, let d = InputDevice.find(uid: uid) { return (DeviceInfo(d.id), true) }
        return (DeviceInfo.input, false)
    }

    func nextDevice() -> DeviceInfo { resolve().0 }

    func start() throws {
        let (dev, chosen) = resolve()
        device = dev
        onFallback = chosenUID != nil && !chosen
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // without this the input unit follows the system default device
        if chosen {
            do { try input.auAudioUnit.setDeviceID(dev.id) } catch {
                throw RecorderError(String(localized: "Couldn't turn on \(dev.name): \(error.localizedDescription)"))
            }
        }
        // the device's own format: after setDeviceID the node's outputFormat still describes the previous
        // device (its channels and sample rate), and the tap must get every channel the device has
        let fmt = input.inputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { throw RecorderError(String(localized: "No microphone found")) }
        let count = Int(fmt.channelCount)
        let saved = InputChannels.saved(uid: dev.uid, count: count)
        let picks = outputs.map { o in o.channels.flatMap { InputChannels.options(count: count).contains($0) ? $0 : nil } ?? saved }
        let writers = self.writers
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, when in
            guard let copy = buf.koeCopy() else { return }
            let host = when.isHostTimeValid ? when.hostTime : mach_absolute_time()
            // the writers only read the buffer: one copy for all of them
            for w in writers { w.append(copy, hostTime: host) }
        }
        // a new engine sometimes reports a "configuration change" right after starting —
        // we don't restart on those, or we could end up restarting in circles
        let started = Date()
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard Date().timeIntervalSince(started) > 2 else { return }
            self?.onChange?("microphone configuration changed")
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            throw RecorderError(String(localized: "Couldn't turn on the microphone: \(error.localizedDescription)"))
        }
        self.engine = engine
        for (o, pick) in zip(outputs, picks) { o.writer.deviceStarted(device, input: fmt, channels: pick) }
        recLog("mic: \(device.name)\(chosen ? " (chosen)" : onFallback ? " (system default — the chosen one isn't connected)" : " (system default)"), "
               + "\(Int(fmt.sampleRate)) Hz, \(fmt.channelCount) channels, input channels: \(picks.map(\.raw).joined(separator: ", ")), "
               + "voice processing: \(input.isVoiceProcessingEnabled ? "ON" : "off")")
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}

/// A Float32 non-interleaved format with any number of channels (more than two need a channel layout).
func floatFormat(_ rate: Double, _ channels: Int) -> AVAudioFormat? {
    channels <= 2 ? AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels))
        : AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)).map {
            AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: $0)
        }
}

/// A listener on the system object (devices, default devices, audio processes), called on the main queue.
final class SystemListener {
    private var addr: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock

    init?(_ selector: AudioObjectPropertySelector, _ action: @escaping () -> Void) {
        addr = propertyAddress(selector)
        block = { _, _ in action() }
        guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block) == noErr else { return nil }
    }

    func remove() {
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
    }
}

/// The process tap of the system audio track: all audio, or the processes of the ticked apps; mono or stereo.
/// Its format follows the output device, and it calls onChange when that format changes.
final class SystemTap {
    private(set) var id = AudioObjectID(kAudioObjectUnknown)
    let uuid: String
    let source: SystemAudio
    /// The ticked apps' processes in the tap. The apps may have none yet: the tap is then silent until they appear.
    let included: Set<AudioObjectID>
    private var formatListener: AudioObjectPropertyListenerBlock?

    /// extra — more processes to mix in (Koe itself, see SilenceOutput).
    init(source: SystemAudio, stereo: Bool, extra: [AudioObjectID] = []) throws {
        self.source = source
        let desc: CATapDescription
        if case .apps(let apps) = source {
            // one tap for all the ticked apps: their processes are mixed into one track
            let ids = audioProcessIDs(of: apps.map(\.bundleID))
            included = Set(ids)
            desc = stereo ? CATapDescription(stereoMixdownOfProcesses: ids + extra) : CATapDescription(monoMixdownOfProcesses: ids + extra)
        } else {
            included = []
            desc = stereo ? CATapDescription(stereoGlobalTapButExcludeProcesses: []) : CATapDescription(monoGlobalTapButExcludeProcesses: [])
        }
        desc.name = "Koe"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        uuid = desc.uuid.uuidString
        try check(AudioHardwareCreateProcessTap(desc, &id),
                  String(localized: "Couldn't connect to system audio. Check that \(Identity.appName) is allowed in System Settings → Privacy & Security → Screen & System Audio Recording"))
    }

    /// The format the tap delivers on its own (in Koe's aggregate device it comes at that device's sample rate).
    func format() throws -> AVAudioFormat {
        var addr = propertyAddress(kAudioTapPropertyFormat)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &asbd), String(localized: "Couldn't read the system audio format"))
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else { throw RecorderError(String(localized: "Unsupported system audio format")) }
        return fmt
    }

    /// The tap's format follows the output device: call this when it changes.
    func onFormatChange(_ action: @escaping () -> Void) {
        let listener: AudioObjectPropertyListenerBlock = { _, _ in action() }
        var addr = propertyAddress(kAudioTapPropertyFormat)
        if AudioObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main, listener) == noErr { formatListener = listener }
    }

    /// A ticked app has an audio process this tap doesn't have (a browser opened a tab with the call, a messenger
    /// started a call). macOS won't change the process list of a running tap (kAudioTapPropertyDescription → '!hog'):
    /// it takes a new tap.
    var missesProcesses: Bool {
        !source.apps.isEmpty && !Set(audioProcessIDs(of: source.apps.map(\.bundleID))).isSubset(of: included)
    }

    func destroy() {
        guard id != kAudioObjectUnknown else { return }
        if let formatListener {
            var addr = propertyAddress(kAudioTapPropertyFormat)
            AudioObjectRemovePropertyListenerBlock(id, &addr, DispatchQueue.main, formatListener)
        }
        formatListener = nil
        AudioHardwareDestroyProcessTap(id)
        id = AudioObjectID(kAudioObjectUnknown)
    }
}

/// System audio through a process tap: tap → private aggregate device → our IOProc.
/// The source is all audio or the processes of the ticked apps. Mono for Compact, stereo for High and Lossless.
final class SystemCapture: Capture {
    private let writer: TrackWriter
    let source: SystemAudio   // .all or .apps
    private let stereo: Bool
    private var tap: SystemTap?
    private var processListener: SystemListener?
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "koe.system.io", qos: .userInteractive)
    var onChange: ((String) -> Void)?
    private(set) var device = DeviceInfo.output
    var writers: [TrackWriter] { [writer] }

    init(writer: TrackWriter, source: SystemAudio, stereo: Bool) {
        self.writer = writer
        self.source = source
        self.stereo = stereo
    }

    func nextDevice() -> DeviceInfo { DeviceInfo.output }

    func start() throws {
        device = DeviceInfo.output
        do {
            try writer.deviceStarted(device, input: startTap(), channels: stereo ? .stereo : .mix)
        } catch {
            stop()
            throw error
        }
    }

    /// Returns the format the tap delivers.
    private func startTap() throws -> AVAudioFormat {
        let tap = try SystemTap(source: source, stereo: stereo)
        self.tap = tap
        let fmt = try tap.format()

        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Koe system tap",
            kAudioAggregateDeviceUIDKey: privateDevicePrefix + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tap.uuid,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggregateID), String(localized: "Couldn't set up a device for recording system audio"))

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [writer] _, inData, inTime, _, _ in
            guard let b = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: inData, deallocator: nil),
                  let copy = b.koeCopy() else { return }
            let t = inTime.pointee
            writer.append(copy, hostTime: t.mFlags.contains(.hostTimeValid) ? t.mHostTime : mach_absolute_time())
        }, String(localized: "Couldn't connect the audio handler"))
        try check(AudioDeviceStart(aggregateID, procID), String(localized: "Couldn't start recording system audio"))

        // the tap's format follows the output device; when it changes, restart with the new one
        tap.onFormatChange { [weak self] in self?.onChange?("system audio format changed") }
        if !source.apps.isEmpty {
            // a ticked app started a new audio process — recreate the tap with it included; about a second
            // is lost when the process appears, the gap is noted in session.json
            processListener = SystemListener(kAudioHardwarePropertyProcessObjectList) { [weak self] in
                guard let self, self.tap?.missesProcesses == true else { return }
                self.onChange?("a ticked app (\(self.source.apps.map(\.name).joined(separator: ", "))) started a new audio process")
            }
        }
        recLog("system: output \(device.name), \(Int(fmt.sampleRate)) Hz, \(fmt.channelCount) channels, "
               + "source: \(source.logName)\(source.apps.isEmpty ? "" : ", \(tap.included.count) processes")")
        return fmt
    }

    func stop() {
        processListener?.remove()
        processListener = nil
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        tap?.destroy()
        tap = nil
    }
}

/// Several microphones, an aggregate device from Audio MIDI Setup or a device with several input streams — and
/// system audio, if it's on — through one private aggregate device of Koe's own: the microphones' devices (an
/// aggregate device of the user's goes in as its own devices: one aggregate device can't hold another) and the
/// process tap. One IOProc gets every input stream and the tap at once; their channels are sorted into tracks.
/// The first device is the clock, the others and the tap are drift-compensated by Core Audio.
///
/// A ticked device that isn't connected gets no audio (its track has a gap) until it comes back — unlike a
/// single microphone, it doesn't move to the system default: that would usually put the same room on two tracks.
/// System default here is whichever device is the default when capture (re)starts.
final class InputsCapture: Capture {
    struct Output {
        let writer: TrackWriter
        let pick: MicPick
        /// Which channels go to this track; nil — the device's saved Input channels.
        let channels: InputChannels?
    }
    private let outputs: [Output]
    private let systemWriter: TrackWriter?
    let source: SystemAudio
    private let stereo: Bool
    private var tap: SystemTap?
    private let silence = SilenceOutput()
    private var processListener: SystemListener?
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "koe.inputs.io", qos: .userInteractive)
    var onChange: ((String) -> Void)?
    /// Something about system audio changed (the output device, a new process of a ticked app): the tap is
    /// swapped inside the running device — the microphones lose ~0.1 s instead of a restart of everything.
    var onSystemChange: ((String) -> Void)?
    /// The clock device, for the log.
    private(set) var device = DeviceInfo.input
    var writers: [TrackWriter] { outputs.map(\.writer) + (systemWriter.map { [$0] } ?? []) }
    /// The ticked microphones that weren't connected at the last (re)start.
    private(set) var missing: [MicPick] = []
    /// The devices in the running aggregate device (UIDs), in order — to notice when one comes or goes.
    private(set) var running: [String] = []
    private var started = false

    init(outputs: [Output], systemWriter: TrackWriter?, source: SystemAudio, stereo: Bool) {
        self.outputs = outputs
        self.systemWriter = systemWriter
        self.source = source
        self.stereo = stereo
    }

    func nextDevice() -> DeviceInfo { InputDevice.systemDefault.map { DeviceInfo($0.id) } ?? DeviceInfo.input }

    /// The ticked devices that are connected now, each once, with their tracks; and the physical devices that
    /// go into the aggregate device, in order.
    private func resolve() -> (groups: [(device: InputDevice, outputs: [Output])], parts: [InputDevice], missing: [MicPick]) {
        let devices = InputDevice.all()
        let defaultUID = InputDevice.systemDefault?.uid
        var groups: [(device: InputDevice, outputs: [Output])] = []
        var missing: [MicPick] = []
        for o in outputs {
            guard let dev = devices.first(where: { $0.uid == (o.pick.uid ?? defaultUID) }) else {
                if !missing.contains(o.pick) { missing.append(o.pick) }
                continue
            }
            if let i = groups.firstIndex(where: { $0.device.uid == dev.uid }) { groups[i].outputs.append(o) } else { groups.append((dev, [o])) }
        }
        var parts: [InputDevice] = []
        for g in groups {
            let own = g.device.isAggregate ? g.device.parts.compactMap { u in devices.first { $0.uid == u } } : [g.device]
            for d in own where !parts.contains(where: { $0.uid == d.uid }) { parts.append(d) }
        }
        return (groups, parts, missing)
    }

    /// The devices have changed so that the running aggregate device no longer matches the ticked ones.
    var outOfDate: Bool { resolve().parts.map(\.uid) != running }

    func start() throws {
        let (groups, parts, missing) = resolve()
        self.missing = missing
        defer { started = true }
        guard !parts.isEmpty || systemWriter != nil else {
            // none of the ticked microphones is connected: wait for one (the device list is watched)
            if !started { throw RecorderError(String(localized: "None of the chosen microphones is connected")) }
            running = []
            recLog("inputs: none of the chosen microphones is connected — waiting")
            return
        }
        do { try startDevice(groups, parts) } catch {
            stop()
            throw error
        }
    }

    private func startDevice(_ groups: [(device: InputDevice, outputs: [Output])], _ parts: [InputDevice]) throws {
        // the aggregate device's input streams: every stream of every part in order, then the tap
        var first: [String: Int] = [:]   // part UID → index of its first stream
        var expected: [Int] = []          // channels of each stream
        for p in parts {
            first[p.uid] = expected.count
            expected += p.streams
        }
        if systemWriter != nil {
            let tap = try SystemTap(source: source, stereo: stereo, extra: keepAlive())
            self.tap = tap
            expected.append(stereo ? 2 : 1)
        }
        var desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Koe inputs",
            kAudioAggregateDeviceUIDKey: privateDevicePrefix + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: parts.enumerated().map { i, p in
                [kAudioSubDeviceUIDKey: p.uid, kAudioSubDeviceDriftCompensationKey: i > 0] as [String: Any]
            },
            kAudioAggregateDeviceTapListKey: tap.map { [[kAudioSubTapUIDKey: $0.uuid, kAudioSubTapDriftCompensationKey: true]] }
                ?? [] as [[String: Any]],
        ]
        if let main = parts.first { desc[kAudioAggregateDeviceMainSubDeviceKey] = main.uid }
        try check(AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggregateID),
                  String(localized: "Couldn't set up a device for recording the microphones"))

        // check that the device came out as expected: stream by stream, Float32
        let streams = aggregateStreams(aggregateID)
        guard streams.map(\.channels) == expected, streams.allSatisfy(\.isFloat), let rate = streams.first?.rate, rate > 0 else {
            recLog("inputs: unexpected streams \(streams.map { "\($0.channels)ch \(Int($0.rate)) Hz\($0.isFloat ? "" : " not float")" }), expected \(expected)")
            throw RecorderError(String(localized: "Couldn't set up a device for recording the microphones"))
        }

        // where each track's channels are: (stream, channel in that stream)
        struct Route { let writers: [TrackWriter]; let format: AVAudioFormat; let map: [(Int, Int)] }
        var routes: [Route] = []
        var log: [String] = []
        for g in groups {
            let own = g.device.isAggregate ? g.device.parts.compactMap { u in parts.first { $0.uid == u } } : [g.device]
            let map = own.flatMap { p in
                p.streams.enumerated().flatMap { s, n in (0..<n).map { (first[p.uid]! + s, $0) } }
            }
            guard let fmt = floatFormat(rate, map.count) else { continue }
            let saved = InputChannels.saved(uid: g.device.uid, count: map.count)
            for o in g.outputs {
                let pick = o.channels.flatMap { InputChannels.options(count: map.count).contains($0) ? $0 : nil } ?? saved
                o.writer.deviceStarted(DeviceInfo(g.device.id), input: fmt, channels: pick)
                log.append("\(o.writer.name) ← \(g.device.name)\(o.pick.uid == nil ? " (system default)" : ""), \(map.count) ch, \(pick.raw)")
            }
            routes.append(Route(writers: g.outputs.map(\.writer), format: fmt, map: map))
        }
        if let systemWriter, let fmt = floatFormat(rate, stereo ? 2 : 1) {
            systemWriter.deviceStarted(DeviceInfo.output, input: fmt, channels: stereo ? .stereo : .mix)
            routes.append(Route(writers: [systemWriter], format: fmt, map: (0..<(stereo ? 2 : 1)).map { (expected.count - 1, $0) }))
            log.append("system ← output \(DeviceInfo.output.name), source: \(source.logName)\(source.apps.isEmpty ? "" : ", \(tap?.included.count ?? 0) processes")")
        }

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, inData, inTime, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            // a device came or went and the layout changed: skip until the restart that follows
            guard list.count == expected.count, zip(list, expected).allSatisfy({ Int($0.mNumberChannels) == $1 }) else { return }
            let frames = Int(list[0].mDataByteSize) / (4 * expected[0])
            guard frames > 0 else { return }
            let t = inTime.pointee
            let host = t.mFlags.contains(.hostTimeValid) ? t.mHostTime : mach_absolute_time()
            for r in routes {
                guard let buf = AVAudioPCMBuffer(pcmFormat: r.format, frameCapacity: AVAudioFrameCount(frames)),
                      let dst = buf.floatChannelData else { continue }
                buf.frameLength = AVAudioFrameCount(frames)
                for (c, (s, ch)) in r.map.enumerated() {
                    let b = list[s], n = Int(b.mNumberChannels)
                    guard let src = b.mData?.assumingMemoryBound(to: Float.self), Int(b.mDataByteSize) >= frames * n * 4 else {
                        memset(dst[c], 0, frames * MemoryLayout<Float>.size)
                        continue
                    }
                    for i in 0..<frames { dst[c][i] = src[i * n + ch] }   // the streams are interleaved
                }
                // the writers only read the buffer: one copy for all tracks of a device
                for w in r.writers { w.append(buf, hostTime: host) }
            }
        }, String(localized: "Couldn't connect the audio handler"))
        try check(AudioDeviceStart(aggregateID, procID), String(localized: "Couldn't start recording the microphones"))

        tap?.onFormatChange { [weak self] in self?.onSystemChange?("system audio format changed") }
        if systemWriter != nil, !source.apps.isEmpty {
            processListener = SystemListener(kAudioHardwarePropertyProcessObjectList) { [weak self] in
                guard let self, self.tap?.missesProcesses == true else { return }
                self.onSystemChange?("a ticked app (\(self.source.apps.map(\.name).joined(separator: ", "))) started a new audio process")
            }
        }
        running = parts.map(\.uid)
        device = parts.first.map { DeviceInfo($0.id) } ?? DeviceInfo.output
        recLog("inputs: Koe's aggregate device, \(Int(rate)) Hz, clock: \(parts.first?.name ?? "system audio"), devices: "
               + "\(parts.map(\.name).joined(separator: ", "))\(tap != nil ? " + system audio" : ""); "
               + log.joined(separator: "; ")
               + (missing.isEmpty ? "" : "; not connected: \(missing.map { $0.name ?? $0.uid ?? "?" }.joined(separator: ", "))"))
    }

    /// Koe's silence goes into the tap, so the tap (and the microphones with it) start right away — see SilenceOutput.
    /// A global tap has Koe in it anyway; a tap of the ticked apps gets Koe's process added.
    private func keepAlive() -> [AudioObjectID] {
        silence.start()
        guard !source.apps.isEmpty else { return [] }
        if let me = SilenceOutput.processObject { return [me] }
        recLog("inputs: Koe's own audio process not found — the microphones may wait until a ticked app makes a sound")
        return []
    }

    /// A new tap in the running device instead of the old one: the output device or the ticked apps' processes
    /// changed. Every track gets a gap of ~0.1 s, filled with silence by the clock.
    func swapTap(_ reason: String) throws {
        guard let old = tap, aggregateID != kAudioObjectUnknown else { return }
        let new = try SystemTap(source: source, stereo: stereo, extra: SilenceOutput.processObject.map { source.apps.isEmpty ? [] : [$0] } ?? [])
        writers.forEach { $0.captureRestarting(reason: reason) }
        var addr = propertyAddress(kAudioAggregateDevicePropertyTapList)
        var list = [new.uuid] as CFArray
        let status = withUnsafeMutablePointer(to: &list) {
            AudioObjectSetPropertyData(aggregateID, &addr, 0, nil, UInt32(MemoryLayout<CFArray>.size), $0)
        }
        guard status == noErr else {
            new.destroy()
            throw RecorderError(String(localized: "Couldn't start recording system audio (code \(status))"))
        }
        old.destroy()
        tap = new
        new.onFormatChange { [weak self] in self?.onSystemChange?("system audio format changed") }
        recLog("inputs: system audio tap swapped — \(reason)\(source.apps.isEmpty ? "" : ", \(new.included.count) processes")")
    }

    func stop() {
        processListener?.remove()
        processListener = nil
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        tap?.destroy()
        tap = nil
        silence.stop()
        running = []
    }
}

/// Koe's own process plays digital silence to the output device while InputsCapture records system audio.
/// A process tap starts delivering only once one of its processes has started playing (after that it keeps
/// going, even when they're quiet), and in a shared aggregate device a tap that hasn't started holds up the
/// microphones too: nothing is recorded until the ticked app — or with All system audio, any app — makes
/// a sound. Koe's own process is in the tap, so the tap starts right away. The silence adds nothing to the mix.
final class SilenceOutput {
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?

    /// Koe's own audio process object (it exists once Koe has used audio).
    static var processObject: AudioObjectID? {
        var addr = propertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    func start() {
        let e = AVAudioEngine()
        let player = AVAudioPlayerNode()
        e.attach(player)
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4800) else { return }
        buf.frameLength = 4800   // zeros
        e.connect(player, to: e.mainMixerNode, format: fmt)
        player.scheduleBuffer(buf, at: nil, options: .loops)
        do { try e.start() } catch {
            recLog("silence output didn't start: \(error.localizedDescription)")
            return
        }
        player.play()
        engine = e
        // the output device changed: the engine stops — start it again on the new one
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: .main) { [weak self] _ in
            self?.stop()
            self?.start()
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.stop()
        engine = nil
    }
}

/// The input streams of a device: channels, sample rate, Float32 or not.
func aggregateStreams(_ id: AudioObjectID) -> [(channels: Int, rate: Double, isFloat: Bool)] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.map { s in
        var faddr = propertyAddress(kAudioStreamPropertyVirtualFormat)
        var asbd = AudioStreamBasicDescription()
        var fsize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioObjectGetPropertyData(s, &faddr, 0, nil, &fsize, &asbd)
        return (Int(asbd.mChannelsPerFrame), asbd.mSampleRate,
                asbd.mFormatID == kAudioFormatLinearPCM && asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 && asbd.mBitsPerChannel == 32)
    }
}

// ---------- session ----------

/// One recording: the folder inbox/<date_time>/ with its tracks (mic.aac, mic-2.aac… and/or system.aac, or .wav
/// for Lossless) and session.json. session.json is written on stop and means "the recording is ready"; while recording,
/// session.partial.json sits next to it — it's used to recover the recording after a crash.
@MainActor
final class CallRecording {
    let dir: URL
    let startedAt = Date()
    let startHost = mach_absolute_time()
    /// The microphone tracks, in order (empty — the microphone is off), and their writers.
    let micTracks: [MicTrack]
    private let micWriters: [TrackWriter]
    private let systemWriter: TrackWriter?   // nil — no system track
    // one way of capturing or the other (see the top of the file); system — only without inputs
    private let mic: MicCapture?
    private let inputs: InputsCapture?
    private let system: SystemCapture?
    private var listeners: [SystemListener] = []
    private var pending: [String: DispatchWorkItem] = [:]
    private var activity: NSObjectProtocol?
    private(set) var stopped = false
    let quality: RecordingQuality
    /// The chosen microphone wasn't there (at the start or later): what was recorded instead, for the notification.
    private(set) var micSwitches: [(at: Double, from: String, to: String)] = []
    /// With several microphones: which ticked ones went missing and when (they aren't replaced by another device).
    private(set) var inputGaps: [(at: Double, name: String, back: Double?)] = []

    /// What goes on the system track; .off — no system track.
    let systemAudio: SystemAudio
    var hasMic: Bool { !micTracks.isEmpty }
    /// Loudness for the menu bar ring: the first microphone, or system audio if the microphone is off.
    var level: Double { micWriters.first?.level ?? systemWriter?.level ?? 0 }

    /// Loudness of the tracks of one ticked microphone (uid nil — System default), the loudest of them; nil — it has
    /// no track in this recording. For the meters in the panel.
    func micLevel(_ uid: String?) -> Double? {
        zip(micTracks, micWriters).filter { $0.0.pick.uid == uid }.map { $0.1.level }.max()
    }

    /// Loudness of the system audio track; nil — there's none.
    var systemLevel: Double? { systemWriter?.level }

    /// The panel's volume slider moved: key — TrackVolume.key of a ticked microphone (all its tracks) or
    /// TrackVolume.system. Heard in the file from this moment on.
    func setVolume(_ key: String, _ value: Double) {
        for (t, w) in zip(micTracks, micWriters) where TrackVolume.key(t.pick.uid) == key { w.setVolume(value) }
        if key == TrackVolume.system { systemWriter?.setVolume(value) }
    }

    /// --volume-at: every track at once.
    func setAllVolumesForTest(_ value: Double) {
        for w in micWriters + (systemWriter.map { [$0] } ?? []) { w.setVolume(value) }
    }

    /// mics — the ticked microphones (empty — no microphone track; uid nil — System default); system .off — no
    /// system track; channels — override the saved Input channels; names, skip — override a track's name and
    /// Transcribe by its id; volume — every track's volume instead of the saved ones (the last four are for --record-test).
    init(mics: [MicPick] = MicChoice.active, system: SystemAudio = .saved, quality: RecordingQuality = .saved,
         channels: InputChannels? = nil, names: [String: String] = [:], skip: Set<String> = [],
         volume: Double? = nil) throws {
        guard !mics.isEmpty || system != .off else {
            throw RecorderError(String(localized: "Nothing to record. Turn on the microphone or system audio."))
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmm"
        let base = f.string(from: startedAt)
        var dir = Identity.inboxDir.appendingPathComponent(base)
        var n = 2
        // the name is the recording's key for transcription: a recording from the same minute may have
        // already left the inbox, but its key is still in the registry — then this one would be taken as done
        let known = readJSON(Identity.stateDir.appendingPathComponent("registry.json"))["recordings"] as? [String: Any] ?? [:]
        while FileManager.default.fileExists(atPath: dir.path) || known["local:\(dir.lastPathComponent)"] != nil {
            dir = Identity.inboxDir.appendingPathComponent("\(base)_\(n)")
            n += 1
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.dir = dir
        self.quality = quality
        systemAudio = system
        micTracks = MicPlan.tracks(mics, channels: channels).map { t in
            var t = t
            if let name = names[t.id] { t.name = name }
            if skip.contains(t.id) { t.transcribe = false }
            return t
        }
        let host = startHost
        micWriters = micTracks.map {
            TrackWriter(name: $0.id, dir: dir, sessionStartHost: host, quality: quality,
                        volume: volume ?? TrackVolume.get(TrackVolume.key($0.pick.uid)))
        }
        systemWriter = system == .off ? nil : TrackWriter(name: "system", dir: dir, sessionStartHost: host, quality: quality,
                                                          volume: volume ?? TrackVolume.get(TrackVolume.system))
        // one plain device (one input stream, not an aggregate one) — AVAudioEngine, as before; a chosen device
        // that isn't connected goes this way too: it falls back to the system default
        let picks = Set(micTracks.map(\.pick))
        if micTracks.isEmpty {
            mic = nil
            inputs = nil
        } else if picks.count == 1, micTracks[0].device?.engineCanRecord ?? true {
            let pick = micTracks[0].pick
            mic = MicCapture(outputs: zip(micTracks, micWriters).map { .init(writer: $1, channels: $0.channels) },
                             uid: pick.uid, name: pick.name)
            inputs = nil
        } else {
            mic = nil
            inputs = InputsCapture(outputs: zip(micTracks, micWriters).map { .init(writer: $1, pick: $0.pick, channels: $0.channels) },
                                   systemWriter: systemWriter, source: system, stereo: quality != .compact)
        }
        if let systemWriter, inputs == nil {
            self.system = SystemCapture(writer: systemWriter, source: system, stereo: quality != .compact)
        } else {
            self.system = nil
        }
    }

    private var micLogName: String {
        guard !micTracks.isEmpty else { return "off" }
        return micTracks.map { t in
            "\(t.id): " + (t.pick.uid.map { "\(t.pick.name ?? "?") (\($0))" } ?? "system default")
                + (t.channels.map { ", \($0.raw)" } ?? "") + (t.transcribe ? "" : ", not transcribed")
        }.joined(separator: "; ") + (inputs != nil ? " — through Koe's aggregate device" : "")
    }

    func start() throws {
        recLog("recording started: \(dir.lastPathComponent), quality: \(quality.rawValue), "
               + "system audio: \(systemAudio.logName), microphone: \(micLogName)")
        do {
            try system?.start()
            try mic?.start()
            try inputs?.start()
        } catch {
            system?.stop()
            mic?.stop()
            inputs?.stop()
            try? FileManager.default.removeItem(at: dir)
            recLog("recording didn't start: \(error.localizedDescription)")
            throw error
        }
        if let mic {
            if mic.onFallback { noteMicSwitch(from: mic.chosenName ?? "?") }
            mic.onChange = { [weak self] r in MainActor.assumeIsolated { self?.scheduleRestart("mic", r) } }
            // a chosen microphone doesn't follow the system — unless it's gone and we're on the system default for now
            listen(kAudioHardwarePropertyDefaultInputDevice) {
                if $0.mic?.followsSystem == true { $0.scheduleRestart("mic", "input device changed") }
            }
            listen(kAudioHardwarePropertyDevices) { $0.inputDevicesChanged() }
        }
        if let inputs {
            for pick in inputs.missing { inputGaps.append((0, pick.name ?? pick.uid ?? "?", nil)) }
            inputs.onChange = { [weak self] r in MainActor.assumeIsolated { self?.scheduleRestart("inputs", r) } }
            inputs.onSystemChange = { [weak self] r in MainActor.assumeIsolated { self?.scheduleRestart("tap", r) } }
            // a ticked device came or went, or the system default moved (when System default is ticked)
            for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
                listen(selector) {
                    if $0.inputs?.outOfDate == true { $0.scheduleRestart("inputs", "input devices changed") }
                }
            }
            if systemWriter != nil {
                listen(kAudioHardwarePropertyDefaultOutputDevice) { $0.scheduleRestart("tap", "output device changed") }
            }
        }
        if let system {
            system.onChange = { [weak self] r in MainActor.assumeIsolated { self?.scheduleRestart("system", r) } }
            listen(kAudioHardwarePropertyDefaultOutputDevice) { $0.scheduleRestart("system", "output device changed") }
        }
        // the recording shouldn't break off because the Mac dozed off while idle;
        // closing the lid still puts it to sleep, and then the recording stops properly
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated], reason: "\(Identity.appName): recording")
        writePartial()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.writePartial() }
    }

    private func listen(_ selector: AudioObjectPropertySelector, _ action: @escaping @MainActor (CallRecording) -> Void) {
        if let l = SystemListener(selector, { [weak self] in MainActor.assumeIsolated { if let self { action(self) } } }) {
            listeners.append(l)
        }
    }

    /// A device was connected or disconnected: the chosen microphone is gone — move to the system default;
    /// it's back — return to it.
    private func inputDevicesChanged() {
        guard let mic, let uid = mic.chosenUID else { return }
        let present = InputDevice.find(uid: uid) != nil
        let name = mic.chosenName ?? uid
        if !mic.onFallback && !present {
            scheduleRestart("mic", "\(name) disconnected")
        } else if mic.onFallback && present {
            scheduleRestart("mic", "\(name) is back")
        }
    }

    private func noteMicSwitch(from: String) {
        let at = Date().timeIntervalSince(startedAt)
        let now = mic?.device.name ?? "?"
        micSwitches.append((at, from, now))
        recLog("mic: the chosen microphone \(from) isn't connected — recording from \(now)")
    }

    /// After a restart of the inputs: which ticked microphones went missing or came back.
    private func noteInputs(missingBefore: [MicPick]) {
        guard let inputs else { return }
        let at = Date().timeIntervalSince(startedAt)
        for pick in inputs.missing where !missingBefore.contains(pick) {
            inputGaps.append((at, pick.name ?? pick.uid ?? "?", nil))
            recLog("inputs: \(pick.name ?? pick.uid ?? "?") isn't connected — its track is silent until it comes back")
        }
        for pick in missingBefore where !inputs.missing.contains(pick) {
            let name = pick.name ?? pick.uid ?? "?"
            if let i = inputGaps.lastIndex(where: { $0.name == name && $0.back == nil }) { inputGaps[i].back = at }
        }
    }

    /// For the notification after recording: a chosen microphone went missing. nil — they were there all along.
    var micSwitchNote: (title: String, text: String)? {
        if let first = micSwitches.first {
            let title = String(localized: "Recorded with a different microphone")
            if first.at < 1 {
                return (title, String(localized: "\(first.from) wasn't connected when the recording started, so \(Identity.appName) used \(first.to) instead."))
            }
            return (title, String(localized: "\(first.from) was disconnected \(clock(first.at)) into the recording, so \(Identity.appName) switched to \(first.to). The moment of the switch may have a short gap."))
        }
        guard !inputGaps.isEmpty else { return nil }
        let text = inputGaps.map { g in
            if g.at < 1 && g.back == nil { return String(localized: "\(g.name) wasn't connected, so its track is empty.") }
            if g.at < 1, let back = g.back { return String(localized: "\(g.name) wasn't connected until \(clock(back)) into the recording; its track is silent before that.") }
            if let back = g.back { return String(localized: "\(g.name) was disconnected from \(clock(g.at)) to \(clock(back)); its track is silent in between.") }
            return String(localized: "\(g.name) was disconnected \(clock(g.at)) into the recording; its track is silent from then on.")
        }.joined(separator: " ")
        return (String(localized: "A microphone was missing"), text)
    }

    /// Devices usually change with a burst of notifications — restart once, after things settle.
    private func scheduleRestart(_ track: String, _ reason: String) {
        guard !stopped else { return }
        pending[track]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.restart(track, reason) }
        }
        pending[track] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// For testing: restart every capture, as if the device changed.
    func restartForTest() {
        for track in ["mic", "inputs", "system"] { restart(track, "restart test") }
    }

    /// For testing: swap the system audio tap of the inputs device, as if the output device changed.
    func swapTapForTest() { restart("tap", "tap swap test") }

    private func restart(_ track: String, _ reason: String) {
        guard !stopped else { return }
        if track == "tap" {
            // with the inputs device: a new tap inside it; if that fails — a restart of everything
            guard let inputs else { return }
            do { try inputs.swapTap(reason) } catch {
                recLog("inputs: tap swap failed (\(error.localizedDescription)) — restarting")
                restart("inputs", reason)
            }
            writePartial()
            return
        }
        let cap: Capture
        switch track {
        case "mic": guard let mic else { return }; cap = mic
        case "inputs": guard let inputs else { return }; cap = inputs
        default: guard let system else { return }; cap = system
        }
        pending[track]?.cancel()
        if track == "inputs" { pending["tap"]?.cancel() }   // the restart makes a new tap anyway
        let before = cap.device.name
        let wasFallback = mic?.onFallback ?? false
        let missingBefore = inputs?.missing ?? []
        cap.stop()
        let now = cap.nextDevice()
        let why = now.name == before || track == "inputs" ? reason : "\(reason): \(before) → \(now.name)"
        cap.writers.forEach { $0.captureRestarting(reason: why) }
        do {
            try cap.start()
            recLog("\(track): restarted — \(why)")
            if track == "mic", let mic, mic.onFallback, !wasFallback { noteMicSwitch(from: mic.chosenName ?? before) }
            if track == "inputs" { noteInputs(missingBefore: missingBefore) }
        } catch {
            recLog("\(track): restart failed (\(error.localizedDescription)), trying again in 3 s")
            cap.writers.first?.noteError("restart failed: \(error.localizedDescription)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.restart(track, reason) }
        }
        writePartial()
    }

    private func document(ended: Date?, reason: String?, finish: Bool) -> [String: Any] {
        // only the tracks that are on; the transcription takes whichever are there
        var tracks: [String: Any] = [:]
        for (t, w) in zip(micTracks, micWriters) {
            var d = w.summary(finish: finish)
            // the name in the transcript: typed in Settings → Inputs, otherwise "Your name" for "mic" and default_name for the rest
            d["name"] = t.name ?? NSNull()
            d["default_name"] = t.defaultName ?? NSNull()
            d["transcribe"] = t.transcribe
            var input: [String: Any] = ["key": t.key]
            if let uid = t.pick.uid {
                input["choice"] = "device"
                input["uid"] = uid
                input["name"] = t.device?.name ?? t.pick.name ?? NSNull()
            } else {
                input["choice"] = "system default"
            }
            if case .channel(let k) = t.channels, t.key.contains("#") { input["channel"] = k + 1 }
            d["input"] = input
            tracks[t.id] = d
        }
        if let systemWriter { tracks["system"] = systemWriter.summary(finish: finish) }
        let microphone: [String: Any]
        let picks = micTracks.reduce(into: [MicPick]()) { if !$0.contains($1.pick) { $0.append($1.pick) } }
        if picks.isEmpty {
            microphone = ["choice": "off"]
        } else if picks.count == 1 {
            microphone = picks[0].uid.map { ["choice": "device", "uid": $0, "name": picks[0].name ?? NSNull()] }
                ?? ["choice": "system default"]
        } else {
            microphone = ["choice": "devices", "devices": picks.map { p in
                p.uid.map { ["uid": $0, "name": p.name ?? NSNull()] as [String: Any] } ?? ["choice": "system default"]
            }]
        }
        var d: [String: Any] = [
            "version": 1,
            "id": dir.lastPathComponent,
            "source": "local",
            "started_at": isoLocal(startedAt),
            "tracks": tracks,
            "quality": quality.rawValue,
            "microphone": microphone,
            // how the microphones were captured: AVAudioEngine, or Koe's aggregate device together with system audio
            "capture": inputs != nil ? "aggregate" : micTracks.isEmpty ? "system" : "engine",
            "system_source": systemAudio.json,
            "gaps": (micWriters + (systemWriter.map { [$0] } ?? [])).flatMap(\.gapList),
        ]
        if let ended {
            d["ended_at"] = isoLocal(ended)
            d["duration_s"] = round3(ended.timeIntervalSince(startedAt))
        }
        if let reason { d["end_reason"] = reason }
        // menu → Save to: take the choice at the moment the file is written; it can change during the recording
        if let folder = CallFolder.current { d["meetings_folder"] = folder }
        return d
    }

    private func writePartial() {
        guard !stopped else { return }
        writeJSON(document(ended: nil, reason: nil, finish: false), dir.appendingPathComponent("session.partial.json"))
    }

    /// Stop the tracks and write session.json. reason: user / sleep / quit.
    @discardableResult
    func stop(reason: String) -> [String: Any] {
        guard !stopped else { return [:] }
        stopped = true
        pending.values.forEach { $0.cancel() }
        listeners.forEach { $0.remove() }
        listeners = []
        mic?.stop()
        inputs?.stop()
        system?.stop()
        // let the writer queues finish the last buffers
        let doc = document(ended: Date(), reason: reason, finish: true)
        writeJSON(doc, dir.appendingPathComponent("session.json"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("session.partial.json"))
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        recLog("recording stopped (\(reason)): \(dir.lastPathComponent), \(doc["duration_s"] ?? "?") s")
        return doc
    }

    /// Recordings cut off by a crash (session.partial.json exists, session.json doesn't): close them,
    /// taking the last modification time of the audio files as the end. Called when the app launches.
    static func recoverInterrupted() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Identity.inboxDir, includingPropertiesForKeys: nil) else { return }
        for dir in dirs {
            let partial = dir.appendingPathComponent("session.partial.json")
            let final = dir.appendingPathComponent("session.json")
            guard fm.fileExists(atPath: partial.path), !fm.fileExists(atPath: final.path) else { continue }
            var doc = readJSON(partial)
            var tracks = doc["tracks"] as? [String: [String: Any]] ?? [:]
            let ends = tracks.values.compactMap { $0["file"] as? String }.compactMap {
                (try? fm.attributesOfItem(atPath: dir.appendingPathComponent($0).path))?[.modificationDate] as? Date
            }
            let ended = ends.max() ?? Date()
            doc["ended_at"] = isoLocal(ended)
            if let s = doc["started_at"] as? String, let start = ISO8601DateFormatter().date(from: s) {
                doc["duration_s"] = round3(ended.timeIntervalSince(start))
            }
            doc["end_reason"] = "recovered"
            // track lengths in the snapshot are stale: only the file itself knows the real one.
            // A WAV gets its header fixed from the file size, and then we know its length too.
            for (k, t) in tracks {
                let fixed = t["format"] as? String == "wav"
                    ? (t["file"] as? String).flatMap { WavWriter.repair(dir.appendingPathComponent($0)) } : nil
                tracks[k]?["frames"] = fixed.map { $0.frames } ?? NSNull()
                tracks[k]?["duration_s"] = fixed.map { round3(Double($0.frames) / Double($0.sampleRate)) } ?? NSNull()
                if let fixed { recLog("recovery: \(t["file"] ?? "?") fixed, \(fixed.frames) frames") }
            }
            doc["tracks"] = tracks
            writeJSON(doc, final)
            try? fm.removeItem(at: partial)
            recLog("recovered an interrupted recording: \(dir.lastPathComponent)")
        }
    }
}

func writeJSON(_ obj: [String: Any], _ url: URL) {
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: url, options: .atomic)
    }
}
