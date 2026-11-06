// A WAV file (PCM, 24 bit) that survives a crash and isn't stuck at 4 GB.
//
// An ordinary WAV header keeps the file's lengths in 32 bits and is only right once the file is closed.
// Here the header always has the same 80 bytes: RIFF, a 28-byte JUNK chunk, fmt, data. The lengths
// are rewritten every ~2 seconds and on close, so a crash leaves a file that plays up to the last
// couple of seconds — and repair() (recovery after a crash) sets them from the file size anyway.
// When the file outgrows 4 GB it becomes RF64 (EBU Tech 3306): "RIFF" → "RF64", JUNK → ds64 with
// 64-bit lengths, and the 32-bit lengths turn into 0xFFFFFFFF. QuickTime, ffmpeg and audio editors read it.
import AVFoundation

final class WavWriter {
    static let headerSize = 80
    static let headerInterval = 2.0
    let sampleRate: Int
    let channels: Int
    var blockAlign: Int { channels * 3 }
    private(set) var dataBytes: UInt64 = 0
    /// Above how many bytes of RIFF length the file turns into RF64. Lower only in the writer test.
    let rf64Above: UInt64
    private var fd: Int32
    private var lastHeader = ProcessInfo.processInfo.systemUptime

    init(url: URL, sampleRate: Int, channels: Int, rf64Above: UInt64 = UInt64(UInt32.max)) throws {
        self.sampleRate = sampleRate
        self.channels = channels
        self.rf64Above = rf64Above
        fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw RecorderError(String(localized: "Couldn't create the audio file (code \(errno))")) }
        try writeHeader()
        // the header goes in with pwrite, which doesn't move the file position: the samples start after it
        lseek(fd, off_t(WavWriter.headerSize), SEEK_SET)
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }

    var frames: Int64 { Int64(dataBytes / UInt64(blockAlign)) }

    /// Float32 non-interleaved with the file's channel count → 24-bit interleaved samples.
    func write(_ buf: AVAudioPCMBuffer) throws {
        let n = Int(buf.frameLength)
        guard n > 0, let src = buf.floatChannelData, Int(buf.format.channelCount) == channels else { return }
        var bytes = [UInt8](repeating: 0, count: n * blockAlign)
        var k = 0
        for i in 0..<n {
            for c in 0..<channels {
                let v = Int32((max(-1, min(1, src[c][i])) * 8_388_607).rounded())
                bytes[k] = UInt8(truncatingIfNeeded: v)
                bytes[k + 1] = UInt8(truncatingIfNeeded: v >> 8)
                bytes[k + 2] = UInt8(truncatingIfNeeded: v >> 16)
                k += 3
            }
        }
        try append(bytes)
    }

    func writeSilence(frames: Int64) throws {
        var left = frames
        while left > 0 {
            let n = min(left, 48_000)
            try append([UInt8](repeating: 0, count: Int(n) * blockAlign))
            left -= n
        }
    }

    private func append(_ bytes: [UInt8]) throws {
        var done = 0
        try bytes.withUnsafeBytes { p in
            while done < p.count {
                let r = Darwin.write(fd, p.baseAddress! + done, p.count - done)
                if r < 0 {
                    if errno == EINTR { continue }
                    throw RecorderError(String(localized: "Couldn't write the audio file (code \(errno))"))
                }
                done += r
            }
        }
        dataBytes += UInt64(bytes.count)
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastHeader >= WavWriter.headerInterval {
            lastHeader = now
            try writeHeader()
        }
    }

    /// Final lengths, the pad byte after odd-sized data (RIFF wants chunks of even length), close.
    func close() {
        guard fd >= 0 else { return }
        if dataBytes % 2 == 1 { _ = Darwin.write(fd, [UInt8(0)], 1) }
        try? writeHeader(padded: dataBytes % 2 == 1)
        Darwin.close(fd)
        fd = -1
    }

    private func writeHeader(padded: Bool = false) throws {
        let h = WavWriter.header(dataBytes: dataBytes, sampleRate: sampleRate, channels: channels,
                                 padded: padded, rf64Above: rf64Above)
        let r = h.withUnsafeBytes { pwrite(fd, $0.baseAddress!, h.count, 0) }
        if r != h.count { throw RecorderError(String(localized: "Couldn't write the audio file (code \(errno))")) }
    }

    static func header(dataBytes: UInt64, sampleRate: Int, channels: Int, padded: Bool = false,
                       rf64Above: UInt64 = UInt64(UInt32.max)) -> [UInt8] {
        var h: [UInt8] = []
        func tag(_ s: String) { h += Array(s.utf8) }
        func u16(_ v: Int) { h += [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)] }
        func u32(_ v: UInt64) { for i in 0..<4 { h.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) } }
        func u64(_ v: UInt64) { for i in 0..<8 { h.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) } }
        let riffSize = UInt64(headerSize - 8) + dataBytes + (padded ? 1 : 0)
        let rf64 = riffSize > rf64Above
        let blockAlign = channels * 3
        tag(rf64 ? "RF64" : "RIFF"); u32(rf64 ? 0xFFFF_FFFF : riffSize); tag("WAVE")
        // 28 bytes: room for ds64 (RIFF size, data size, sample count, table length)
        tag(rf64 ? "ds64" : "JUNK"); u32(28)
        if rf64 {
            u64(riffSize); u64(dataBytes); u64(dataBytes / UInt64(blockAlign)); u32(0)
        } else {
            h += [UInt8](repeating: 0, count: 28)
        }
        tag("fmt "); u32(16)
        u16(1); u16(channels); u32(UInt64(sampleRate)); u32(UInt64(sampleRate * blockAlign)); u16(blockAlign); u16(24)
        tag("data"); u32(rf64 ? 0xFFFF_FFFF : dataBytes)
        return h
    }

    /// After a crash: set the lengths in the header from the file size (an unfinished last frame is cut off).
    /// Only for files from this writer. Returns the frame count, the sample rate and the channels.
    static func repair(_ url: URL) -> (frames: Int64, sampleRate: Int, channels: Int)? {
        let fd = open(url.path, O_RDWR)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var h = [UInt8](repeating: 0, count: headerSize)
        guard h.withUnsafeMutableBytes({ pread(fd, $0.baseAddress!, headerSize, 0) }) == headerSize else { return nil }
        func tag(_ at: Int) -> String { String(decoding: h[at..<at + 4], as: UTF8.self) }
        func u16(_ at: Int) -> Int { Int(h[at]) | Int(h[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        guard ["RIFF", "RF64"].contains(tag(0)), tag(8) == "WAVE", tag(48) == "fmt ", tag(72) == "data",
              u16(56 + 14) == 24 else { return nil }
        let channels = u16(56 + 2), rate = u32(56 + 4)
        guard channels > 0, rate > 0 else { return nil }
        let size = lseek(fd, 0, SEEK_END)
        guard size >= headerSize else { return nil }
        let block = UInt64(channels * 3)
        let data = UInt64(size - off_t(headerSize)) / block * block
        guard ftruncate(fd, off_t(headerSize) + off_t(data)) == 0 else { return nil }
        let fixed = header(dataBytes: data, sampleRate: rate, channels: channels)
        guard fixed.withUnsafeBytes({ pwrite(fd, $0.baseAddress!, fixed.count, 0) }) == fixed.count else { return nil }
        return (Int64(data / block), rate, channels)
    }
}
