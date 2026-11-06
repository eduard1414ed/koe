// The speech models: what Koe downloads, how big each one is, and getting or deleting them (stage 9).
//
// Everything goes through ModelStore: the setup window, Settings → Speech models and transcription itself. One
// download at a time; whoever needs a model that's being downloaded waits for that same download, so the window
// and the queue never fetch the same files twice. The download lives in the app, not in a window: closing the
// window doesn't stop it.
//
// Before downloading, the free space is checked. Without the internet (or when the server can't be reached) the
// download fails with ModelsUnavailable: the queue keeps the recording and tries again when the Mac is back online
// (TranscriptionQueue), instead of counting it as a failed transcription.
//
// A deleted model is downloaded again the first time it's needed.
@preconcurrency import FluidAudio
import Foundation
import Network
import os

enum SpeechModel: String, CaseIterable, Identifiable {
    case recognizer, detector, voices, vocabulary
    var id: String { rawValue }

    /// What every transcription needs; voices — only recordings with system audio, but it's small and part of setup.
    static let required: [SpeechModel] = [.recognizer, .detector, .voices]

    var title: String {
        switch self {
        case .recognizer: String(localized: "Speech recognition")
        case .detector: String(localized: "Speech detector")
        case .voices: String(localized: "Telling voices apart")
        case .vocabulary: String(localized: "Vocabulary helper")
        }
    }

    var detail: String {
        switch self {
        case .recognizer: String(localized: "Parakeet Ultra: turns speech into text")
        case .detector: String(localized: "Silero VAD: finds where someone is talking")
        case .voices: String(localized: "Splits system audio into Speaker 1, 2…")
        case .vocabulary: String(localized: "Only used when Vocabulary has words")
        }
    }

    /// The download, in bytes: the files of FluidAudio 0.18.0's models as they lie on disk after downloading
    /// (measured in stage 9; the files are already compiled, so on disk is the same as over the network).
    var size: Int64 {
        switch self {
        case .recognizer: 632_314_500
        case .detector: 1_063_427
        case .voices: 21_787_007
        case .vocabulary: 102_803_869
        }
    }

    var folder: URL {
        switch self {
        case .recognizer: SpeechModels.asrDir
        case .detector: SpeechModels.dir.appendingPathComponent(Repo.vad.folderName)
        case .voices: SpeechModels.dir.appendingPathComponent(Repo.diarizer.folderName)
        case .vocabulary: SpeechModels.vocabularyDir
        }
    }

    /// All its files are there, and none is half-downloaded (FluidAudio keeps those as *.partial).
    var isDownloaded: Bool {
        let present: Bool
        switch self {
        case .recognizer: present = SpeechModels.downloaded
        case .detector: present = ModelNames.VAD.requiredModels.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        case .voices: present = VoiceSplitter.downloaded
        case .vocabulary: present = CtcModels.modelsExist(at: folder)
        }
        return present && !hasPartialFiles
    }

    private var hasPartialFiles: Bool {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let f = files?.nextObject() as? URL { if f.pathExtension == "partial" { return true } }
        return false
    }

    /// What its folder takes on disk now (also a half-finished download), 0 — no folder.
    var sizeOnDisk: Int64 {
        var total: Int64 = 0
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        while let f = files?.nextObject() as? URL { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        return total
    }

    /// Download it (if needed) and load it once, so it's also prepared for this Mac — then the first transcription
    /// doesn't wait for that. The loaded model is let go right away. progress: the share downloaded (nil — unknown)
    /// or "preparing".
    func fetch(_ progress: @escaping @Sendable (ModelStep) -> Void) async throws {
        // FluidAudio gives one share for downloading and preparing: downloading is its first half
        let handler: ProgressHandler = { p in
            switch p.phase {
            case .listing: progress(.downloading(nil))
            case .downloading: progress(.downloading(min(1, p.fractionCompleted * 2)))
            case .compiling: progress(.preparing)
            }
        }
        switch self {
        case .recognizer: _ = try await AsrModels.download(to: SpeechModels.asrDir, version: SpeechModels.version, progressHandler: handler)
        case .detector: _ = try await VadManager(config: .default, modelDirectory: Identity.supportDir, progressHandler: handler)
        case .voices: _ = try await OfflineDiarizerModels.load(from: SpeechModels.dir, progressHandler: handler)
        case .vocabulary:
            progress(.downloading(nil))   // FluidAudio doesn't tell how far this one is
            _ = try await CtcModels.download(to: folder, variant: SpeechModels.vocabularyVariant)
        }
    }
}

/// The models can't be downloaded right now: no internet, the server doesn't answer, or not enough space.
/// Not a failed transcription: the recording waits and is tried again later.
struct ModelsUnavailable: LocalizedError {
    enum Reason: Equatable {
        case offline
        case server
        case noSpace(need: Int64, free: Int64)
    }
    let reason: Reason
    let models: [SpeechModel]

    var bytes: Int64 { models.reduce(0) { $0 + $1.size } }

    var errorDescription: String? {
        let size = humanSize(Double(bytes))
        switch reason {
        case .offline:
            return String(localized: "No internet connection. \(Identity.appName) needs it once to download its speech models (\(size)).")
        case .server:
            return String(localized: "Couldn't reach the download server (huggingface.co) to get the speech models (\(size)).")
        case .noSpace(let need, let free):
            return String(localized: "Not enough free space: downloading the speech models (\(size)) needs \(humanSize(Double(need))) free, and your Mac has \(humanSize(Double(free))).")
        }
    }

    /// One line for the menu.
    var short: String {
        switch reason {
        case .offline: String(localized: "No internet: will try again when you're online")
        case .server: String(localized: "Download server not answering: will try again soon")
        case .noSpace(let need, _): String(localized: "Not enough disk space: need \(humanSize(Double(need)))")
        }
    }
}

/// Is the Mac online? Watches the network; others can wait for it to come back.
enum Network {
    private static let monitor = NWPathMonitor()
    private static let state = OSAllocatedUnfairLock(initialState: (online: true, started: false, waiting: [@Sendable () -> Void]()))

    static func start() {
        guard !state.withLock({ $0.started }) else { return }
        state.withLock { $0.started = true }
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            let call = state.withLock { s -> [@Sendable () -> Void] in
                let was = s.online
                s.online = online
                guard online, !was else { return [] }
                defer { s.waiting = [] }
                return s.waiting
            }
            for f in call { f() }
        }
        monitor.start(queue: DispatchQueue(label: "koe.network"))
    }

    /// Until the first answer from the system it says yes: better to try than to wait for nothing.
    static var online: Bool { state.withLock { $0.online } }

    /// Call this once the Mac is back online (any thread).
    static func whenOnline(_ f: @escaping @Sendable () -> Void) { state.withLock { $0.waiting.append(f) } }
}

/// Free space on the disk with the data folder, as macOS counts it for things the person wants (it can clear caches).
func freeDiskSpace() -> Int64? {
    // KOE_FREE_SPACE_TEST=bytes — pretend there's only that much (for testing the "not enough space" message)
    if let fake = ProcessInfo.processInfo.environment["KOE_FREE_SPACE_TEST"].flatMap({ Int64($0) }) { return fake }
    let url = FileManager.default.fileExists(atPath: Identity.supportDir.path) ? Identity.supportDir : home
    return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
}

/// The error came from the network (no connection, the server, a stalled download), not from the files or the models.
func isNetworkError(_ error: Error) -> Bool {
    if let d = error as? DownloadError {
        switch d {
        case .downloadFailed(_, let underlying): return isNetworkError(underlying)
        case .invalidResponse, .rateLimited, .htmlErrorResponse, .stalled, .networkDisabled: return true
        case .modelNotFound, .invalidArtifact, .modelMissing: return false
        }
    }
    var e: NSError? = error as NSError
    while let n = e {
        if n.domain == NSURLErrorDomain && n.code != NSURLErrorCancelled { return true }
        if n.domain == "HTTP" { return true }
        if n.domain == NSPOSIXErrorDomain && [ENETDOWN, ENETUNREACH, EHOSTUNREACH, ECONNREFUSED, ECONNRESET, ETIMEDOUT, EPERM].contains(Int32(n.code)) { return true }
        e = n.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return false
}

@MainActor
final class ModelStore: ObservableObject {
    static let shared = ModelStore()

    enum Activity: Equatable {
        case idle
        case downloading(Double?)   // share of the whole download (nil — not known yet)
        case preparing              // getting a downloaded model ready for this Mac
        case failed(String)         // why the last download didn't work
    }

    @Published private(set) var activity: Activity = .idle
    /// The models of the download going on now (or the last one, if it failed).
    @Published private(set) var batch: [SpeechModel] = []
    /// Bumped when models appear or are deleted: views read isDownloaded again.
    @Published private(set) var revision = 0
    /// Something changed — the menu and the icon.
    var onChange: (() -> Void)?
    /// A download finished — the queue can try the recordings that waited for it.
    var onDownloaded: (() -> Void)?
    private var task: Task<Void, Error>?
    private var listeners: [UUID: @Sendable (ModelStep) -> Void] = [:]
    private var retrying = false

    var busy: Bool { task != nil }
    var missingRequired: [SpeechModel] { SpeechModel.required.filter { !$0.isDownloaded } }

    /// The person asked for the models (setup or Settings): if the app quits before they're done, the download
    /// continues on the next launch. Deleting a required model takes the wish back.
    var wanted: Bool {
        get { UserDefaults.standard.bool(forKey: "modelsWanted") }
        set { UserDefaults.standard.set(newValue, forKey: "modelsWanted") }
    }

    /// At launch: finish a download the person asked for.
    func resumeIfWanted() {
        if wanted && !missingRequired.isEmpty { download(missingRequired) }
    }

    /// Start downloading in the background (the setup window, Settings). If it can't be done now because of the
    /// network, it's tried again once the Mac is online (and every 5 minutes, if the server didn't answer).
    func download(_ models: [SpeechModel]) {
        if models.contains(where: SpeechModel.required.contains) { wanted = true }
        Task {
            do {
                try await ensure(models)
            } catch let e as ModelsUnavailable where e.reason == .offline || e.reason == .server {
                retryLater(models, after: e.reason == .server ? 300 : nil)
            } catch {}
        }
    }

    private func retryLater(_ models: [SpeechModel], after seconds: Double?) {
        guard !retrying else { return }
        retrying = true
        let again: @Sendable () -> Void = { Task { @MainActor in
            guard self.retrying else { return }
            self.retrying = false
            if !models.allSatisfy(\.isDownloaded) { self.download(models) }
        } }
        if let seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: again)
        } else {
            Network.whenOnline(again)
        }
    }

    /// Make sure these models are on disk: download what's missing, or wait for the download that's already going.
    /// step — progress for whoever waits (any thread). Throws ModelsUnavailable when it can't be done now.
    func ensure(_ models: [SpeechModel], step: (@Sendable (ModelStep) -> Void)? = nil) async throws {
        let id = UUID()
        if let step { listeners[id] = step }
        defer { listeners[id] = nil }
        while true {
            let missing = models.filter { !$0.isDownloaded }
            guard !missing.isEmpty else { return }
            if let task {
                try await task.value   // someone else's download; then check again — it may not have had ours
                continue
            }
            let t = Task { try await self.run(missing) }
            task = t
            defer { if task == t { task = nil } }
            try await t.value
        }
    }

    private func run(_ models: [SpeechModel]) async throws {
        batch = models
        let total = models.reduce(0) { $0 + $1.size }
        let free = freeDiskSpace()
        // room for the files plus what CoreML keeps once they're prepared (about half as much again), and some air
        let need = total + max(100_000_000, total / 2)
        if let free, free < need { throw unavailable(.noSpace(need: need, free: free), models) }
        if !Network.online { throw unavailable(.offline, models) }
        set(.downloading(0))
        tlog("downloading models: \(models.map(\.rawValue).joined(separator: ", ")) (\(humanSize(Double(total))))")
        let t0 = Date()
        var done: Int64 = 0
        for m in models where !m.isDownloaded {
            let before = done
            do {
                let size = m.size
                try await Task.detached {
                    try await m.fetch { s in
                        Task { @MainActor in
                            switch s {
                            case .downloading(let f): self.set(.downloading(f.map { (Double(before) + $0 * Double(size)) / Double(total) }))
                            case .preparing: self.set(.preparing)
                            }
                        }
                    }
                }.value
            } catch {
                tlog("couldn't download \(m.rawValue): \(error.localizedDescription)")
                revision += 1
                if isNetworkError(error) { throw unavailable(Network.online ? .server : .offline, models) }
                set(.failed(error.localizedDescription))
                throw error
            }
            done += m.size
            revision += 1
            set(.downloading(Double(done) / Double(total)))
        }
        tlog(String(format: "models ready in %.0f s", Date().timeIntervalSince(t0)))
        set(.idle)
        onDownloaded?()
    }

    private func unavailable(_ reason: ModelsUnavailable.Reason, _ models: [SpeechModel]) -> ModelsUnavailable {
        let e = ModelsUnavailable(reason: reason, models: models)
        tlog("models can't be downloaded now: \(e.errorDescription ?? "")")
        set(.failed(e.errorDescription ?? ""))
        return e
    }

    private func set(_ a: Activity) {
        guard a != activity else { return }
        activity = a
        let step: ModelStep? = switch a {
        case .downloading(let f): .downloading(f)
        case .preparing: .preparing
        default: nil
        }
        if let step { for l in listeners.values { l(step) } }
        onChange?()
    }

    /// Delete a model's files. Not while it's in use: the window disables the button then (see canDelete).
    func delete(_ m: SpeechModel) {
        try? FileManager.default.removeItem(at: m.folder)
        tlog("model deleted: \(m.rawValue) (\(m.folder.path))")
        if SpeechModel.required.contains(m) { wanted = false }
        if case .failed = activity { set(.idle) }
        revision += 1
        onChange?()
    }
}
