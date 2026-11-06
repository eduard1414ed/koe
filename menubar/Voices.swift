// Telling voices apart on the system track: who of the other people said each phrase.
//
// The voices come from FluidAudio's offline diarization (pyannote segmentation, WeSpeaker voice prints, VBx
// clustering; chosen over Sortformer, which was more accurate on up to 4 people but slower and limited to 4).
// On top of it, the rules the old koe_speakers.py had:
//   - a voice with less than minSpeakerS of speech in the whole recording isn't a person of its own: its speech goes
//     to the most similar voice (by voice print);
//   - voices are numbered in the order they first spoke: "Speaker 1" spoke first; one voice is just "Speaker";
//   - a phrase gets its voice by the start of its words (Parakeet's word starts are more exact than the ends); where
//     the voice changes inside a phrase, the phrase is split; a single word of another voice between words of one
//     voice isn't a change;
//   - where two people talk at once, the words go to the one heard louder: the voice print of that stretch of sound
//     is compared with the voices of the people talking, and the closest wins (the louder voice is most of the sound).
// The slider in Settings ("Telling voices apart") is the clustering threshold: lower — more voices, higher — fewer.
// Microphones aren't split by voice: one person, one input.
import FluidAudio
import Foundation

enum VoiceTuning {
    static let minSpeakerS = 20.0       // less speech than this in the whole recording — not a speaker of their own
    static let defaultThreshold = 0.6   // FluidAudio's own default (pyannote community-1)
    static let range = 0.3...0.8        // the slider: lower — more voices, higher — fewer
    static let wordProbeS = 0.05        // where in a word its voice is looked up: this far after the start
    static let nearS = 0.5              // a word outside every turn, but this close to one, is that turn's voice
    static let method = "fluidaudio-offline-vbx"
    static let modelRepo = "FluidInference/speaker-diarization-coreml"
}

/// A stretch of one voice. Turns of different voices may overlap: people talk at once.
struct VoiceTurn {
    var start: Double
    var end: Double
    var speaker: Int
}

/// What diarization found: the voices (1… in the order they first spoke) and when each one spoke.
struct VoicesFound {
    var turns: [VoiceTurn] = []
    var speech: [Int: Double] = [:]      // voice → seconds of speech
    var prints: [Int: [Float]] = [:]     // voice → its voice print
    var clusters = 0                     // voices before the minSpeakerS rule
    var merged: [String] = []            // what the minSpeakerS rule did, for the log and raw/*.json
    var count: Int { speech.count }
}

/// Unions overlapping or touching stretches.
func unionSpans(_ spans: [(Double, Double)]) -> [(Double, Double)] {
    var out: [(Double, Double)] = []
    for s in spans.sorted(by: { $0.0 < $1.0 }) {
        if let last = out.last, s.0 <= last.1 {
            out[out.count - 1].1 = max(last.1, s.1)
        } else {
            out.append(s)
        }
    }
    return out
}

func cosine(_ a: [Float], _ b: [Float]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return -1 }
    var ab = 0.0, aa = 0.0, bb = 0.0
    for i in a.indices {
        ab += Double(a[i]) * Double(b[i])
        aa += Double(a[i]) * Double(a[i])
        bb += Double(b[i]) * Double(b[i])
    }
    return aa > 0 && bb > 0 ? ab / (aa * bb).squareRoot() : -1
}

/// The diarization models, loaded once (21 MB, downloaded into <data>/Models/speaker-diarization the first
/// time voices are told apart).
final class VoiceSplitter {
    private let models: OfflineDiarizerModels

    static var downloaded: Bool {
        let dir = SpeechModels.dir.appendingPathComponent(Repo.diarizer.folderName)
        return ModelNames.OfflineDiarizer.requiredModels.allSatisfy {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    init(step: @escaping @Sendable (ModelStep) -> Void) async throws {
        let firstTime = !Self.downloaded
        step(firstTime ? .downloading(nil) : .preparing)
        models = try await OfflineDiarizerModels.load(from: SpeechModels.dir) { p in
            switch p.phase {
            case .downloading where firstTime: step(.downloading(p.fractionCompleted))
            case .compiling: step(.preparing)
            default: break
            }
        }
    }

    private func manager(_ threshold: Double) -> OfflineDiarizerManager {
        var config = OfflineDiarizerConfig()
        config.clustering.threshold = threshold
        // overlapping turns stay: who was louder there is decided by the words (dominantVoices)
        config.postProcessing.exclusiveSegments = false
        let m = OfflineDiarizerManager(config: config)
        m.initialize(models: models)
        return m
    }

    /// The voices in a track (16 kHz mono). progress — the share done (0…1).
    func split(_ audio: [Float], threshold: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> VoicesFound {
        let result = try await manager(threshold).process(audio: audio) { done, total in
            progress(total > 0 ? Double(done) / Double(total) : 1)
        }
        return Self.voices(result.segments.map { ($0.speakerId, Double($0.startTimeSeconds), Double($0.endTimeSeconds), $0.embedding) },
                           prints: result.speakerDatabase ?? [:])
    }

    /// Diarization's turns → voices: the minSpeakerS rule, then numbers in the order of speaking.
    static func voices(_ segments: [(id: String, start: Double, end: Double, embedding: [Float])],
                       prints given: [String: [Float]]) -> VoicesFound {
        var found = VoicesFound()
        var spans: [String: [(Double, Double)]] = [:]
        for s in segments where s.end > s.start { spans[s.id, default: []].append((s.start, s.end)) }
        guard !spans.isEmpty else { return found }
        found.clusters = spans.count
        var speech = spans.mapValues { unionSpans($0).reduce(0) { $0 + $1.1 - $1.0 } }
        // a voice print for each: FluidAudio's, or the mean of its turns' prints
        var prints = given
        for id in spans.keys where prints[id] == nil {
            let es = segments.filter { $0.id == id && !$0.embedding.isEmpty }.map(\.embedding)
            if let n = es.first?.count, es.allSatisfy({ $0.count == n }) {
                prints[id] = (0..<n).map { i in es.reduce(0) { $0 + $1[i] } / Float(es.count) }
            }
        }
        // less than minSpeakerS of speech — to the most similar voice that has enough (if none has, the one that spoke most)
        var owner = Dictionary(uniqueKeysWithValues: spans.keys.map { ($0, $0) })
        let big = speech.filter { $0.value >= VoiceTuning.minSpeakerS }.keys.sorted()
        let keep = big.isEmpty ? [speech.max { $0.value < $1.value }!.key] : big
        for id in speech.keys.sorted() where !keep.contains(id) {
            let to = keep.max { a, b in
                cosine(prints[id] ?? [], prints[a] ?? []) < cosine(prints[id] ?? [], prints[b] ?? [])
            }!
            owner[id] = to
            found.merged.append(String(format: "%@ (%.1f s, similarity %.2f) → %@", id, speech[id]!,
                                       cosine(prints[id] ?? [], prints[to] ?? []), to))
        }
        // numbers by first appearance
        var number: [String: Int] = [:]
        for s in segments.sorted(by: { $0.start < $1.start }) where s.end > s.start {
            let o = owner[s.id]!
            if number[o] == nil { number[o] = number.count + 1 }
        }
        var byVoice: [Int: [(Double, Double)]] = [:]
        for s in segments where s.end > s.start { byVoice[number[owner[s.id]!]!, default: []].append((s.start, s.end)) }
        speech = [:]
        for (v, list) in byVoice {
            let u = unionSpans(list)
            found.turns += u.map { VoiceTurn(start: $0.0, end: $0.1, speaker: v) }
            found.speech[v] = u.reduce(0) { $0 + $1.1 - $1.0 }
        }
        found.turns.sort { ($0.start, $0.speaker) < ($1.start, $1.speaker) }
        for (id, n) in number { found.prints[n] = prints[id] }
        return found
    }

    /// For testing (--voices): diarization once, then clustering at each threshold. Also FluidAudio's own turns.
    func sweep(_ audio: [Float], thresholds: [Double]) async throws -> [(VoicesFound, [(String, Double, Double)], Double)] {
        let t0 = Date()
        let prepared = try await manager(thresholds[0]).prepare(audio: audio)
        tlog(String(format: "voices: segmentation and voice prints %.1f s", Date().timeIntervalSince(t0)))
        return try thresholds.map { th in
            let t1 = Date()
            let r = try manager(th).cluster(prepared)
            let segs = r.segments.map { ($0.speakerId, Double($0.startTimeSeconds), Double($0.endTimeSeconds), $0.embedding) }
            return (Self.voices(segs, prints: r.speakerDatabase ?? [:]), segs.map { ($0.0, $0.1, $0.2) }, Date().timeIntervalSince(t1))
        }
    }

    /// For stretches where several voices talk at once: the voice whose print is closest to the sound there.
    func dominantVoices(_ audio: [Float], spans: [(Double, Double)], candidates: [[Int]], prints: [Int: [Float]]) async throws -> [Int] {
        guard !spans.isEmpty else { return [] }
        let duration = Double(audio.count) / Double(asrRate)
        let ranges = spans.map { s -> Range<TimeInterval> in
            let a = max(0, min(s.0, duration - 0.05)), b = min(duration, max(s.1, a + 0.05))
            return a..<b
        }
        let heard = try await manager(VoiceTuning.defaultThreshold).embedSpans(audioSource: ArrayAudioSampleSource(samples: audio),
                                                                              spans: ranges)
        return zip(heard, candidates).map { e, cands in
            cands.max { cosine(e, prints[$0] ?? []) < cosine(e, prints[$1] ?? []) } ?? cands[0]
        }
    }
}

// ---------- phrases → voices ----------

/// Which voices speak at moment t: the turns that cover it; outside every turn — the nearest one.
func voicesAt(_ t: Double, _ turns: [VoiceTurn]) -> [Int] {
    let covering = turns.filter { $0.start <= t && t < $0.end }.map(\.speaker)
    if !covering.isEmpty { return Array(Set(covering)).sorted() }
    func dist(_ x: VoiceTurn) -> Double { min(abs(t - x.start), abs(t - x.end)) }
    guard let near = turns.min(by: { dist($0) < dist($1) }) else { return [] }
    if dist(near) <= VoiceTuning.nearS { return [near.speaker] }
    // far from every turn: any voice, the voice print decides
    return Array(Set(turns.map(\.speaker))).sorted()
}

/// Every phrase gets its voice (Segment.speaker), by the start of each word; where the voice changes inside a phrase,
/// it's split. Words where several voices talk at once go to dominant: it gets the stretches of such words and the
/// voices talking there, and returns the one heard there. Returns the phrases and how many words were in overlaps.
func assignVoices(_ segments: [Segment], _ turns: [VoiceTurn],
                  dominant: ([(Double, Double)], [[Int]]) async throws -> [Int]) async rethrows -> ([Segment], Int) {
    guard !turns.isEmpty else { return (segments, 0) }
    // the voices at each word; runs of words with the same several voices are asked about together
    var cands: [[[Int]]] = []
    var spans: [(Double, Double)] = [], spanCands: [[Int]] = [], spanOf: [[Int?]] = []
    var overlapWords = 0
    for seg in segments {
        let c = seg.words.isEmpty ? [voicesAt((seg.start + seg.end) / 2, turns)]
                                  : seg.words.map { voicesAt($0.start + min(VoiceTuning.wordProbeS, ($0.end - $0.start) / 2), turns) }
        var marks: [Int?] = []
        for (i, v) in c.enumerated() {
            guard v.count > 1 else { marks.append(nil); continue }
            overlapWords += 1
            let (a, b) = seg.words.isEmpty ? (seg.start, seg.end) : (seg.words[i].start, seg.words[i].end)
            if i > 0, c[i - 1] == v, let k = marks[i - 1] {
                spans[k].1 = b
            } else {
                spans.append((a, b))
                spanCands.append(v)
            }
            marks.append(spans.count - 1)
        }
        cands.append(c)
        spanOf.append(marks)
    }
    let picked = try await dominant(spans, spanCands)
    var out: [Segment] = []
    for (k, seg) in segments.enumerated() {
        var labs = cands[k].enumerated().map { i, v in spanOf[k][i].map { picked[$0] } ?? v.first ?? 0 }
        // a single word of another voice between words of one voice isn't a change
        if labs.count > 2 {
            for i in 1..<(labs.count - 1) where labs[i - 1] == labs[i + 1] && labs[i] != labs[i - 1] { labs[i] = labs[i - 1] }
        }
        if seg.words.isEmpty || Set(labs).count == 1 {
            var s = seg
            s.speaker = labs.first
            out.append(s)
            continue
        }
        var i = 0
        while i < labs.count {
            var j = i
            while j + 1 < labs.count && labs[j + 1] == labs[i] { j += 1 }
            let ws = Array(seg.words[i...j])
            let probs = ws.compactMap(\.probability)
            var s = Segment(start: ws[0].start, end: ws[ws.count - 1].end, text: ws.map(\.word).joined(separator: " "), words: ws,
                            confidence: probs.isEmpty ? nil : probs.reduce(0, +) / Double(probs.count))
            s.speaker = labs[i]
            s.splitBySpeaker = true
            s.replaced = seg.replaced.filter { p in ws.contains { $0.word == p.1 } }
            out.append(s)
            i = j + 1
        }
    }
    return (out, overlapWords)
}

/// The default labels of the voices: one — "Speaker", several — "Speaker 1", "Speaker 2"…
func voiceLabels(_ other: String, count: Int) -> [Int: String] {
    count == 1 ? [1: other] : Dictionary(uniqueKeysWithValues: (1...max(1, count)).map { ($0, "\(other) \($0)") })
}

/// A progress callback handed to FluidAudio, which may call it from any thread (ours don't mind).
final class UncheckedProgress: @unchecked Sendable {
    private let f: (Double) -> Void
    init(_ f: @escaping (Double) -> Void) { self.f = f }
    func call(_ x: Double) { f(x) }
}
