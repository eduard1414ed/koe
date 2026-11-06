// The speech recognizer and the speech detector, and where their models live.
//
// Recognition is behind one interface (TranscriptionEngine), so the engine can be swapped. The engine
// now is FluidAudio with Parakeet Ultra (chosen after comparing it with WhisperKit on real recordings): it gets each piece of speech
// without a language — it writes every word in its own language — and returns the text with the time of
// each word.
//
// The speech detector is Silero from FluidAudio, but the cutting into pieces is ours, the same as the
// old pipeline's (silero_vad.get_speech_timestamps + joining neighbors): FluidAudio gives one speech
// probability per 256 ms (we make it 128 ms, see probabilities), and Tuning has the old pipeline's settings.
//
// Models are downloaded the first time they're needed into <data folder>/Models.
import AppKit
@preconcurrency import FluidAudio
import Foundation

/// The FluidAudio version — the same as in Package.swift (it's pinned exactly). Written to meta.json.
let fluidAudioVersion = "0.18.0"

/// The fine-tuning of the old pipeline (its config.toml). The same values; not in the interface.
enum Tuning {
    // speech detector
    static let threshold: Float = 0.5      // sensitivity (0..1, higher is stricter)
    static let minSpeechMs = 250.0         // anything shorter isn't speech, just a click
    static let minSilenceMs = 500.0        // a pause shorter than this doesn't split speech
    static let padMs = 200.0               // margin around pieces so word beginnings aren't cut off
    static let joinGapS = 2.0              // speech pieces with a shorter pause than this are transcribed together
    static let maxChunkS = 29.0            // the longest piece given to the recognizer
    // the transcript
    static let mergeGapS = 30.0            // one person's lines are merged if the pause is no longer than this
    static let maxLineS = 120.0            // but no longer than this: a long monologue gets paragraphs with their own timestamps
    // phrases inside a piece (Parakeet returns the whole piece as one line)
    static let phrasePauseS = 1.0          // a pause between words this long starts a new phrase
    static let phraseCommaS = 10.0         // a phrase this long ends at the next comma

    static var vadJSON: [String: Any] {
        ["threshold": threshold, "min_speech_ms": Int(minSpeechMs), "min_silence_ms": Int(minSilenceMs),
         "pad_ms": Int(padMs), "join_gap_s": joinGapS, "max_chunk_s": maxChunkS]
    }
}

struct Word {
    var word: String
    var start: Double
    var end: Double
    var probability: Double?
}

/// What the engine heard in one piece of audio. Times are from the start of the piece.
struct Heard {
    var text: String
    var words: [Word]
    var confidence: Double?
    /// What the vocabulary changed: the words Parakeet wrote → the vocabulary's word.
    var replaced: [(String, String)] = []
}

protocol TranscriptionEngine: AnyObject {
    var name: String { get }
    var model: String { get }
    /// Words to spell right (Settings → Vocabulary and the tracks' names), for the next pieces; [] — none.
    /// Returns the words the engine took (a hint may not fit every word).
    func setVocabulary(_ terms: [String], step: @escaping @Sendable (ModelStep) -> Void) async throws -> [String]
    func transcribe(_ samples: [Float]) async throws -> Heard
}

// ---------- models ----------

/// Where the models are and getting them. FluidAudio can download into any folder: the recognizer goes into
/// <data>/Models/<its folder>, the speech detector into <data>/Models/silero-vad.
enum SpeechModels {
    static let dir = Identity.supportDir.appendingPathComponent("Models")
    /// FluidAudio puts the files next to this path, in a folder named after the model (parakeet-ultra…).
    static let asrDir = dir.appendingPathComponent("parakeet-ultra")
    static let version = AsrModelVersion.ultra
    static let modelName = "parakeet-ultra"
    static let modelRepo = "FluidInference/parakeet-ultra-coreml"

    static var downloaded: Bool { AsrModels.modelsExist(at: asrDir, version: version) }

    /// The vocabulary model (Parakeet CTC 110M, ~99 MB): only downloaded once Settings → Vocabulary has words.
    static let vocabularyVariant = CtcModelVariant.ctc110m
    static let vocabularyDir = dir.appendingPathComponent(vocabularyVariant.repo.folderName)
    static let vocabularyRepo = vocabularyVariant.repo.rawValue
}

/// What getting the models is doing now: downloading (share 0…1, nil — not known yet) or preparing them for this Mac.
enum ModelStep: Equatable {
    case downloading(Double?)
    case preparing
}

/// Parakeet (FluidAudio) — the recognizer.
final class ParakeetEngine: TranscriptionEngine {
    let name = "fluidaudio"
    let model = SpeechModels.modelName
    private let asr: AsrManager

    /// Downloads the model if it isn't there yet and loads it. step — what's going on, for the menu (any thread).
    init(step: @escaping @Sendable (ModelStep) -> Void) async throws {
        let firstTime = !SpeechModels.downloaded
        if firstTime { step(.downloading(nil)) } else { step(.preparing) }
        // the first ModelHub pass downloads all files of the model (the first half of its share), then each
        // part is prepared for this Mac; later passes find the files and only prepare
        let seen = Progress()
        let models = try await AsrModels.downloadAndLoad(to: SpeechModels.asrDir, version: SpeechModels.version) { p in
            switch p.phase {
            case .listing: if firstTime && !seen.preparing { step(.downloading(seen.fraction)) }
            case .downloading:
                guard firstTime, !seen.preparing else { return }
                seen.fraction = max(seen.fraction ?? 0, min(1, p.fractionCompleted * 2))
                step(.downloading(seen.fraction))
            case .compiling:
                if !seen.preparing { seen.preparing = true; step(.preparing) }
            }
        }
        asr = AsrManager(config: .default)
        try await asr.loadModels(models)
    }

    /// Tracks the download share across FluidAudio's calls (the handler may come on any thread).
    private final class Progress: @unchecked Sendable {
        var fraction: Double?
        var preparing = false
    }

    func transcribe(_ samples: [Float]) async throws -> Heard {
        // Parakeet wants at least 1 s; a shorter piece gets silence at the end
        var input = samples
        if input.count < asrRate { input += [Float](repeating: 0, count: asrRate - input.count) }
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        // no language: Parakeet writes each word in its own language (with a language, English words go Cyrillic)
        let result = try await asr.transcribe(input, decoderState: &state, language: nil)
        let timings = result.tokenTimings ?? []
        var words = buildWordTimings(from: timings).map { w -> Word in
            let tokens = timings.filter { $0.startTime >= w.startTime && $0.startTime <= w.endTime }
            let conf = tokens.isEmpty ? nil : Double(tokens.map(\.confidence).reduce(0, +)) / Double(tokens.count)
            return Word(word: w.word, start: w.startTime, end: w.endTime, probability: conf)
        }
        var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var replaced: [(String, String)] = []
        if let vocabulary {
            (words, replaced) = await vocabulary.rescore(text: text, timings: timings, words: words, audio: input)
            if !replaced.isEmpty { text = words.map(\.word).joined(separator: " ") }
        }
        return Heard(text: text, words: words, confidence: Double(result.confidence), replaced: replaced)
    }

    func unload() async { await asr.cleanup() }

    // ---------- the vocabulary ----------

    private var vocabulary: Vocabulary?

    func setVocabulary(_ terms: [String], step: @escaping @Sendable (ModelStep) -> Void) async throws -> [String] {
        if terms.isEmpty {
            vocabulary = nil
            return []
        }
        if let vocabulary, vocabulary.asked == terms { return vocabulary.terms }
        vocabulary = try await Vocabulary(terms, step: step)
        return vocabulary?.terms ?? []
    }
}

/// Settings → Vocabulary through FluidAudio's vocabulary boosting: a second, small model (Parakeet CTC 110M) listens
/// to the piece for the words from the list, and where Parakeet wrote a similar word and the list's word sounds more
/// likely, the word is replaced. It only knows the Latin alphabet: words without Latin letters are left out.
///
/// FluidAudio's VocabularyBoostingSession is the same thing, but it always looks for the model in
/// ~/Library/Application Support/FluidAudio; here its parts are put together with the model in <data>/Models.
///
/// One rule of our own: real English words (the Mac's spelling dictionary) aren't replaced. Without it ordinary words
/// turned into similar words from the list ("parcel" → "Vercel", "motion" → "Notion", "database" → "Supabase", and
/// with "Koe" in the list, "code was removed" → "Koe"). Several real words are replaced only when together they're
/// spelled almost like the list's word ("tail scale" → "Tailscale"). The price: a term heard as a real word
/// ("Ark" for "Arc") stays as heard.
final class Vocabulary {
    let asked: [String]
    let terms: [String]
    private let context: CustomVocabularyContext
    private let spotter: CtcKeywordSpotter
    private let rescorer: VocabularyRescorer
    private let sizeConfig: ContextBiasingConstants.VocabSizeConfig

    init?(_ asked: [String], step: @escaping @Sendable (ModelStep) -> Void) async throws {
        self.asked = asked
        let dir = SpeechModels.vocabularyDir
        if !CtcModels.modelsExist(at: dir) { step(.downloading(nil)) }
        try await CtcModels.download(to: dir, variant: SpeechModels.vocabularyVariant)
        step(.preparing)
        let models = try await CtcModels.load(from: dir, variant: SpeechModels.vocabularyVariant)
        let tokenizer = try await CtcTokenizer.load(from: dir)
        let usable = asked.compactMap { t -> CustomVocabularyTerm? in
            let ids = tokenizer.encode(t)
            return ids.isEmpty ? nil : CustomVocabularyTerm(text: t, ctcTokenIds: ids)
        }
        guard !usable.isEmpty else { return nil }
        terms = usable.map(\.text)
        context = CustomVocabularyContext(terms: usable)
        spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        sizeConfig = ContextBiasingConstants.rescorerConfig(forVocabSize: usable.count)
        rescorer = try await VocabularyRescorer.create(spotter: spotter, vocabulary: context, ctcModelDirectory: dir)
    }

    /// The piece's words with the list's words put in (each keeps the time of the words it replaced), and what was
    /// replaced with what. Any failure leaves the words as they were: the hint must never break transcription.
    func rescore(text: String, timings: [TokenTiming], words: [Word], audio: [Float]) async -> ([Word], [(String, String)]) {
        let minSimilarity = max(sizeConfig.minSimilarity, context.minSimilarity)
        guard !timings.isEmpty,
              rescorer.hasCTCRescoringCandidates(transcript: text, tokenTimings: timings, minSimilarity: minSimilarity),
              let spot = try? await spotter.spotKeywordsWithLogProbs(audioSamples: audio, customVocabulary: context),
              !spot.logProbs.isEmpty else { return (words, []) }
        let out = rescorer.ctcTokenRescore(transcript: text, tokenTimings: timings, logProbs: spot.logProbs,
                                           frameDuration: spot.frameDuration, cbw: sizeConfig.cbw,
                                           marginSeconds: 0.5, minSimilarity: minSimilarity)
        guard out.wasModified else { return (words, []) }
        return Self.apply(out.replacements.compactMap { r in
            guard r.shouldReplace, let new = r.replacementWord else { return nil }
            let parts = r.originalWord.split(separator: " ").map(String.init)
            if parts.allSatisfy(Self.isEnglishWord) && (parts.count == 1 || Self.similarity(parts.joined(), new) < 0.8) {
                tlog("  vocabulary: kept \"\(r.originalWord)\" (real words), not \"\(new)\"")
                return nil
            }
            return (r.originalWord, new)
        }, to: words)
    }

    /// How alike two spellings are (case, spaces and punctuation aside): 1 — the same, 0 — nothing in common.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.lowercased().filter { $0.isLetter || $0.isNumber })
        let y = Array(b.lowercased().filter { $0.isLetter || $0.isNumber })
        guard !x.isEmpty, !y.isEmpty else { return x == y ? 1 : 0 }
        // edit distance, one row at a time
        var row = Array(0...y.count)
        for i in 1...x.count {
            var diagonal = row[0]
            row[0] = i
            for j in 1...y.count {
                let above = row[j]
                row[j] = min(above + 1, row[j - 1] + 1, diagonal + (x[i - 1] == y[j - 1] ? 0 : 1))
                diagonal = above
            }
        }
        return 1 - Double(row[y.count]) / Double(max(x.count, y.count))
    }

    /// The Mac's English spelling dictionary knows the word.
    static func isEnglishWord(_ word: String) -> Bool {
        let w = word.trimmingCharacters(in: .punctuationCharacters)
        let check = {
            NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0, language: "en", wrap: false,
                                                inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
        return Thread.isMainThread ? check() : DispatchQueue.main.sync(execute: check)
    }

    /// Put the replacements (original words → the list's word) into the words: the replaced words become one word
    /// with their times, keeping the punctuation around them ("Ark," → "Arc,").
    static func apply(_ replacements: [(String, String)], to words: [Word]) -> ([Word], [(String, String)]) {
        func bare(_ w: String) -> String { w.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        var taken = [Bool](repeating: false, count: words.count)
        var spans: [(Range<Int>, String)] = []
        var done: [(String, String)] = []
        for (original, new) in replacements {
            let want = original.split(separator: " ").map { bare(String($0)) }
            guard !want.isEmpty, want.count <= words.count else { continue }
            let found = (0...(words.count - want.count)).first { i in
                (i..<(i + want.count)).allSatisfy { !taken[$0] && bare(words[$0].word) == want[$0 - i] }
            }
            guard let i = found else {
                tlog("  vocabulary: couldn't place \"\(original)\" → \"\(new)\" in the words")
                continue
            }
            let r = i..<(i + want.count)
            for k in r { taken[k] = true }
            let first = words[r.lowerBound].word, last = words[r.upperBound - 1].word
            let lead = String(first.prefix { $0.isPunctuation || $0.isSymbol })
            let trail = String(last.reversed().prefix { $0.isPunctuation || $0.isSymbol }.reversed())
            var word = new
            if !lead.isEmpty && !word.hasPrefix(lead) { word = lead + word }
            if !trail.isEmpty && !word.hasSuffix(trail) { word += trail }
            spans.append((r, word))
            done.append((r.map { words[$0].word }.joined(separator: " "), word))
        }
        guard !spans.isEmpty else { return (words, []) }
        var out: [Word] = []
        var i = 0
        for (r, word) in spans.sorted(by: { $0.0.lowerBound < $1.0.lowerBound }) {
            out += words[i..<r.lowerBound]
            let ws = words[r]
            let probs = ws.compactMap(\.probability)
            out.append(Word(word: word, start: ws.first!.start, end: ws.last!.end,
                            probability: probs.isEmpty ? nil : probs.reduce(0, +) / Double(probs.count)))
            i = r.upperBound
        }
        out += words[i...]
        return (out, done)
    }
}

// ---------- the speech detector ----------

final class SpeechDetector {
    private let vad: VadManager
    static let frame = VadManager.chunkSize   // 4096 samples = 256 ms: one probability per frame

    init() async throws {
        // VadManager looks in <folder>/Models/silero-vad and downloads there (~1 MB) if it's not there
        vad = try await VadManager(config: .default, modelDirectory: Identity.supportDir)
    }

    /// Speech probability for every 128 ms (hop). The model gives one per 256 ms frame, so it runs twice: on the track
    /// and on the track shifted by half a frame; each half-frame gets the lower of the two frames that cover it. That
    /// halves how far the speech edges can be off. progress — the share done (0…1). Stops if the task is cancelled.
    static let hop = frame / 2

    func probabilities(_ samples: [Float], progress: (Double) -> Void) async throws -> [Float] {
        let a = try await pass(samples, from: 0) { progress($0 / 2) }
        let b = try await pass(samples, from: Self.hop) { progress(0.5 + $0 / 2) }
        let n = (samples.count + Self.hop - 1) / Self.hop
        return (0..<n).map { j in
            let pa = a[min(a.count - 1, j / 2)]
            guard j >= 1, !b.isEmpty else { return pa }
            return min(pa, b[min(b.count - 1, (j - 1) / 2)])
        }
    }

    private func pass(_ samples: [Float], from start: Int, progress: (Double) -> Void) async throws -> [Float] {
        var state = await vad.makeStreamState()
        var probs: [Float] = []
        probs.reserveCapacity(samples.count / Self.frame + 1)
        var i = start
        while i < samples.count {
            let end = min(i + Self.frame, samples.count)
            let r = try await vad.processStreamingChunk(Array(samples[i..<end]), state: state)
            state = r.state
            probs.append(r.probability)
            i = end
            if probs.count % 200 == 0 {
                try Task.checkCancellation()
                progress(Double(i) / Double(samples.count))
            }
        }
        return probs
    }

    /// Speech regions in seconds — silero_vad's get_speech_timestamps (version 6) step by step, on 128 ms steps.
    static func regions(_ probs: [Float], samples: Int) -> [(Double, Double)] {
        let window = hop
        let sr = Double(asrRate)
        let minSpeech = sr * Tuning.minSpeechMs / 1000
        let pad = sr * Tuning.padMs / 1000
        let maxSpeech = sr * Tuning.maxChunkS - Double(window) - 2 * pad
        let minSilence = sr * Tuning.minSilenceMs / 1000
        let minSilenceAtMax = sr * 98 / 1000
        let threshold = Tuning.threshold
        let negThreshold = max(threshold - 0.15, 0.01)
        var triggered = false
        var speeches: [(start: Int, end: Int)] = []
        var start: Int?      // the current speech's start (Python: current_speech['start'])
        var tempEnd = 0, prevEnd = 0, nextStart = 0
        var possibleEnds: [(Int, Int)] = []
        for (i, p) in probs.enumerated() {
            let cur = window * i
            if p >= threshold && tempEnd != 0 {
                let silence = cur - tempEnd
                if Double(silence) > minSilenceAtMax { possibleEnds.append((tempEnd, silence)) }
                tempEnd = 0
                if nextStart < prevEnd { nextStart = cur }
            }
            if p >= threshold && !triggered {
                triggered = true
                start = cur
                continue
            }
            if triggered, let s = start, Double(cur - s) > maxSpeech {
                // the longest pause inside the speech so far; none — cut right here
                if let best = possibleEnds.max(by: { $0.1 < $1.1 }) {
                    prevEnd = best.0
                    speeches.append((s, prevEnd))
                    start = nil
                    nextStart = prevEnd + best.1
                    if nextStart < prevEnd + cur { start = nextStart } else { triggered = false }
                    prevEnd = 0; nextStart = 0; tempEnd = 0
                    possibleEnds = []
                } else {
                    speeches.append((s, cur))
                    start = nil
                    prevEnd = 0; nextStart = 0; tempEnd = 0
                    triggered = false
                    possibleEnds = []
                    continue
                }
            }
            if p < negThreshold && triggered {
                if tempEnd == 0 { tempEnd = cur }
                if Double(cur - tempEnd) < minSilence { continue }
                if let s = start, Double(tempEnd - s) > minSpeech { speeches.append((s, tempEnd)) }
                start = nil
                prevEnd = 0; nextStart = 0; tempEnd = 0
                triggered = false
                possibleEnds = []
                continue
            }
        }
        if let s = start, Double(samples - s) > minSpeech { speeches.append((s, samples)) }
        // margins: half of a short pause to each side, otherwise pad
        for i in speeches.indices {
            if i == 0 { speeches[i].start = Int(max(0, Double(speeches[i].start) - pad)) }
            if i != speeches.count - 1 {
                let silence = speeches[i + 1].start - speeches[i].end
                if Double(silence) < 2 * pad {
                    speeches[i].end += silence / 2
                    speeches[i + 1].start = max(0, speeches[i + 1].start - silence / 2)
                } else {
                    speeches[i].end = Int(min(Double(samples), Double(speeches[i].end) + pad))
                    speeches[i + 1].start = Int(max(0, Double(speeches[i + 1].start) - pad))
                }
            } else {
                speeches[i].end = Int(min(Double(samples), Double(speeches[i].end) + pad))
            }
        }
        return speeches.map { (Double($0.start) / sr, Double($0.end) / sr) }
    }

    /// Neighbor regions with a short pause go together (the recognizer understands a whole phrase better),
    /// but a piece is never longer than maxChunkS.
    static func chunks(_ regions: [(Double, Double)]) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        for (s, e) in regions {
            if let last = out.last, s - last.1 < Tuning.joinGapS, e - last.0 <= Tuning.maxChunkS {
                out[out.count - 1].1 = e
            } else {
                out.append((s, e))
            }
        }
        return out
    }
}
