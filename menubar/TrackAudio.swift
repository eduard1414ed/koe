// Reading a recording's track for transcription: any file Koe writes (AAC ADTS stream, WAV, RF64 — also
// ones fixed after a crash) → 16 kHz mono floats. Long files are read in blocks, so only the 16 kHz result
// is held in memory (~230 MB per hour).
//
// WAV/RF64 is read by our own reader: it takes the data length from the header, but never past the end of
// the file, and a header that was never updated (length 0) means "everything up to the end of the file".
// AAC goes through Core Audio (ExtAudioFile). The encoder's silence at the start isn't cut here:
// how much of it there is comes from session.json (encoder_delay_frames), see Transcriber.
import AudioToolbox
import AVFoundation
import Foundation

let asrRate = 16_000

enum TrackAudio {
    /// The whole track at 16 kHz, mono (the channels are averaged). An empty file is an error: the caller checks for it.
    static func read(_ url: URL) throws -> [Float] {
        let source: AudioSource = try isWav(url) ? WavSource(url) : CoreAudioSource(url)
        return try resample(source)
    }

    private static func isWav(_ url: URL) throws -> Bool {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let head = h.readData(ofLength: 12)
        guard head.count == 12 else { return false }
        let tag = String(decoding: head.prefix(4), as: UTF8.self)
        return (tag == "RIFF" || tag == "RF64") && String(decoding: head[8..<12], as: UTF8.self) == "WAVE"
    }

    /// The source at its own rate → 16 kHz (Apple's sample rate converter, best quality).
    private static func resample(_ source: AudioSource) throws -> [Float] {
        var out: [Float] = []
        if Int(source.sampleRate) == asrRate {
            while let block = try source.next(65_536) { out += block }
            return out
        }
        let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source.sampleRate, channels: 1, interleaved: false)!
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(asrRate), channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw RecorderError("can't convert \(Int(source.sampleRate)) Hz audio")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 32_768)!
        var ended = false
        var readError: Error?
        while true {
            outBuffer.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { packets, inputStatus in
                guard !ended else { inputStatus.pointee = .endOfStream; return nil }
                do {
                    guard let block = try source.next(Int(packets)), !block.isEmpty else {
                        ended = true
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    let b = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(block.count))!
                    b.frameLength = b.frameCapacity
                    block.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: block.count) }
                    inputStatus.pointee = .haveData
                    return b
                } catch {
                    readError = error
                    ended = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
            }
            if let error { throw error }
            if let readError { throw readError }
            out.append(contentsOf: UnsafeBufferPointer(start: outBuffer.floatChannelData![0], count: Int(outBuffer.frameLength)))
            if status == .endOfStream || status == .error { break }
        }
        return out
    }
}

/// Mono blocks of a file at its own rate; nil — the end.
protocol AudioSource: AnyObject {
    var sampleRate: Double { get }
    func next(_ frames: Int) throws -> [Float]?
}

/// WAV and RF64: PCM 8/16/24/32 bit or float 32, any number of channels.
final class WavSource: AudioSource {
    let sampleRate: Double
    private let channels: Int
    private let bits: Int
    private let isFloat: Bool
    private let frameBytes: Int
    private var remaining: UInt64
    private let handle: FileHandle

    init(_ url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        let fileSize = (try? handle.seekToEnd()) ?? 0   // the file itself, also behind a symlink
        try handle.seek(toOffset: 0)
        func bad(_ why: String) -> Error { RecorderError("\(url.lastPathComponent): \(why)") }
        let head = handle.readData(ofLength: 12)
        let rf64 = String(decoding: head.prefix(4), as: UTF8.self) == "RF64"
        var ds64Data: UInt64?
        var format: (tag: Int, channels: Int, rate: Int, bits: Int, block: Int)?
        var pos: UInt64 = 12
        while true {
            let ch = handle.readData(ofLength: 8)
            guard ch.count == 8 else { throw bad("no audio data in the file") }
            let id = String(decoding: ch.prefix(4), as: UTF8.self)
            let size = UInt64(ch.u32(4))
            pos += 8
            if id == "data" {
                var length = size
                if rf64 && size == 0xFFFF_FFFF, let d = ds64Data { length = d }
                let available = fileSize > pos ? fileSize - pos : 0
                // a header that was never updated (0) or claims more than there is: everything up to the end of the file
                if length == 0 || length > available { length = available }
                remaining = length
                break
            }
            let body = handle.readData(ofLength: Int(min(size, 1 << 20)))
            if id == "fmt " && body.count >= 16 {
                var tag = Int(body.u16(0))
                if tag == 0xFFFE && body.count >= 26 { tag = Int(body.u16(24)) }   // WAVE_FORMAT_EXTENSIBLE: the real format is in the subformat
                format = (tag, Int(body.u16(2)), Int(body.u32(4)), Int(body.u16(14)), Int(body.u16(12)))
            } else if id == "ds64" && body.count >= 16 {
                ds64Data = body.u64(8)
            }
            pos += size + (size & 1)
            try handle.seek(toOffset: pos)
        }
        guard let format, format.channels > 0, format.rate > 0 else { throw bad("no format description") }
        guard (format.tag == 1 && [8, 16, 24, 32].contains(format.bits)) || (format.tag == 3 && format.bits == 32) else {
            throw bad("unsupported WAV format (\(format.tag), \(format.bits) bit)")
        }
        sampleRate = Double(format.rate)
        channels = format.channels
        bits = format.bits
        isFloat = format.tag == 3
        frameBytes = max(format.block, channels * bits / 8)
        remaining -= remaining % UInt64(frameBytes)   // a half-written frame at the end (crash)
    }

    deinit { try? handle.close() }

    func next(_ frames: Int) throws -> [Float]? {
        guard remaining > 0 else { return nil }
        let want = min(UInt64(frames * frameBytes), remaining)
        let data = handle.readData(ofLength: Int(want))
        let n = data.count / frameBytes
        guard n > 0 else { remaining = 0; return nil }
        remaining -= UInt64(n * frameBytes)
        var out = [Float](repeating: 0, count: n)
        let bytesPer = bits / 8
        let scale = 1 / Float(channels)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<n {
                var sum: Float = 0
                for c in 0..<channels {
                    let o = i * frameBytes + c * bytesPer
                    switch (bits, isFloat) {
                    case (32, true):
                        sum += Float(bitPattern: UInt32(p[o]) | UInt32(p[o + 1]) << 8 | UInt32(p[o + 2]) << 16 | UInt32(p[o + 3]) << 24)
                    case (32, false):
                        sum += Float(Int32(bitPattern: UInt32(p[o]) | UInt32(p[o + 1]) << 8 | UInt32(p[o + 2]) << 16 | UInt32(p[o + 3]) << 24)) / 2_147_483_648
                    case (24, _):
                        let v = Int32(bitPattern: UInt32(p[o]) << 8 | UInt32(p[o + 1]) << 16 | UInt32(p[o + 2]) << 24) >> 8
                        sum += Float(v) / 8_388_608
                    case (16, _):
                        sum += Float(Int16(bitPattern: UInt16(p[o]) | UInt16(p[o + 1]) << 8)) / 32_768
                    default:
                        sum += (Float(p[o]) - 128) / 128
                    }
                }
                out[i] = sum * scale
            }
        }
        return out
    }
}

/// Anything Core Audio can read; for Koe — the AAC ADTS stream. The stream's header doesn't know its length,
/// so it's read to the end. A stream cut off mid-frame (crash) ends where it can still be decoded.
final class CoreAudioSource: AudioSource {
    let sampleRate: Double
    private let channels: Int
    private var file: ExtAudioFileRef?
    private let name: String
    private var done = false

    init(_ url: URL) throws {
        name = url.lastPathComponent
        var f: ExtAudioFileRef?
        try check(ExtAudioFileOpenURL(url as CFURL, &f), "\(name): can't open the audio")
        file = f
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(ExtAudioFileGetProperty(f!, kExtAudioFileProperty_FileDataFormat, &size, &format), "\(name): no format")
        sampleRate = format.mSampleRate
        channels = max(1, Int(format.mChannelsPerFrame))
        var client = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        try check(ExtAudioFileSetProperty(f!, kExtAudioFileProperty_ClientDataFormat,
                                          UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client),
                  "\(name): can't decode")
    }

    deinit { if let file { ExtAudioFileDispose(file) } }

    func next(_ frames: Int) throws -> [Float]? {
        guard !done, let file else { return nil }
        var buffer = [Float](repeating: 0, count: frames * channels)
        var count = UInt32(frames)
        let status: OSStatus = buffer.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            return ExtAudioFileRead(file, &count, &list)
        }
        if status != noErr {
            // the end of a cut-off stream: what was decoded so far is all there is
            recLog("transcription: \(name) can't be decoded further (code \(status)), using what came before")
            done = true
            return nil
        }
        guard count > 0 else { done = true; return nil }
        if channels == 1 { return Array(buffer.prefix(Int(count))) }
        var out = [Float](repeating: 0, count: Int(count))
        let scale = 1 / Float(channels)
        for i in 0..<Int(count) {
            var sum: Float = 0
            for c in 0..<channels { sum += buffer[i * channels + c] }
            out[i] = sum * scale
        }
        return out
    }
}

private extension Data {
    func u16(_ o: Int) -> UInt16 { UInt16(self[startIndex + o]) | UInt16(self[startIndex + o + 1]) << 8 }
    func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) | UInt32(u16(o + 2)) << 16 }
    func u64(_ o: Int) -> UInt64 { UInt64(u32(o)) | UInt64(u32(o + 4)) << 32 }
}
