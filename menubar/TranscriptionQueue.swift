// The transcription queue: transcribing recordings and updating speaker names, one job at a time.
//
// After a recording stops it goes into the queue; one job at a time, off the main thread. The queue lives in
// state/queue.json, so it survives quitting: on the next launch it continues (an unfinished transcription starts
// over). On launch, recordings in the inbox that aren't done yet join the queue too.
// A failed recording is tried 3 times (a minute apart), then it's Failed ▸ in the menu with Try Again.
// Pause stops the current job right away; it starts over after Resume. The pause survives a restart.
// While the queue works, the Mac doesn't fall asleep from being idle.
// The speech models are downloaded the first time they're needed (Models.swift). If that can't be done now (no internet,
// the server doesn't answer, no disk space), it's not a failed attempt: the recording waits and is tried again when the
// Mac is back online, when the models arrive (from the setup window or Settings), or every 5–10 minutes.
//
// The registry (state/registry.json) remembers every recording: done (and where its transcript is), error, failed.
// The app itself keeps the list of transcripts for Settings (Retranscribe, Names).
//
// Speaker names (the Names window, changed names in Settings, speakers.json edited by hand) are updated by jobs of the
// same queue (Names.swift), so they never touch a transcript that's being written.
import AppKit
import Foundation

/// What the queue is doing now — for the menu and the icon.
enum QueuePhase: Equatable {
    case idle
    case paused
    case downloading(Double?)   // the speech model, share 0…1 (nil — not known yet)
    case preparing              // loading the speech model
    case transcribing(Double)   // share of the current recording
    case names                  // updating speaker names
}

struct QueueJob: Codable, Equatable {
    enum Kind: String, Codable { case transcribe, refreshNames = "refresh_names", setSpeakers = "set_speakers" }
    var kind: Kind
    var key: String?               // transcribe: local:<recording>
    var force: Bool?               // transcribe again (Settings → Retranscribe, Try Again)
    var outDir: String?            // set_speakers: the transcript folder; refresh_names: only these (nil — all)
    var dirs: [String]?
    var names: [String: String]?   // set_speakers: label → name
    var tracks: [String: String]?  // set_speakers: track → name, for this recording only (an empty name — its own)
    var notBefore: Double?         // a retry after an error: not before this time (seconds since 1970)
    var waiting: Bool?             // waits for the speech models (they couldn't be downloaded)
}

let maxAttempts = 3

// ---------- the registry and transcript folders ----------

enum Registry {
    static let url = Identity.stateDir.appendingPathComponent("registry.json")

    static func load() -> [String: Any] {
        var reg = readJSON(url)
        if reg["recordings"] == nil { reg["recordings"] = [String: Any]() }
        if reg["notes"] == nil { reg["notes"] = [String: Any]() }
        return reg
    }

    static var recordings: [String: [String: Any]] { load()["recordings"] as? [String: [String: Any]] ?? [:] }

    /// Change the registry: read, change, write back (atomically).
    static func update(_ change: (inout [String: [String: Any]], inout [String: Any]) -> Void) {
        var reg = load()
        var recs = reg["recordings"] as? [String: [String: Any]] ?? [:]
        var notes = reg["notes"] as? [String: Any] ?? [:]
        change(&recs, &notes)
        reg["recordings"] = recs
        reg["notes"] = notes
        try? FileManager.default.createDirectory(at: Identity.stateDir, withIntermediateDirectories: true)
        writeJSON(reg, url)
    }
}

enum Meetings {
    /// All finished transcripts: in the default folder and wherever recordings put them (the registry remembers each one).
    /// A folder of the old layout (working files not in .koe yet) is tidied on the way (MeetingFolder.tidy).
    static func dirs() -> [URL] {
        var roots = Set([TranscriptSettings.load().meetingsFolder])
        for r in Registry.recordings.values { if let d = r["out_dir"] as? String { roots.insert((d as NSString).deletingLastPathComponent) } }
        var out = Set<String>()
        for root in roots {
            // hidden files and a transcript being written (<folder>.partial) aren't transcripts
            for name in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] where !name.hasPrefix(".") && !name.hasSuffix(".partial") {
                let d = URL(fileURLWithPath: (root as NSString).appendingPathComponent(name))
                guard MeetingFolder.isTranscript(d) else { continue }
                MeetingFolder.tidy(d)
                out.insert(d.path)
            }
        }
        return out.sorted().map { URL(fileURLWithPath: $0) }
    }

    /// Transcripts lying in the folders that the registry doesn't know as done (for example, made by hand) — add them.
    static func adoptExisting() {
        let found = dirs().compactMap { d -> (String, URL, [String: Any])? in
            let meta = readJSON(MeetingFolder.meta(d))
            guard let src = meta["source"] as? [String: Any], let id = src["session_id"] as? String else { return nil }
            return ("local:\(id)", d, meta)
        }
        Registry.update { recs, _ in
            for (key, d, meta) in found where recs[key]?["status"] as? String != "done" {
                var e: [String: Any] = ["status": "done", "out_dir": d.path, "source": "local",
                                        "processed_at": (meta["processing"] as? [String: Any])?["processed_at"] ?? NSNull()]
                if let f = speakersFile(d) { e["speakers_file"] = f }
                recs[key] = e
            }
        }
    }

    /// Where a recording's audio is now: in audio/ of its transcript or still in the inbox.
    static func sessionDir(_ key: String) -> URL? {
        let id = key.hasPrefix("local:") ? String(key.dropFirst(6)) : key
        var cands: [URL] = []
        if let out = Registry.recordings[key]?["out_dir"] as? String {
            let dir = URL(fileURLWithPath: out)
            MeetingFolder.tidy(dir)
            cands.append(MeetingFolder.audio(dir))
        }
        cands.append(Identity.inboxDir.appendingPathComponent(id))
        return cands.first { FileManager.default.fileExists(atPath: sessionFile($0).path) }
    }

    /// Finished recordings in the inbox (session.json exists) that aren't done and weren't given up on.
    /// A recording without session.json is still being recorded — it's left alone.
    static func pendingInInbox() -> [String] {
        let recs = Registry.recordings
        let dirs = (try? FileManager.default.contentsOfDirectory(at: Identity.inboxDir, includingPropertiesForKeys: nil)) ?? []
        return dirs.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { d in
            guard let sess = try? readSession(d) else { return nil }
            let key = "local:\(sess["id"] as? String ?? d.lastPathComponent)"
            switch recs[key]?["status"] as? String {
            case "failed": return nil
            case "done":
                // the transcript is there, but the audio stayed in the inbox (a crash between the steps) — finish the move
                if let out = recs[key]?["out_dir"] as? String, recs[key]?["audio_left_in"] == nil,
                   FileManager.default.fileExists(atPath: out) {
                    moveAudio(d, to: URL(fileURLWithPath: out))
                }
                return nil
            default: return key
            }
        }
    }

    /// A transcribed recording's audio moves from the inbox into audio/ of its transcript, its session.json into .koe.
    @discardableResult
    static func moveAudio(_ sessionDir: URL, to outDir: URL) -> Bool {
        var target = MeetingFolder.audio(outDir)
        if sessionDir.standardizedFileURL.path == target.standardizedFileURL.path { return true }
        // shouldn't happen; don't overwrite — put it next to it
        if FileManager.default.fileExists(atPath: target.path) { target = outDir.appendingPathComponent("audio_\(sessionDir.lastPathComponent)") }
        do {
            try FileManager.default.moveItem(at: sessionDir, to: target)
            tlog("recording audio moved: \(target.path)")
        } catch {
            tlog("couldn't move the audio \(sessionDir.path) to \(outDir.path): \(error.localizedDescription)")
            return false
        }
        // session.json is Koe's, not the person's: into .koe (in audio_<id> — the odd case above — it stays with the tracks)
        guard target.lastPathComponent == MeetingFolder.audioName else { return true }
        let from = target.appendingPathComponent("session.json"), to = MeetingFolder.session(outDir)
        do {
            try FileManager.default.createDirectory(at: MeetingFolder.data(outDir), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: to.path) { try FileManager.default.removeItem(at: to) }
            try FileManager.default.moveItem(at: from, to: to)
        } catch {
            // the audio is in place; session.json found in audio/ still works (sessionFile)
            tlog("couldn't move session.json into \(MeetingFolder.dataName) in \(outDir.lastPathComponent): \(error.localizedDescription)")
        }
        return true
    }

    /// The transcript's speakers.json (or the old speakers.toml not turned into it yet), if there is one.
    static func speakersFile(_ dir: URL) -> String? {
        [MeetingFolder.speakers(dir), MeetingFolder.oldSpeakers(dir)].map(\.path)
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Every transcript, newest first (the Names window). Its rows are read when it's picked (nameRows).
    static func withSpeakers() -> [CallNames] {
        dirs().map { CallNames(outDir: $0.path) }
            .sorted { ($0.outDir as NSString).lastPathComponent > ($1.outDir as NSString).lastPathComponent }
    }

    /// The rows of the Names window for one transcript: each microphone track, and the voices of system audio (or the
    /// system track itself where voices weren't told apart). Tracks that aren't transcribed have nothing to name.
    static func nameRows(_ dir: URL) -> [SpeakerRow] {
        let meta = readJSON(MeetingFolder.meta(dir))
        let parts = (meta["recording"] as? [String: Any])?["participants"] as? [[String: Any]] ?? []
        let session = readJSON(sessionFile(MeetingFolder.audio(dir)))["tracks"] as? [String: [String: Any]] ?? [:]
        let mics = parts.filter { $0["role"] as? String == "mic" }.count
        var rows: [SpeakerRow] = []
        for p in parts {
            guard let rawFile = p["raw_file"] as? String else { continue }
            let raw = readJSON(MeetingFolder.raw(dir, rawFile))
            guard raw["transcribe"] as? Bool != false else { continue }
            let id = raw["username"] as? String ?? ""
            let name = raw["name"] as? String ?? id
            let segs = (raw["segments"] as? [[String: Any]] ?? []).map { s in
                (start: (s["start"] as? NSNumber)?.doubleValue ?? 0, end: (s["end"] as? NSNumber)?.doubleValue ?? 0,
                 speaker: (s["speaker"] as? NSNumber)?.intValue)
            }
            // where the track's audio is, to listen to a bit of someone's speech
            let file = (raw["audio_file"] as? String).map { MeetingFolder.audio(dir).appendingPathComponent($0) }
            let info = session[id] ?? [:]
            let rate = (info["sample_rate"] as? NSNumber)?.doubleValue ?? 48_000
            let shift = ((info["encoder_delay_frames"] as? NSNumber)?.doubleValue ?? 0) / (rate > 0 ? rate : 48_000)
                - ((raw["start_offset_s"] as? NSNumber)?.doubleValue ?? 0)
            func clip(_ list: [(start: Double, end: Double, speaker: Int?)]) -> VoiceClip? {
                guard let file, FileManager.default.fileExists(atPath: file.path) else { return nil }
                return VoiceClip.pick(list.map { ($0.start, $0.end) }, file: file, shift: shift)
            }
            func talked(_ list: [(start: Double, end: Double, speaker: Int?)]) -> Double {
                unionSpans(list.map { ($0.start, $0.end) }).reduce(0) { $0 + $1.1 - $1.0 }
            }
            if let speakers = raw["speakers"] as? [[String: Any]], !speakers.isEmpty {
                for sp in speakers {
                    guard let label = sp["label"] as? String else { continue }
                    let n = (sp["id"] as? NSNumber)?.intValue
                    let mine = segs.filter { $0.speaker == n }
                    let spName = sp["name"] as? String ?? label
                    rows.append(SpeakerRow(kind: .voice, key: label, title: label, detail: nil, placeholder: label,
                                           speech: talked(mine), clip: clip(mine), name: spName == label ? "" : spName))
                }
            } else {
                let own = raw["name_default"] as? String ?? name
                let title: String
                if id == "system" {
                    title = String(localized: "System audio")
                } else if mics == 1 || id == "mic" {
                    title = mics == 1 ? String(localized: "Microphone") : String(localized: "Microphone 1")
                } else {
                    title = String(localized: "Microphone \(id.dropFirst(4))")
                }
                let input = raw["input"] as? [String: Any]
                let device = (input?["name"] as? String).map { n in (input?["channel"] as? NSNumber).map { "\(n), input \($0)" } ?? n }
                rows.append(SpeakerRow(kind: .track, key: id, title: title, detail: device, placeholder: own,
                                       speech: talked(segs), clip: clip(segs), name: raw["name_default"] != nil ? name : ""))
            }
        }
        return rows
    }
}

// ---------- doing one job ----------

/// Only one process transcribes at a time: the app, or a test from the command line (--record-test).
final class TranscribeLock {
    private let fd: Int32

    init() {
        try? FileManager.default.createDirectory(at: Identity.stateDir, withIntermediateDirectories: true)
        fd = open(Identity.stateDir.appendingPathComponent("transcribe.lock").path, O_CREAT | O_RDWR, 0o644)
    }

    deinit { close(fd) }

    func tryLock() -> Bool { flock(fd, LOCK_EX | LOCK_NB) == 0 }
    func lock() { flock(fd, LOCK_EX) }
    func unlock() { flock(fd, LOCK_UN) }
}

/// Transcribing recordings: the speech model (downloaded and loaded the first time it's needed, kept while
/// there's work) and the registry. Used by the queue and by --record-test.
final class TranscriptionWork: @unchecked Sendable {
    private var transcriber: Transcriber?

    /// The hallucinations list: a file in the data folder, created from the app's starting list the first time.
    static var hallucinationsFile: URL { Identity.supportDir.appendingPathComponent("hallucinations.txt") }

    func ready(step: @escaping @Sendable (ModelStep) -> Void) async throws -> Transcriber {
        if let transcriber { return transcriber }
        // download what's missing (or wait for the download that's going): ModelsUnavailable if it can't be done now
        try await ModelStore.shared.ensure(SpeechModel.required, step: step)
        let engine = try await ParakeetEngine(step: step)
        let detector = try await SpeechDetector()
        let file = Self.hallucinationsFile
        if !FileManager.default.fileExists(atPath: file.path), let bundled = Bundle.main.url(forResource: "hallucinations", withExtension: "txt") {
            try? FileManager.default.createDirectory(at: Identity.supportDir, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: bundled, to: file)
        }
        let t = Transcriber(engine: engine, detector: detector, phrases: loadHallucinations(file))
        transcriber = t
        return t
    }

    /// Free the model's memory (the queue is empty).
    func unload() async {
        if let e = transcriber?.engine as? ParakeetEngine { await e.unload() }
        transcriber = nil
    }

    /// Transcribe a recording and write it down in the registry; after that its audio moves into the transcript.
    /// Returns the transcript folder and the meta.json written.
    func transcribe(_ key: String, force: Bool, step: @escaping @Sendable (ModelStep) -> Void,
                    progress: @escaping (Double) -> Void, notify: @escaping (String, String) -> Void) async throws -> URL {
        guard let dir = Meetings.sessionDir(key) else {
            throw TranscriberError(String(localized: "Couldn't find the audio for recording \(String(key.dropFirst(6)))"))
        }
        let t = try await ready(step: step)
        var outDir: URL
        do {
            outDir = try await t.process(dir, force: force, modelStep: step, progress: progress, notify: notify)
        } catch let done as AlreadyProcessed {
            tlog("already transcribed: \(key) → \(done.dir.path)")
            outDir = done.dir
        }
        let meta = readJSON(MeetingFolder.meta(outDir))
        var entry: [String: Any] = ["status": "done", "out_dir": outDir.path, "source": "local",
                                    "processed_at": (meta["processing"] as? [String: Any])?["processed_at"] ?? NSNull()]
        if let f = Meetings.speakersFile(outDir) { entry["speakers_file"] = f }
        // the transcript is ready; if the audio can't move it stays in the inbox, but isn't transcribed again
        if !Meetings.moveAudio(dir, to: outDir) { entry["audio_left_in"] = dir.path }
        Registry.update { recs, _ in recs[key] = entry }
        return outDir
    }
}

// ---------- the queue ----------

@MainActor
final class TranscriptionQueue {
    static let shared = TranscriptionQueue()

    /// Something changed (phase, progress, the list) — redraw the icon.
    var onChange: (() -> Void)?
    /// A notification for the person: title, text, the folder a click opens.
    var notify: ((String, String, URL?) -> Void)?
    private(set) var phase: QueuePhase = .idle
    private(set) var current: QueueJob?
    private(set) var jobs: [QueueJob] = []
    /// Why recordings are waiting for the speech models (one line for the menu); nil — they aren't.
    private(set) var modelsProblem: String?
    private let work = TranscriptionWork()
    private let lock = TranscribeLock()
    private var locked = false
    private var task: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var wakeTimer: Timer?
    private var lastChange = 0.0
    private var stopping = false
    static let queueFile = Identity.stateDir.appendingPathComponent("queue.json")
    /// Seconds between attempts after an error (KOE_RETRY_DELAY — for testing).
    let retryDelay = Double(ProcessInfo.processInfo.environment["KOE_RETRY_DELAY"] ?? "") ?? 60

    var paused: Bool {
        get { UserDefaults.standard.bool(forKey: "pipelinePaused") }
        set { UserDefaults.standard.set(newValue, forKey: "pipelinePaused") }
    }

    var busy: Bool { task != nil }
    /// Recordings waiting (not counting the current one).
    var waiting: Int { jobs.filter { $0.kind == .transcribe }.count }

    /// At launch: the saved queue, plus recordings in the inbox that aren't transcribed yet (the app was quit in the
    /// middle of transcribing or recording), plus transcripts already in the folders and names that changed meanwhile.
    func start() {
        if let data = try? Data(contentsOf: Self.queueFile), let saved = try? JSONDecoder().decode([QueueJob].self, from: data) {
            jobs = saved
        }
        // recordings that waited for the speech models get a fresh try at launch (the Mac may be online now)
        for i in jobs.indices where jobs[i].waiting == true { jobs[i].notBefore = nil }
        Meetings.adoptExisting()
        for key in Meetings.pendingInInbox() where !jobs.contains(where: { $0.kind == .transcribe && $0.key == key }) {
            jobs.append(QueueJob(kind: .transcribe, key: key))
        }
        checkNames()
        save()
        if paused { phase = .paused }
        kick()
    }

    /// A recording stopped: it goes into the queue.
    func add(recording dir: URL) {
        let key = "local:\(dir.lastPathComponent)"
        guard !jobs.contains(where: { $0.kind == .transcribe && $0.key == key }), current?.key != key else { return }
        jobs.append(QueueJob(kind: .transcribe, key: key))
        save()
        kick()
    }

    /// Transcribe a finished recording again (Settings) or a failed one (Try Again).
    func reprocess(_ key: String) {
        jobs.removeAll { $0.kind == .transcribe && $0.key == key }
        jobs.append(QueueJob(kind: .transcribe, key: key, force: true))
        save()
        kick()
    }

    /// Names in Settings changed — update them in all finished transcripts.
    func refreshNames() {
        jobs.removeAll { $0.kind == .refreshNames }
        jobs.append(QueueJob(kind: .refreshNames))
        save()
        kick()
    }

    /// Speaker names of one recording from the Names window.
    func setSpeakers(_ outDir: String, _ names: SpeakerNames.Names) {
        jobs.append(QueueJob(kind: .setSpeakers, outDir: outDir, names: names.speakers, tracks: names.tracks))
        save()
        kick()
    }

    func pause() {
        paused = true
        task?.cancel()   // the current job stops and starts over after Resume
        phase = .paused
        changed(force: true)
    }

    func resume() {
        paused = false
        if task == nil { phase = .idle }
        kick()
        changed(force: true)
    }

    /// The models may be there now (downloaded, the Mac is online again): recordings that waited for them go now.
    func retryWaiting() {
        guard jobs.contains(where: { $0.waiting == true }) else { return }
        for i in jobs.indices where jobs[i].waiting == true { jobs[i].notBefore = nil }
        save()
        kick()
        changed(force: true)
    }

    /// The app is quitting: the current job stops, the queue continues on the next launch.
    func stop() {
        stopping = true
        task?.cancel()
        save()
    }

    /// Start working if there's a job whose time has come and nothing is going.
    func kick() {
        guard task == nil, !paused, !stopping else { return }
        let now = Date().timeIntervalSince1970
        guard let i = jobs.firstIndex(where: { ($0.notBefore ?? 0) <= now }) else {
            scheduleWake()
            return
        }
        // another Koe process (a test from the command line) is transcribing — try again in a few seconds
        if !locked {
            guard lock.tryLock() else {
                wakeTimer?.invalidate()
                wakeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { _ in MainActor.assumeIsolated { self.kick() } }
                return
            }
            locked = true
        }
        let job = jobs.remove(at: i)
        current = job
        save()
        if activity == nil {
            // while transcribing, the Mac doesn't fall asleep from being idle
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                             reason: "\(Identity.appName): transcribing")
        }
        phase = job.kind == .transcribe ? .transcribing(0) : .names
        changed(force: true)
        task = Task { await self.run(job) }
    }

    private func run(_ job: QueueJob) async {
        switch job.kind {
        case .transcribe: await transcribe(job)
        case .refreshNames, .setSpeakers: await names(job)
        }
        task = nil
        current = nil
        save()
        // nothing to do right now (recordings may wait for a retry or the models): let the model and the Mac go
        let now = Date().timeIntervalSince1970
        if !jobs.contains(where: { ($0.notBefore ?? 0) <= now }) || paused {
            if !paused { await work.unload() }
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
            if locked { lock.unlock(); locked = false }
            if jobs.isEmpty && !paused { checkNames() }
        }
        phase = paused ? .paused : .idle
        changed(force: true)
        kick()
    }

    private func transcribe(_ job: QueueJob) async {
        guard let key = job.key else { return }
        let started = Date()
        let step: @Sendable (ModelStep) -> Void = { s in
            Task { @MainActor in
                guard self.current == job, !self.paused else { return }
                switch s {
                case .downloading(let f): self.phase = .downloading(f)
                case .preparing: self.phase = .preparing
                }
                self.changed()
            }
        }
        do {
            let out = try await work.transcribe(key, force: job.force == true, step: step, progress: { f in
                Task { @MainActor in
                    guard self.current == job, !self.paused else { return }
                    self.phase = .transcribing(f)
                    self.changed()
                }
            }, notify: { title, text in
                Task { @MainActor in self.notify?(title, text, nil) }
            })
            modelsProblem = nil
            let meta = readJSON(MeetingFolder.meta(out))
            let duration = ((meta["recording"] as? [String: Any])?["duration_s"] as? NSNumber)?.doubleValue ?? 0
            notify?(String(localized: "Transcript ready"),
                    String(localized: "\(out.lastPathComponent) — \(humanDuration(duration)), took \(humanDuration(Date().timeIntervalSince(started)))"),
                    out)
        } catch let e as ModelsUnavailable {
            waitForModels(job, key, e)
        } catch is CancellationError {
            // paused or quitting: back to the front of the queue, it starts over
            tlog("stopped (pause or quit): \(key) — it starts over next time")
            jobs.insert(job, at: 0)
            save()
        } catch {
            if Task.isCancelled {
                jobs.insert(job, at: 0)
                save()
                return
            }
            failed(job, key, error)
        }
    }

    /// The models couldn't be downloaded: the recording waits (no attempt is counted). It's tried again when the Mac is
    /// back online, when a download from the window or Settings finishes, or in 5 minutes (10 when offline: coming back
    /// online calls sooner). The person hears about it once, until a transcription works again.
    private func waitForModels(_ job: QueueJob, _ key: String, _ e: ModelsUnavailable) {
        tlog("waiting for the speech models: \(key) — \(e.errorDescription ?? "")")
        var again = job
        again.waiting = true
        again.notBefore = Date().timeIntervalSince1970 + (e.reason == .offline ? 600 : 300)
        jobs.insert(again, at: 0)
        save()
        if modelsProblem == nil {
            notify?(String(localized: "Transcription is waiting"),
                    (e.errorDescription ?? "") + " " + String(localized: "Your recording is saved and will be transcribed after that."), nil)
        }
        modelsProblem = e.short
        if e.reason == .offline { Network.whenOnline { Task { @MainActor in self.retryWaiting() } } }
    }

    /// An error: the attempt is counted. A new recording is tried again in a minute, 3 times in all; then it's Failed ▸.
    /// Transcribing again (force) isn't repeated: the old transcript stays as it was.
    private func failed(_ job: QueueJob, _ key: String, _ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        var attempts = 0
        var wasDone = false
        Registry.update { recs, _ in
            var rec = recs[key] ?? [:]
            attempts = (rec["attempts"] as? Int ?? 0) + 1
            wasDone = rec["status"] as? String == "done"
            rec["attempts"] = attempts
            rec["last_error"] = message
            rec["last_attempt"] = isoLocal(Date())
            if job.force == true {
                if !wasDone { rec["status"] = "failed" }   // the old transcript stays in force
            } else {
                rec["status"] = attempts >= maxAttempts ? "failed" : "error"
            }
            recs[key] = rec
        }
        tlog("error transcribing \(key) (attempt \(attempts) of \(maxAttempts)): \(message)")
        let title = recordingTitle(key)
        if job.force == true {
            notify?(String(localized: "Something went wrong"), String(localized: "Couldn't transcribe the recording from \(title) again: \(message)"), nil)
        } else if attempts >= maxAttempts {
            notify?(String(localized: "Transcription failed"),
                    String(localized: "The recording from \(title) failed \(maxAttempts) times in a row, so \(Identity.appName) stopped trying. You can try again from the menu."), nil)
        } else {
            var again = job
            again.waiting = nil
            again.notBefore = Date().timeIntervalSince1970 + retryDelay
            jobs.append(again)
            save()
            notify?(String(localized: "Something went wrong"),
                    String(localized: "The recording from \(title): \(message). \(Identity.appName) will try again in a minute."), nil)
        }
    }

    /// The earliest retry — wake up then.
    private func scheduleWake() {
        wakeTimer?.invalidate()
        guard !paused, let next = jobs.compactMap(\.notBefore).min() else { return }
        let delay = max(1, next - Date().timeIntervalSince1970)
        wakeTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { self.kick() } }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Identity.stateDir, withIntermediateDirectories: true)
        let all = (current.map { [$0] } ?? []) + jobs   // the current job too: after a crash it starts over
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: Self.queueFile, options: .atomic) }
    }

    /// Redraw — progress at most a few times a second.
    private func changed(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastChange > 0.25 else { return }
        lastChange = now
        onChange?()
    }

    // ---------- speaker names ----------

    /// The names in Settings ("Your name", "Other people") changed since the last update, or someone edited speakers.json
    /// by hand (or there's an old speakers.toml to turn into it) — update the names in those transcripts. Nothing is
    /// transcribed again.
    func checkNames() {
        let s = TranscriptSettings.load()
        let names = "[\(jsonString(s.me)), \(jsonString(s.other))]"   // the same string the Python pipeline kept
        let notes = Registry.load()["notes"] as? [String: Any] ?? [:]
        if notes["settings_names"] as? String != names {
            if !jobs.contains(where: { $0.kind == .refreshNames && $0.dirs == nil }) { jobs.append(QueueJob(kind: .refreshNames)) }
            return
        }
        // the files' times as of the last update ("speakers_mtimes" was Python's, of speakers.toml only: a new key, so
        // every old speakers.toml is turned into speakers.json once)
        let seen = notes["speakers_files_mtimes"] as? [String: Double] ?? [:]
        let changed = Set(speakersFiles().filter { seen[$0.key] != $0.value }.map { MeetingFolder.owner(ofDataFile: $0.key) })
        if !changed.isEmpty { jobs.append(QueueJob(kind: .refreshNames, dirs: changed.sorted())) }
    }

    private func speakersFiles() -> [String: Double] {
        var out: [String: Double] = [:]
        for d in Meetings.dirs() {
            for file in [MeetingFolder.speakers(d), MeetingFolder.oldSpeakers(d)] {
                let f = file.path
                if let m = (try? FileManager.default.attributesOfItem(atPath: f))?[.modificationDate] as? Date { out[f] = m.timeIntervalSince1970 }
            }
        }
        return out
    }

    private func names(_ job: QueueJob) async {
        let notify = self.notify
        let settings = TranscriptSettings.load()
        await Task.detached(priority: .utility) {
            let say: (String, String) -> Void = { t, x in Task { @MainActor in notify?(t, x, nil) } }
            switch job.kind {
            case .setSpeakers:
                guard let dir = job.outDir, let names = job.names else { return }
                SpeakerNames.set(URL(fileURLWithPath: dir), .init(speakers: names, tracks: job.tracks ?? [:]), settings: settings, notify: say)
            default:
                SpeakerNames.refreshAll(job.dirs?.map { URL(fileURLWithPath: $0) }, settings: settings, notify: say)
            }
        }.value
        // done (or it can't be done at all — not repeated forever): remember the names and the files' times
        let files = speakersFiles()
        Registry.update { _, notes in
            if job.kind == .refreshNames && job.dirs == nil { notes["settings_names"] = "[\(jsonString(settings.me)), \(jsonString(settings.other))]" }
            var m = notes["speakers_files_mtimes"] as? [String: Double] ?? [:]
            for (k, v) in files { m[k] = v }
            notes["speakers_files_mtimes"] = m
            notes["speakers_mtimes"] = nil
        }
    }
}

func jsonString(_ s: String) -> String {
    (try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
        .map { String(decoding: $0, as: UTF8.self) } ?? "\"\(s)\""
}
