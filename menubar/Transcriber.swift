// Transcribing one recording (its folder with the tracks and session.json) into a transcript folder:
// transcript.md, and .koe/raw/<track>.json and .koe/meta.json (MeetingFolder.swift) — the same kind as the old
// Python pipeline wrote (it was removed in stage 7). Step by step:
//   1. every track that's transcribed → 16 kHz mono, the encoder's silence cut off and the track moved to
//      where it started on the recording's timeline (session.json), so the tracks' lines go side by side;
//   2. the speech detector finds speech, the pieces go to the recognizer;
//   3. each piece is split into phrases (by punctuation and pauses between words);
//   4. known hallucinations are thrown out (the 70% rule), so is the other side's voice that leaked from the
//      speakers into a microphone (echo), and a phrase two microphones in one room both heard stays only where
//      it's louder; everything thrown out stays in raw/*.json under "filtered";
//   5. the system track's phrases get the voice that said them: "Speaker 1, 2…" (Voices.swift);
//   6. lines are merged (one person, a pause ≤ 30 s) and a monologue gets a new timestamp every ~2 minutes.
// Settings → Vocabulary (plus the microphone tracks' names) goes to the recognizer as a hint (Engine.swift, Vocabulary).
// Names from speakers.json (the Names window) stay when a recording is transcribed again.
import CryptoKit
import Foundation

let pipelineVersion = "2"   // 1 — the Python pipeline (Whisper), 2 — this one

struct TranscriberError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

/// The recording was transcribed before, into this folder (and it wasn't asked to do it again).
struct AlreadyProcessed: Error { let dir: URL }

/// A phrase of a track: what goes into raw/<track>.json.
struct Segment {
    var start: Double
    var end: Double
    var text: String
    var words: [Word]
    var confidence: Double?
    var reason: String?
    var replaced: [(String, String)] = []   // what the vocabulary changed
    var speaker: Int?                       // the voice on the system track (Voices.swift)
    var splitBySpeaker = false              // a part of a phrase where the voice changed

    var json: [String: Any] {
        var d: [String: Any] = [
            "start": round3(start), "end": round3(end), "text": text,
            "words": words.map { w in
                ["word": w.word, "start": round3(w.start), "end": round3(w.end),
                 "probability": w.probability.map(round3) ?? NSNull()] as [String: Any]
            },
        ]
        if let confidence { d["confidence"] = round3(confidence) }
        if let reason { d["reason"] = reason }
        if !replaced.isEmpty { d["vocabulary"] = replaced.map { [$0.0, $0.1] } }
        if let speaker { d["speaker"] = speaker }
        if splitBySpeaker { d["split_by_speaker"] = true }
        return d
    }
}

/// One track of the recording while it's being transcribed.
final class TrackRun {
    let number: Int
    let role: String        // mic / system
    let id: String          // mic, mic-2…, system (the "username" in raw/*.json)
    let name: String
    let nameFixed: Bool     // the name from Settings → Inputs: updating names doesn't touch it
    let audioFile: String
    let transcribe: Bool
    let input: Any?
    let startOffset: Double
    let devices: Any
    let delay: Double       // the encoder's silence at the start of the file, seconds
    var duration = 0.0
    var language: String?
    var script: [String: Double] = [:]
    var regions: [(Double, Double)] = []
    var chunks: [(Double, Double)] = []
    var segments: [Segment] = []
    var filtered: [Segment] = []
    var elapsed = 0.0
    var rawFile = ""
    /// The track's loudness: mean square of the samples in every levelFrame seconds (for repeats between microphones).
    var levels: [Float] = []
    /// Voices told apart (the system track): id, label, name, seconds of speech; and how it was done.
    var speakers: [(id: Int, label: String, name: String, speech: Double)] = []
    var diarization: [String: Any]?

    init(number: Int, role: String, id: String, name: String, nameFixed: Bool, info: [String: Any]) {
        self.number = number
        self.role = role
        self.id = id
        self.name = name
        self.nameFixed = nameFixed
        audioFile = info["file"] as? String ?? ""
        transcribe = info["transcribe"] as? Bool != false
        input = info["input"]
        startOffset = (info["start_offset_s"] as? NSNumber)?.doubleValue ?? 0
        devices = info["devices"] ?? []
        // in the file's frames: 2112 for AAC, 0 for WAV
        let rate = (info["sample_rate"] as? NSNumber)?.doubleValue ?? 48_000
        delay = ((info["encoder_delay_frames"] as? NSNumber)?.doubleValue ?? 0) / (rate > 0 ? rate : 48_000)
    }

    var raw: [String: Any] {
        var d: [String: Any] = [
            "track": number, "role": role, "username": id, "name": name, "name_fixed": nameFixed,
            "transcribe": transcribe, "input": input ?? NSNull(), "audio_file": audioFile,
            "start_offset_s": round3(startOffset), "devices": devices, "duration_s": round3(duration),
            "language": language ?? NSNull(), "language_source": transcribe ? "text" : NSNull(),
            "script": script.mapValues(round3),
            "vad_regions": regions.map { [round3($0.0), round3($0.1)] },
            "chunks": chunks.map { [round3($0.0), round3($0.1)] },
            "segments": segments.map { s in
                var j = s.json
                if let sp = s.speaker { j["name"] = speakerName(sp) }
                return j
            },
            "filtered": filtered.map(\.json),
        ]
        if !speakers.isEmpty {
            d["speakers"] = speakers.map { ["id": $0.id, "label": $0.label, "name": $0.name, "speech_s": round1($0.speech)] as [String: Any] }
        }
        if let diarization { d["diarization"] = diarization }
        return d
    }

    func speakerName(_ id: Int) -> String { speakers.first { $0.id == id }?.name ?? name }

    /// What transcript.md needs from the track.
    var text: TranscriptTrack {
        TranscriptTrack(role: role, name: name, transcribe: transcribe, speakerNames: speakers.isEmpty ? nil : speakers.map(\.name),
                        lines: segments.map { Line(start: $0.start, end: $0.end, name: $0.speaker.map(speakerName) ?? name, text: $0.text) })
    }

    /// The track's level over [a, b] in dB (full scale); nil — no audio there.
    func level(_ a: Double, _ b: Double) -> Double? {
        let i = max(0, Int(a / levelFrame)), j = min(levels.count, Int((b / levelFrame).rounded(.up)))
        guard i < j else { return nil }
        let mean = levels[i..<j].reduce(0) { $0 + Double($1) } / Double(j - i)
        return 10 * log10(max(mean, 1e-12))
    }
}

let levelFrame = 0.05   // seconds

/// What the transcription needs from Settings (settings.json, written by the Settings window).
struct TranscriptSettings {
    var me = SettingsModel.defaultMe
    var other = SettingsModel.defaultOther
    var meetingsFolder = Identity.defaultMeetingsFolder
    var vocabulary: [String] = []   // Settings → Vocabulary: one word or phrase per line
    var voiceThreshold = VoiceTuning.defaultThreshold   // Settings → Telling voices apart

    /// For the command line: values instead of settings.json's (see main.swift).
    nonisolated(unsafe) static var overrides: [String: Any] = [:]

    static func load() -> TranscriptSettings {
        let d = readJSON(Identity.settingsFile).merging(overrides) { $1 }
        var s = TranscriptSettings()
        if let me = d["me"] as? String, !me.isEmpty { s.me = me }
        if let other = d["other"] as? String, !other.isEmpty { s.other = other }
        if let f = d["meetings_folder"] as? String, !f.isEmpty { s.meetingsFolder = f }
        s.vocabulary = vocabularyLines(d["vocabulary"] as? String ?? "")
        if let v = (d["voice_threshold"] as? NSNumber)?.doubleValue { s.voiceThreshold = min(max(v, VoiceTuning.range.lowerBound), VoiceTuning.range.upperBound) }
        return s
    }
}

/// Settings → Vocabulary: one word or phrase per line, empty lines and repeats left out.
func vocabularyLines(_ text: String) -> [String] {
    var out: [String] = []
    for line in text.split(whereSeparator: \.isNewline) {
        let t = line.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty && !out.contains(t) { out.append(t) }
    }
    return out
}

/// The words given to the recognizer as a hint, and the ones left out. The hint only knows Latin letters and ignores
/// words shorter than 3 letters. The tracks' names are added only when Vocabulary itself has words: names alone
/// ("Me") don't download the vocabulary model.
func vocabularyTerms(_ vocabulary: [String], names: [String]) -> ([String], [String]) {
    func usable(_ t: String) -> Bool {
        t.count >= 3 && t.unicodeScalars.contains { (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value) }
    }
    let words = vocabulary.filter(usable)
    let skipped = vocabulary.filter { !usable($0) }
    guard !words.isEmpty else { return ([], skipped) }
    var terms = words
    for n in names where usable(n) && !terms.contains(n) { terms.append(n) }
    return (terms, skipped)
}

final class Transcriber {
    let engine: TranscriptionEngine
    let detector: SpeechDetector
    let phrases: [String]
    /// The diarization models: loaded the first time a system track has speech.
    private var splitter: VoiceSplitter?

    init(engine: TranscriptionEngine, detector: SpeechDetector, phrases: [String]) {
        self.engine = engine
        self.detector = detector
        self.phrases = phrases
    }

    /// Transcribe the recording in sessionDir into its transcript folder; returns that folder.
    /// force — again, even if it was done. progress — the share done (0…1). notify — a notification for the person
    /// (the old transcript.md had edits by hand). modelStep — getting the vocabulary model, the first time it's needed.
    /// Stops on task cancellation (pause, quit) without leaving half a folder.
    func process(_ sessionDir: URL, force: Bool, outRoot: URL? = nil,
                 modelStep: @escaping @Sendable (ModelStep) -> Void = { _ in },
                 progress: @escaping (Double) -> Void, notify: (String, String) -> Void) async throws -> URL {
        let t0 = Date()
        let sess = try readSession(sessionDir)
        let id = sess["id"] as? String ?? sessionDir.lastPathComponent
        let settings = TranscriptSettings.load()
        let meetings = outRoot ?? URL(fileURLWithPath: (sess["meetings_folder"] as? String) ?? settings.meetingsFolder)
        guard let started = (sess["started_at"] as? String).flatMap(parseISO) else {
            throw TranscriberError("session.json has no start time")
        }
        let outDir = try pickMeetingDir(meetings, started: started, key: "local:\(id)", force: force)
        tlog("transcribing recording \(id) → \(outDir.path)")

        // the tracks: microphones by number, then system audio — whichever were recorded
        let sessTracks = sess["tracks"] as? [String: [String: Any]] ?? [:]
        var tracks: [TrackRun] = []
        for trackID in micTrackIDs(Array(sessTracks.keys)) + ["system"] {
            guard let info = sessTracks[trackID] else { continue }
            guard let file = info["file"] as? String, FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent(file).path) else {
                // the device wasn't connected for the whole recording — no file
                tlog("the recording has no file for track \(trackID): \(info["file"] ?? "?")")
                continue
            }
            let (name, fixed) = trackName(info, trackID, settings)
            tracks.append(TrackRun(number: tracks.count + 1, role: trackID == "system" ? "system" : "mic", id: trackID,
                                   name: name, nameFixed: fixed, info: info))
        }
        guard !tracks.isEmpty else { throw TranscriberError("the recording has no audio tracks") }

        // the hint: Settings → Vocabulary, plus the microphone tracks' names — only if Vocabulary has words
        // telling voices apart needs its model: get it before the long part, not after it
        if tracks.contains(where: { $0.role == "system" && $0.transcribe }) {
            try await ModelStore.shared.ensure([.voices], step: modelStep)
        }

        var (hint, skipped) = vocabularyTerms(settings.vocabulary,
                                              names: tracks.filter { $0.role == "mic" && $0.transcribe }.map(\.name))
        if !skipped.isEmpty { tlog("vocabulary: left out (the hint only knows Latin letters, 3 or more): \(skipped.joined(separator: ", "))") }
        // the vocabulary's model can't be downloaded now (no internet, no space): this transcript goes without the hint
        // rather than waiting for it — it's noted in meta.json, and the recording can be transcribed again later
        var vocabularySkipped: String?
        if !hint.isEmpty {
            do {
                try await ModelStore.shared.ensure([.vocabulary], step: modelStep)
            } catch let e as ModelsUnavailable {
                tlog("vocabulary: not used this time — \(e.errorDescription ?? "")")
                vocabularySkipped = e.errorDescription
                hint = []
            }
        }
        let vocabulary = try await engine.setVocabulary(hint, step: modelStep)
        if !vocabulary.isEmpty { tlog("vocabulary: \(vocabulary.joined(separator: ", "))") }

        let todo = tracks.filter(\.transcribe)
        for (k, t) in todo.enumerated() {
            let share = 1 / Double(todo.count)
            try await runTrack(t, sessionDir, settings: settings, modelStep: modelStep) { progress((Double(k) + $0) * share) }
        }
        for t in tracks where !t.transcribe {
            // Transcribe is off (an instrument): the track stays in audio/, no text for it
            tlog("track \(t.id) (\(t.name)) isn't transcribed — turned off in Settings")
        }
        // the other side's voice from the speakers — on every microphone track; without system audio there's nothing to compare with
        var echo = 0
        if let system = tracks.first(where: { $0.role == "system" && $0.transcribe }) {
            for m in tracks where m.role == "mic" && m.transcribe {
                let n = removeEcho(m, system)
                if n > 0 { tlog("removed the other side's echo from \(m.id) (\(m.name)): \(n) lines") }
                echo += n
            }
        }
        // two microphones in one room: a phrase heard by both stays where it's louder
        let mics = tracks.filter { $0.role == "mic" && $0.transcribe }
        let repeats = mics.count > 1 ? removeRepeats(mics) : 0
        if repeats > 0 { tlog("removed phrases another microphone heard louder: \(repeats)") }
        for t in tracks where t.transcribe { (t.language, t.script) = textLanguage(t.segments) }
        let duration = max(tracks.map(\.duration).max() ?? 0, (sess["duration_s"] as? NSNumber)?.doubleValue ?? 0)
        let apps = systemApps(sess["system_source"])
        let src: [String: Any] = [
            "type": "local", "session_id": id, "app": "Koe",
            "started_at": sess["started_at"] ?? NSNull(), "ended_at": sess["ended_at"] ?? NSNull(),
            "end_reason": sess["end_reason"] ?? NSNull(), "audio_dir": "audio",
            "gaps": sess["gaps"] ?? [], "system_source": sess["system_source"] ?? ["type": "all"],
            "tracks": tracks.map(\.id),
            "system_apps": tracks.contains { $0.role == "system" } ? apps : [],
            "devices": Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0.devices) }),
            "not_transcribed": tracks.filter { !$0.transcribe }.map(\.id),
        ]
        let texts = tracks.map(\.text)
        let md = renderMarkdown(started: started, zone: .current, duration: duration, tracks: texts, apps: apps,
                                lines: buildLines(texts))
        assignRawFiles(tracks)
        let elapsed = Date().timeIntervalSince(t0)
        var meta: [String: Any] = [
            "source": src,
            "recording": [
                "start_local": isoLocal(started), "duration_s": round3(duration),
                "participants": tracks.map { t -> [String: Any] in
                    var p: [String: Any] = [
                        "track": t.number, "role": t.role, "username": t.id, "name": t.name, "transcribe": t.transcribe,
                        "language": t.language ?? NSNull(), "language_source": t.transcribe ? "text" : NSNull(),
                        "segments": t.segments.count, "filtered": t.filtered.count, "raw_file": t.rawFile,
                    ]
                    if let sp = t.raw["speakers"] { p["speakers"] = sp }
                    return p
                },
            ],
            "processing": [
                "processed_at": isoLocal(Date()), "pipeline_version": pipelineVersion,
                "engine": engine.name, "engine_version": fluidAudioVersion,
                "model": engine.model, "model_repo": SpeechModels.modelRepo,
                "language": "auto", "language_source": "auto",
                "vad": "silero-vad", "vad_frame_ms": 256, "vad_settings": Tuning.vadJSON,
                "phrase_settings": ["pause_s": Tuning.phrasePauseS, "comma_after_s": Tuning.phraseCommaS],
                "initial_prompt": NSNull(),
                "vocabulary": vocabulary,
                "vocabulary_model": vocabulary.isEmpty ? NSNull() : SpeechModels.vocabularyRepo,
                "vocabulary_replaced": tracks.reduce(0) { n, t in n + (t.segments + t.filtered).reduce(0) { $0 + $1.replaced.count } },
                "merge_gap_s": Tuning.mergeGapS, "max_line_s": Tuning.maxLineS,
                "echo_removed": echo,
                "voices": tracks.first { $0.diarization != nil }.map { t -> Any in
                    ["method": VoiceTuning.method, "model_repo": VoiceTuning.modelRepo, "threshold": round3(settings.voiceThreshold),
                     "min_speaker_s": VoiceTuning.minSpeakerS, "speakers": t.speakers.count] as [String: Any]
                } ?? NSNull(),
                "repeats_removed": repeats,
                "host": hostName(),
                "elapsed_s": round1(elapsed),
                "per_track_elapsed_s": Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, round1($0.elapsed)) }),
            ] as [String: Any],
        ]
        if let vocabularySkipped, var p = meta["processing"] as? [String: Any] {
            p["vocabulary_skipped"] = vocabularySkipped
            meta["processing"] = p
        }
        try Task.checkCancellation()
        try writeMeeting(outDir, md: md, tracks: tracks, meta: meta, notify: notify)
        // the names given before (the Names window, speakers.json) stay: a new voice gets its label as its name
        let labels = tracks.flatMap { $0.speakers.map(\.label) }
        if !labels.isEmpty { SpeakerNames.addLabels(outDir, labels) }
        if FileManager.default.fileExists(atPath: MeetingFolder.speakers(outDir).path) {
            try SpeakerNames.refresh(outDir, settings: settings, notify: notify)
        }
        progress(1)
        tlog("done: \(outDir.path) (recording \(humanDuration(duration)), took \(String(format: "%.1f", elapsed)) s)")
        return outDir
    }

    /// One track: audio → speech pieces → recognized phrases, minus hallucinations.
    private func runTrack(_ t: TrackRun, _ sessionDir: URL, settings: TranscriptSettings,
                          modelStep: @escaping @Sendable (ModelStep) -> Void, progress: @escaping (Double) -> Void) async throws {
        let t0 = Date()
        let url = sessionDir.appendingPathComponent(t.audioFile)
        var audio: [Float]
        let size = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size == 0 {
            // the chosen app didn't make a sound the whole recording — the file is empty
            tlog("track \(t.id) is empty")
            audio = [Float](repeating: 0, count: asrRate)
        } else {
            audio = try await Task.detached(priority: .utility) { try TrackAudio.read(url) }.value
            if audio.isEmpty {
                tlog("track \(t.id) is empty")   // a WAV without a single sample (only the header)
                audio = [Float](repeating: 0, count: asrRate)
            }
        }
        // the AAC encoder puts a little silence at the start of the file — cut it off, and move the track to
        // where it started on the recording's timeline: that way the tracks' lines go side by side
        let cut = min(audio.count, Int((t.delay * Double(asrRate)).rounded()))
        let lead = Int((max(0, t.startOffset) * Double(asrRate)).rounded())
        audio = [Float](repeating: 0, count: lead) + audio[cut...]
        t.duration = Double(audio.count) / Double(asrRate)
        let frame = Int(levelFrame * Double(asrRate))
        t.levels = stride(from: 0, to: audio.count, by: frame).map { i in
            let s = audio[i..<min(audio.count, i + frame)]
            return s.reduce(0) { $0 + $1 * $1 } / Float(s.count)
        }
        progress(0.05)
        try Task.checkCancellation()

        let probs = try await detector.probabilities(audio) { progress(0.05 + 0.15 * $0) }
        t.regions = SpeechDetector.regions(probs, samples: audio.count)
        t.chunks = SpeechDetector.chunks(t.regions)
        let speech = t.chunks.reduce(0) { $0 + $1.1 - $1.0 }
        tlog("track \(t.number) (\(t.id)): \(humanDuration(t.duration)), speech \(humanDuration(t.regions.reduce(0) { $0 + $1.1 - $1.0 })), pieces \(t.chunks.count)")
        // the system track: the last part of its share is for telling voices apart
        let voicesShare = t.role == "system" ? 0.15 : 0
        var done = 0.0
        for (cs, ce) in t.chunks {
            try Task.checkCancellation()
            let a = max(0, min(audio.count, Int(cs * Double(asrRate))))
            let b = max(a, min(audio.count, Int(ce * Double(asrRate))))
            let heard = try await engine.transcribe(Array(audio[a..<b]))
            for (was, now) in heard.replaced { tlog("  vocabulary: \"\(was)\" → \"\(now)\" at \(ts(cs))") }
            for seg in splitPhrases(heard, offset: cs, end: ce) {
                if let reason = hallucinationReason(seg.text, phrases) {
                    var s = seg
                    s.reason = reason
                    t.filtered.append(s)
                    tlog("  thrown out (\(reason)): \(seg.text)")
                } else {
                    t.segments.append(seg)
                }
            }
            done += ce - cs
            progress(0.2 + (0.8 - voicesShare) * (speech > 0 ? done / speech : 1))
        }
        if t.role == "system" && !t.segments.isEmpty {
            try await tellVoicesApart(t, audio, settings: settings, modelStep: modelStep) { progress(1 - voicesShare * (1 - $0)) }
        }
        t.elapsed = Date().timeIntervalSince(t0)
    }

    /// Who said each phrase of the system track (Voices.swift). If it fails, the track stays one voice: the transcript
    /// is still worth having.
    private func tellVoicesApart(_ t: TrackRun, _ audio: [Float], settings: TranscriptSettings,
                                 modelStep: @escaping @Sendable (ModelStep) -> Void, progress: @escaping (Double) -> Void) async throws {
        let t0 = Date()
        do {
            if splitter == nil { splitter = try await VoiceSplitter(step: modelStep) }
            guard let splitter else { return }
            try Task.checkCancellation()
            let p = UncheckedProgress(progress)
            let found = try await splitter.split(audio, threshold: settings.voiceThreshold) { p.call(0.9 * $0) }
            try Task.checkCancellation()
            guard found.count > 0 else {
                tlog("  voices: none found")
                return
            }
            for m in found.merged { tlog("  voices: less than \(Int(VoiceTuning.minSpeakerS)) s of speech, joined: \(m)") }
            let (segs, overlapWords) = try await assignVoices(t.segments, found.turns) { spans, cands in
                try await splitter.dominantVoices(audio, spans: spans, candidates: cands, prints: found.prints)
            }
            t.segments = segs
            let labels = voiceLabels(settings.other, count: found.count)
            t.speakers = (1...found.count).map { ($0, labels[$0]!, labels[$0]!, found.speech[$0] ?? 0) }
            let elapsed = Date().timeIntervalSince(t0)
            t.diarization = [
                "method": VoiceTuning.method, "threshold": round3(settings.voiceThreshold), "min_speaker_s": VoiceTuning.minSpeakerS,
                "voices_found": found.clusters, "joined": found.merged, "overlap_words": overlapWords, "elapsed_s": round1(elapsed),
                "turns": found.turns.map { [round3($0.start), round3($0.end), $0.speaker] as [Any] },
            ]
            tlog("  voices: \(found.count) (\(t.speakers.map { "\($0.label) — \(humanDuration($0.speech))" }.joined(separator: ", "))), "
                 + "words where people talk at once: \(overlapWords), took \(String(format: "%.1f", elapsed)) s")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            tlog("  voices: couldn't tell them apart, the track stays one voice: \(error.localizedDescription)")
            t.diarization = ["method": VoiceTuning.method, "error": error.localizedDescription]
        }
        progress(1)
    }

    // ---------- the transcript folder ----------

    private func pickMeetingDir(_ meetings: URL, started: Date, key: String, force: Bool) throws -> URL {
        let base = folderStamp(started)
        var n = 1
        while true {
            let cand = meetings.appendingPathComponent(n == 1 ? base : "\(base)_\(n)")
            MeetingFolder.tidy(cand)   // a folder of the old layout: its meta.json moves into .koe first
            let meta = MeetingFolder.meta(cand)
            if !FileManager.default.fileExists(atPath: cand.path) { return cand }
            if FileManager.default.fileExists(atPath: meta.path),
               let src = readJSON(meta)["source"] as? [String: Any], "local:\(src["session_id"] ?? "")" == key {
                if !force { throw AlreadyProcessed(dir: cand) }
                return cand
            }
            n += 1
        }
    }

    /// transcript.md, and .koe/raw/ and .koe/meta.json (MeetingFolder). First everything goes into a temporary folder:
    /// a cut-off run won't leave half a transcript. When transcribing again only these files change (notes, audio/,
    /// speakers.json stay).
    private func writeMeeting(_ outDir: URL, md: String, tracks: [TrackRun], meta: [String: Any],
                              notify: (String, String) -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: outDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = outDir.deletingLastPathComponent().appendingPathComponent(outDir.lastPathComponent + ".partial")
        if fm.fileExists(atPath: tmp.path) { try fm.removeItem(at: tmp) }
        try fm.createDirectory(at: MeetingFolder.data(tmp).appendingPathComponent("raw"), withIntermediateDirectories: true)
        try Data(md.utf8).write(to: MeetingFolder.transcript(tmp))
        for t in tracks { try jsonData(t.raw).write(to: MeetingFolder.raw(tmp, t.rawFile)) }
        var meta = meta
        meta["transcript_sha256"] = sha256(md)
        try jsonData(meta).write(to: MeetingFolder.meta(tmp))
        if !fm.fileExists(atPath: outDir.path) {
            try fm.moveItem(at: tmp, to: outDir)
            return
        }
        protectManualEdits(outDir, newMarkdown: md, notify: notify)
        try fm.createDirectory(at: MeetingFolder.data(outDir), withIntermediateDirectories: true)
        let raw = MeetingFolder.data(outDir).appendingPathComponent("raw")
        if fm.fileExists(atPath: raw.path) { try fm.removeItem(at: raw) }
        try fm.moveItem(at: MeetingFolder.data(tmp).appendingPathComponent("raw"), to: raw)
        // meta.json last: meta.json means "done"
        for (target, from) in [(MeetingFolder.transcript(outDir), MeetingFolder.transcript(tmp)), (MeetingFolder.meta(outDir), MeetingFolder.meta(tmp))] {
            if fm.fileExists(atPath: target.path) {
                _ = try fm.replaceItemAt(target, withItemAt: from)
            } else {
                try fm.moveItem(at: from, to: target)
            }
        }
        try? fm.removeItem(at: tmp)
    }
}

// ---------- the pieces of the pipeline (the same rules as the old Python pipeline) ----------

/// The tracks' log lines go to pipeline.log, as before.
func tlog(_ text: String) {
    pipelineLogQueue.async {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = Data("\(f.string(from: Date())) \(text)\n".utf8)
        try? FileManager.default.createDirectory(at: Identity.logsDir, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: Identity.pipelineLog) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            try? line.write(to: Identity.pipelineLog)
        }
    }
    if CommandLine.arguments.contains("--verbose") { print(text) }
}

private let pipelineLogQueue = DispatchQueue(label: "koe.pipeline.log")

func round1(_ x: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), x)) }

func jsonData(_ obj: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
}

func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

func parseISO(_ s: String) -> Date? { ISO8601DateFormatter().date(from: s) }

func hostName() -> String {
    var buf = [CChar](repeating: 0, count: 256)
    gethostname(&buf, buf.count)
    return String(cString: buf)
}

/// "2026-10-28_1405" — the transcript folder's name.
func folderStamp(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd_HHmm"
    return f.string(from: d)
}

/// A recording's session.json: next to the tracks while it's in the inbox; once the audio has moved into audio/ of
/// its transcript — in .koe of that transcript (MeetingFolder), or still in audio/ if it couldn't be moved.
func sessionFile(_ dir: URL) -> URL {
    if dir.lastPathComponent == MeetingFolder.audioName {
        let moved = MeetingFolder.session(dir.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: moved.path) { return moved }
    }
    return dir.appendingPathComponent("session.json")
}

/// session.json of a recording (dir — where its tracks are); it appearing means "the recording is ready". The
/// recording's name is the id field, and for old recordings — the folder name (after the move into audio/ it comes
/// from meta.json).
func readSession(_ dir: URL) throws -> [String: Any] {
    let url = sessionFile(dir)
    guard let data = try? Data(contentsOf: url), var sess = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw TranscriberError("can't read \(url.path)")
    }
    if (sess["id"] as? String ?? "").isEmpty {
        let meta = MeetingFolder.meta(dir.deletingLastPathComponent())
        if dir.lastPathComponent == MeetingFolder.audioName, let src = readJSON(meta)["source"] as? [String: Any], let id = src["session_id"] as? String {
            sess["id"] = id
        } else {
            sess["id"] = dir.lastPathComponent
        }
    }
    return sess
}

/// Microphone tracks in order: mic, mic-2, mic-3…
func micTrackIDs(_ ids: [String]) -> [String] {
    ids.filter { $0 == "mic" || ($0.hasPrefix("mic-") && Int($0.dropFirst(4)) != nil) }
        .sorted { ($0 == "mic" ? 1 : Int($0.dropFirst(4))!) < ($1 == "mic" ? 1 : Int($1.dropFirst(4))!) }
}

/// A track's name in the transcript. Typed in Settings → Inputs — as is (fixed); otherwise the first microphone
/// track is "Your name" (changes in Settings and in finished transcripts), the others are by device, system audio — "Other people".
func trackName(_ info: [String: Any], _ id: String, _ s: TranscriptSettings) -> (String, Bool) {
    if id == "system" { return (s.other, false) }
    if let name = info["name"] as? String, !name.isEmpty { return (name, true) }
    if id == "mic" { return (s.me, false) }
    return ((info["default_name"] as? String) ?? id, true)
}

/// The names of the apps whose sound is on the system track; [] — all system audio. Before stage 4 there was one app.
func systemApps(_ source: Any?) -> [String] {
    let ss = source as? [String: Any] ?? [:]
    switch ss["type"] as? String {
    case "apps": return (ss["apps"] as? [[String: Any]] ?? []).map { ($0["name"] as? String) ?? ($0["bundle_id"] as? String) ?? "?" }
    case "app": return [(ss["name"] as? String) ?? (ss["bundle_id"] as? String) ?? "?"]
    default: return []
    }
}

private let wordRegex = try! NSRegularExpression(pattern: "\\w+")

/// Lowercase, ё → е, only the words: for comparing texts.
func normalize(_ text: String) -> String {
    let t = text.lowercased().replacingOccurrences(of: "ё", with: "е")
    let ns = t as NSString
    return wordRegex.matches(in: t, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }.joined(separator: " ")
}

/// hallucinations.txt: one phrase per line, # — a comment. Normalized.
func loadHallucinations(_ url: URL) -> [String] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }.map(normalize).filter { !$0.isEmpty }
}

let hallucinationCoverage = 0.7   // the share of a phrase's words the listed phrases must take up

/// What share of the words is taken by phrases from the list (whole words), and which phrases were found.
func phraseCoverage(_ words: [Substring], _ phrases: [String]) -> (Double, [String]) {
    var covered = [Bool](repeating: false, count: words.count)
    var found: [String] = []
    for p in phrases {
        let pw = p.split(separator: " ")
        var i = 0
        while i + pw.count <= words.count {
            if Array(words[i..<(i + pw.count)]) == pw {
                for k in i..<(i + pw.count) { covered[k] = true }
                if !found.contains(p) { found.append(p) }
                i += pw.count
            } else {
                i += 1
            }
        }
    }
    return (Double(covered.filter { $0 }.count) / Double(max(1, words.count)), found)
}

/// Why a phrase is thrown out, or nil. Only if it's almost all known phrases (or their repeats): "subscribe to the
/// channel" inside live speech is speech, not a hallucination.
func hallucinationReason(_ text: String, _ phrases: [String]) -> String? {
    let norm = normalize(text)
    if norm.isEmpty { return "empty text" }
    let (share, found) = phraseCoverage(norm.split(separator: " "), phrases)
    if !found.isEmpty && share >= hallucinationCoverage {
        return "known hallucination: \(found.map { "\"\($0)\"" }.joined(separator: ", ")) (\(Int((share * 100).rounded()))% of the text)"
    }
    return nil
}

/// A piece from the recognizer → phrases. Parakeet returns the whole piece (up to 29 s) as one line; the transcript
/// needs phrases, so the lines of different tracks interleave as they were said and echo is compared phrase by phrase.
/// A phrase ends after a word with . ? ! …, before a pause of phrasePauseS between words, and — once it's longer
/// than phraseCommaS — after a comma; also after a comma where the language changes (Cyrillic ↔ Latin): the other
/// side's English heard by a Russian speaker's microphone becomes its own phrase and goes as echo. Times are moved by
/// offset (the piece's start on the track).
func splitPhrases(_ heard: Heard, offset: Double, end: Double) -> [Segment] {
    let words = heard.words.map { Word(word: $0.word, start: offset + $0.start, end: offset + $0.end, probability: $0.probability) }
    guard !words.isEmpty else {
        if heard.text.isEmpty { return [] }
        return [Segment(start: offset, end: end, text: heard.text, words: [], confidence: heard.confidence)]
    }
    var out: [Segment] = []
    var cur: [Word] = []
    func flush() {
        guard let first = cur.first, let last = cur.last else { return }
        let probs = cur.compactMap(\.probability)
        out.append(Segment(start: first.start, end: last.end, text: cur.map(\.word).joined(separator: " "), words: cur,
                           confidence: probs.isEmpty ? nil : probs.reduce(0, +) / Double(probs.count)))
        cur = []
    }
    let closers = CharacterSet(charactersIn: "\"'»”’)]")
    for (i, w) in words.enumerated() {
        if let prev = cur.last, w.start - prev.end >= Tuning.phrasePauseS { flush() }
        cur.append(w)
        let bare = w.word.trimmingCharacters(in: closers)
        if let c = bare.last {
            if ".?!…".contains(c) {
                flush()
            } else if ",;:".contains(c), let first = cur.first {
                let next = i + 1 < words.count ? script(words[i + 1].word) : nil
                let switches = next != nil && script(w.word) != nil && next != script(w.word)
                if switches || w.end - first.start >= Tuning.phraseCommaS { flush() }
            }
        }
    }
    flush()
    // what the vocabulary changed goes with the phrase that has the new word
    for pair in heard.replaced {
        if let k = out.firstIndex(where: { s in s.words.contains { $0.word == pair.1 } && !s.replaced.contains { $0 == pair } }) {
            out[k].replaced.append(pair)
        }
    }
    return out
}

/// A word's alphabet by its first letter: true — Cyrillic, false — Latin, nil — no letters.
private func script(_ word: String) -> Bool? {
    guard let u = word.unicodeScalars.first(where: { CharacterSet.letters.contains($0) }) else { return nil }
    switch u.value {
    case 0x0400...0x04FF: return true
    case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: return false
    default: return nil
    }
}

/// The track's language for meta.json, from its text: Parakeet doesn't say which language it heard.
/// Mostly Cyrillic — ru (uk if there are letters only Ukrainian has), mostly Latin — en.
func textLanguage(_ segments: [Segment]) -> (String?, [String: Double]) {
    var cyr = 0, lat = 0, ukr = 0
    for s in segments {
        for u in s.text.unicodeScalars where CharacterSet.letters.contains(u) {
            switch u.value {
            case 0x0400...0x04FF:
                cyr += 1
                if "іїєґІЇЄҐ".unicodeScalars.contains(u) { ukr += 1 }
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: lat += 1
            default: break
            }
        }
    }
    let total = cyr + lat
    guard total > 0 else { return (nil, [:]) }
    let script = ["cyrillic": Double(cyr) / Double(total), "latin": Double(lat) / Double(total)]
    if cyr >= lat { return (ukr * 50 > cyr ? "uk" : "ru", script) }
    return ("en", script)
}

// ---------- echo of the other side in a microphone ----------

let echoWindowS = 1.5      // how much earlier/later than the line to look for its copy on the system track
let echoMinCoverage = 0.7  // what share of the microphone line's text must be found at the other side
let echoMinBlock = 4       // matches shorter than this many letters don't count (or "да" is found anywhere)

/// What share of text a was found in text b, in order, in pieces of echoMinBlock letters and more
/// (Python's difflib.SequenceMatcher without junk). Fuzzy: different endings don't break the whole match.
func textCoverage(_ a: String, _ b: String) -> Double {
    let a = Array(a.unicodeScalars), b = Array(b.unicodeScalars)
    guard !a.isEmpty, !b.isEmpty else { return 0 }
    var b2j: [Unicode.Scalar: [Int]] = [:]
    for (j, c) in b.enumerated() { b2j[c, default: []].append(j) }
    func longest(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> (Int, Int, Int) {
        var best = (alo, blo, 0)
        var j2len: [Int: Int] = [:]
        for i in alo..<ahi {
            var next: [Int: Int] = [:]
            for j in b2j[a[i]] ?? [] {
                if j < blo { continue }
                if j >= bhi { break }
                let k = (j2len[j - 1] ?? 0) + 1
                next[j] = k
                if k > best.2 { best = (i - k + 1, j - k + 1, k) }
            }
            j2len = next
        }
        return best
    }
    var queue = [(0, a.count, 0, b.count)]
    var blocks: [(Int, Int, Int)] = []
    while let (alo, ahi, blo, bhi) = queue.popLast() {
        let (i, j, k) = longest(alo, ahi, blo, bhi)
        guard k > 0 else { continue }
        blocks.append((i, j, k))
        if alo < i && blo < j { queue.append((alo, i, blo, j)) }
        if i + k < ahi && j + k < bhi { queue.append((i + k, ahi, j + k, bhi)) }
    }
    blocks.sort { ($0.0, $0.1) < ($1.0, $1.1) }
    // neighboring blocks are joined, as get_matching_blocks does
    var joined: [Int] = []
    var (i1, j1, k1) = (0, 0, 0)
    for (i2, j2, k2) in blocks {
        if i1 + k1 == i2 && j1 + k1 == j2 {
            k1 += k2
        } else {
            if k1 > 0 { joined.append(k1) }
            (i1, j1, k1) = (i2, j2, k2)
        }
    }
    if k1 > 0 { joined.append(k1) }
    return Double(joined.filter { $0 >= echoMinBlock }.reduce(0, +)) / Double(a.count)
}

/// Number words → digits, so that "one, two" on one track and "1, 2" on the other compare as the same: the recognizer
/// writes numbers either way, and the two tracks of one phrase can differ.
private let numberWords: [String: String] = {
    var m: [String: String] = [:]
    let en = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
              "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty"]
    let ru = ["ноль", "один", "два", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять", "десять", "одиннадцать",
              "двенадцать", "тринадцать", "четырнадцать", "пятнадцать", "шестнадцать", "семнадцать", "восемнадцать",
              "девятнадцать", "двадцать"]
    for (i, w) in en.enumerated() { m[w] = String(i) }
    for (i, w) in ru.enumerated() { m[w] = String(i) }
    for (w, n) in [("thirty", 30), ("forty", 40), ("fifty", 50), ("sixty", 60), ("seventy", 70), ("eighty", 80),
                   ("ninety", 90), ("hundred", 100), ("thousand", 1000), ("одна", 1), ("одно", 1), ("две", 2),
                   ("тридцать", 30), ("сорок", 40), ("пятьдесят", 50), ("шестьдесят", 60), ("семьдесят", 70),
                   ("восемьдесят", 80), ("девяносто", 90), ("сто", 100), ("тысяча", 1000)] { m[w] = String(n) }
    return m
}()

/// The text as echo is compared: normalized, number words as digits.
func echoForm(_ text: String) -> String {
    normalize(text).split(separator: " ").map { numberWords[String($0)] ?? String($0) }.joined(separator: " ")
}

/// Microphone lines that almost word for word repeat the other side's speech at the same time are their voice from
/// the speakers that got into the microphone. They go to filtered with the reason. Short lines (1–2 words) are echo
/// only if the other side has exactly the same line at that time: your own "yes" over their long phrase stays.
func removeEcho(_ mic: TrackRun, _ system: TrackRun) -> Int {
    guard system.segments.contains(where: { !$0.words.isEmpty }) else { return 0 }
    return throwOut(mic) { seg in
        sameSpeech(seg, on: system).map { "echo of the other side: \($0.describe("their speech", at: seg.start))" }
    }
}

/// How a phrase was found on another track.
enum SpeechMatch {
    case exact(Segment)     // a short phrase: the other track has exactly the same one
    case covered(Double)    // this share of the text is in the other track's words at that time

    func describe(_ whose: String, at t: Double) -> String {
        switch self {
        case .exact(let o): return "\"\(o.text)\" at \(ts(o.start))"
        case .covered(let c): return "\(Int((c * 100).rounded()))% of the text matches \(whose) at \(ts(t))"
        }
    }
}

/// Whether the other track has (almost) the same phrase at the same time (± echoWindowS): at least echoMinCoverage
/// of the text is in its words; a short phrase (1–2 words) — only if it has exactly the same phrase.
func sameSpeech(_ seg: Segment, on other: TrackRun) -> SpeechMatch? {
    let text = echoForm(seg.text)
    let lo = seg.start - echoWindowS, hi = seg.end + echoWindowS
    if text.split(separator: " ").count <= 2 {
        guard !text.isEmpty else { return nil }
        return other.segments.first { $0.end >= lo && $0.start <= hi && echoForm($0.text) == text }.map { .exact($0) }
    }
    let window = echoForm(other.segments.flatMap(\.words).filter { $0.end >= lo && $0.start <= hi }.map(\.word).joined(separator: " "))
    let cover = textCoverage(text, window)
    return cover >= echoMinCoverage ? .covered(cover) : nil
}

/// Phrases of the track for which why() gives a reason go to filtered with it.
private func throwOut(_ track: TrackRun, why: (Segment) -> String?) -> Int {
    var kept: [Segment] = []
    var removed = 0
    for seg in track.segments {
        if let reason = why(seg) {
            var s = seg
            s.reason = reason
            track.filtered.append(s)
            removed += 1
            tlog("  thrown out (\(reason)): \(seg.text)")
        } else {
            kept.append(seg)
        }
    }
    track.segments = kept
    return removed
}

/// Two microphones in one room hear the same person: the phrase is on both tracks, louder on the near one. A phrase that
/// another microphone track has too (the same rules as echo) stays where it's louder — by each track's level during
/// the phrase — and goes to filtered on the quieter tracks. Every phrase is checked against the tracks as they were
/// before anything was thrown out, so each copy is judged the same way.
func removeRepeats(_ mics: [TrackRun]) -> Int {
    let reasons: [[String?]] = mics.map { m in
        m.segments.map { seg -> String? in
            guard let here = m.level(seg.start, seg.end) else { return nil }
            var best: (TrackRun, SpeechMatch, Double)?
            for o in mics where o !== m {
                guard let there = o.level(seg.start, seg.end), there > here, there > best?.2 ?? -.infinity,
                      let match = sameSpeech(seg, on: o) else { continue }
                best = (o, match, there)
            }
            guard let (o, match, there) = best else { return nil }
            return "heard louder on \(o.name): \(match.describe("its speech", at: seg.start)), "
                + String(format: "%.0f dB there, %.0f dB here", there, here)
        }
    }
    var removed = 0
    for (m, r) in zip(mics, reasons) {
        var k = 0
        removed += throwOut(m) { _ in defer { k += 1 }; return r[k] }
    }
    return removed
}

// ---------- the transcript ----------

/// 3725.4 → "01:02:05"
func ts(_ sec: Double) -> String {
    let s = Int(sec)
    return String(format: "%02d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
}

/// 723 → "12 min 03 s", 3900 → "1 h 05 min", 9 → "9 s"
func humanDuration(_ sec: Double) -> String {
    let s = Int(sec.rounded(.toNearestOrEven))
    let (h, m, r) = (s / 3600, s % 3600 / 60, s % 60)
    if h > 0 { return String(format: "%d h %02d min", h, m) }
    if m > 0 { return String(format: "%d min %02d s", m, r) }
    return "\(r) s"
}

struct Line {
    var start: Double
    var end: Double
    var name: String
    var text: String
}

/// A track as transcript.md sees it: made by transcription (TrackRun.text) or read back from raw/*.json when names change.
struct TranscriptTrack {
    var role: String              // mic / system
    var name: String
    var transcribe: Bool
    var speakerNames: [String]?   // voices told apart: the speakers' names, in order
    var lines: [Line]             // every phrase, with the name of whoever said it
}

/// All tracks' phrases by time; one person's neighboring phrases (pause ≤ mergeGapS) are one line, but a long monologue
/// gets a new line (with its own timestamp) at least every maxLineS.
func buildLines(_ tracks: [TranscriptTrack]) -> [Line] {
    var events: [(Int, Line)] = []
    for t in tracks {
        for l in t.lines { events.append((events.count, l)) }
    }
    events.sort { ($0.1.start, $0.0) < ($1.1.start, $1.0) }   // stable, like Python's sort
    var lines: [Line] = []
    for (_, e) in events {
        if let last = lines.last, last.name == e.name, e.start - last.end <= Tuning.mergeGapS, e.start - last.start < Tuning.maxLineS {
            lines[lines.count - 1].text += " " + e.text
            lines[lines.count - 1].end = max(last.end, e.end)
        } else {
            lines.append(e)
        }
    }
    return lines
}

private let months = ["January", "February", "March", "April", "May", "June", "July",
                      "August", "September", "October", "November", "December"]

/// The header and the lines. Fixed English format whatever the interface language.
/// zone — the time zone the recording was made in.
func renderMarkdown(started: Date, zone: TimeZone, duration: Double, tracks: [TranscriptTrack], apps: [String],
                    lines: [Line]) -> String {
    let cal = Calendar(identifier: .gregorian)
    let c = cal.dateComponents(in: zone, from: started)
    let end = started.addingTimeInterval(duration)
    func hm(_ d: Date) -> String {
        let x = cal.dateComponents(in: zone, from: d)
        return String(format: "%02d:%02d", x.hour!, x.minute!)
    }
    var names: [String] = []
    for t in tracks where t.transcribe {
        if let speakers = t.speakerNames, !speakers.isEmpty {
            for n in speakers where !names.contains(n) { names.append(n) }
        } else {
            names.append(t.lines.isEmpty ? "\(t.name) (didn't speak)" : t.name)
        }
    }
    var out = [
        String(format: "# Recording on %04d-%02d-%02d at %@", c.year!, c.month!, c.day!, hm(started)),
        "",
        "- **Date:** \(months[c.month! - 1]) \(c.day!), \(c.year!), \(hm(started))–\(hm(end))",
        "- **Duration:** \(humanDuration(duration))",
        "- **Speakers:** \(names.joined(separator: ", "))",
    ]
    // what was recorded, and the tracks that weren't transcribed (an instrument)
    let mics = tracks.filter { $0.role == "mic" }.count
    let hasSystem = tracks.contains { $0.role == "system" }
    let system = "system audio (\(apps.isEmpty ? "all apps" : apps.joined(separator: ", ")))"
    let mic = mics == 1 ? "microphone" : "\(mics) microphones"
    let what = mics > 0 && hasSystem ? "\(mic) and \(system)" : mics > 0 ? (mics == 1 ? "only the \(mic)" : "only \(mic)") : "only \(system)"
    out.append("- **Recorded with Koe:** \(what)")
    out += tracks.filter { !$0.transcribe }.map { "- **\($0.name)** — not transcribed" }
    out += ["", "---", ""]
    if lines.isEmpty { out.append("_No speech found._") }
    for l in lines { out += ["[\(ts(l.start))] \(l.name): \(l.text)", ""] }
    var md = out.joined(separator: "\n")
    while md.last?.isWhitespace == true { md.removeLast() }
    return md + "\n"
}

/// raw/<track>.json (in .koe): the track's id without characters a file name can't have; a repeat gets _<number>.
func assignRawFiles(_ tracks: [TrackRun]) {
    var seen = Set<String>()
    for t in tracks {
        var name = t.id.replacingOccurrences(of: "[/\\\\:\\x00]", with: "_", options: .regularExpression)
        if seen.contains(name) { name += "_\(t.number)" }
        seen.insert(name)
        t.rawFile = "raw/\(name).json"
    }
}

/// Before transcript.md is overwritten: if it was edited by hand, keep a copy next to it.
/// "Edited" = the file isn't what Koe wrote (the hash in meta.json). Old transcripts without a hash are kept too.
func protectManualEdits(_ dir: URL, newMarkdown: String, notify: (String, String) -> Void) {
    let path = MeetingFolder.transcript(dir)
    guard let data = try? Data(contentsOf: path) else { return }
    let current = String(decoding: data, as: UTF8.self)
    guard current != newMarkdown else { return }
    if readJSON(MeetingFolder.meta(dir))["transcript_sha256"] as? String == sha256(current) { return }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd_HHmmss"
    let backup = dir.appendingPathComponent("transcript.edited-\(f.string(from: Date())).md")
    do {
        try FileManager.default.copyItem(at: path, to: backup)
    } catch {
        tlog("couldn't keep the edited transcript.md in \(dir.lastPathComponent): \(error.localizedDescription)")
        return
    }
    tlog("transcript.md in \(dir.lastPathComponent) isn't what Koe wrote — kept it as \(backup.lastPathComponent)")
    notify(String(localized: "Your edits are saved"),
           String(localized: "\(dir.lastPathComponent): your edited transcript.md was kept as \(backup.lastPathComponent)"))
}
