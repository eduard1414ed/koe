// What's in a transcript folder. The person sees what they need: transcript.md and audio/ with the tracks (and their
// own copies — transcript.edited-<date>.md — and notes). Koe's working files are in the hidden .koe folder next to them:
//
//   2026-11-09_1103/
//     transcript.md
//     audio/              mic.aac, system.aac… (mic-2.aac and so on with several microphones)
//     .koe/
//       meta.json         where the recording came from, how it was transcribed; it appearing means "done"
//       speakers.json     the speakers' names (Settings → Names writes it, it can be edited by hand)
//       session.json      the recording's tracks and timeline (written while recording, moved here with the audio)
//       raw/<track>.json  everything recognized on each track; "raw_file" in meta.json is relative to .koe
//
// In Koe 1.0.1 and earlier these lay in the folder itself (session.json in audio/). Such a folder is tidied once — the first time Koe
// finds it (tidy): everything moves into .koe, meta.json last, so a move cut off half-way is finished next time.
// The audio and transcript.md don't move.
import Foundation

enum MeetingFolder {
    static let dataName = ".koe"
    static let transcriptName = "transcript.md"
    static let audioName = "audio"

    static func data(_ dir: URL) -> URL { dir.appendingPathComponent(dataName, isDirectory: true) }
    static func meta(_ dir: URL) -> URL { data(dir).appendingPathComponent("meta.json") }
    static func speakers(_ dir: URL) -> URL { data(dir).appendingPathComponent(SpeakerNames.file) }
    static func oldSpeakers(_ dir: URL) -> URL { data(dir).appendingPathComponent(SpeakerNames.oldFile) }
    static func session(_ dir: URL) -> URL { data(dir).appendingPathComponent("session.json") }
    static func transcript(_ dir: URL) -> URL { dir.appendingPathComponent(transcriptName) }
    static func audio(_ dir: URL) -> URL { dir.appendingPathComponent(audioName, isDirectory: true) }
    /// A track's raw/<track>.json: "raw_file" in meta.json.
    static func raw(_ dir: URL, _ rawFile: String) -> URL { data(dir).appendingPathComponent(rawFile) }

    /// The transcript folder a working file belongs to: …/<folder>/.koe/speakers.json → …/<folder>.
    static func owner(ofDataFile path: String) -> String {
        ((path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
    }

    /// A finished transcript is here (its meta.json, in .koe or — not tidied yet — in the folder itself).
    static func isTranscript(_ dir: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: meta(dir).path) || oldLayout(dir)
    }

    /// The layout of Koe 1.0.1 and earlier: meta.json of a Koe transcript lies in the folder itself.
    private static func oldLayout(_ dir: URL) -> Bool {
        let old = dir.appendingPathComponent("meta.json")
        guard FileManager.default.fileExists(atPath: old.path) else { return false }
        // only a meta.json Koe wrote: some other file of that name isn't touched
        let m = readJSON(old)
        return m["source"] is [String: Any] && m["recording"] is [String: Any]
    }

    private static let lock = NSLock()

    /// Move the working files of an old folder into .koe. Nothing to do — nothing happens (cheap: a file check).
    static func tidy(_ dir: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard oldLayout(dir), !FileManager.default.fileExists(atPath: meta(dir).path) else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: data(dir), withIntermediateDirectories: true)
        } catch {
            tlog("\(dir.lastPathComponent): couldn't make \(dataName): \(error.localizedDescription)")
            return
        }
        // meta.json last: while it's still in the folder, the move isn't finished
        let moves: [(URL, URL)] = [
            (dir.appendingPathComponent("raw"), data(dir).appendingPathComponent("raw")),
            (dir.appendingPathComponent(SpeakerNames.file), speakers(dir)),
            (dir.appendingPathComponent(SpeakerNames.oldFile), oldSpeakers(dir)),
            (audio(dir).appendingPathComponent("session.json"), session(dir)),
            (dir.appendingPathComponent("meta.json"), meta(dir)),
        ]
        for (from, to) in moves where fm.fileExists(atPath: from.path) && !fm.fileExists(atPath: to.path) {
            do {
                try fm.moveItem(at: from, to: to)
            } catch {
                tlog("\(dir.lastPathComponent): couldn't move \(from.lastPathComponent) into \(dataName): \(error.localizedDescription)")
                return
            }
        }
        tlog("\(dir.lastPathComponent): working files moved into \(dataName)")
    }
}
