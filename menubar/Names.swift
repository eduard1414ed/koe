// Speaker names in finished transcripts — changed without transcribing again (until stage 7 this was Python's
// koe_names.py; the rules are the same).
//
// Where names come from:
//   - Settings: "Your name" (the first microphone track) and "Other people" (system audio). A track named in
//     Settings → Inputs keeps its name (name_fixed in raw/*.json);
//   - speakers.json in the transcript folder (in its hidden .koe, MeetingFolder.swift): "speakers" — the voices told apart on the system track, label
//     ("Speaker 1") → name; "tracks" — tracks renamed for this recording only, track ("mic-2", or "system" where voices
//     weren't told apart) → name. The Names window writes it, it can be edited by hand. The same name on two rows is
//     one person: their lines merge. The old speakers.toml is read once and turned into speakers.json.
// transcript.md is put together again from raw/*.json; the edits made by hand are kept as a copy (protectManualEdits).
import Foundation

enum SpeakerNames {
    static let file = "speakers.json"
    static let oldFile = "speakers.toml"
    static let about = "Who's who in this recording: on the left is how a speaker is labeled, on the right is their name. "
        + "\"speakers\" are the voices of system audio, \"tracks\" are microphones renamed for this recording (mic, mic-2…). "
        + "It's easier to change in Settings → Names. You can edit it here too: the transcript updates the next time "
        + "Koe looks (on launch, after a transcription). The same name on two rows means it's the same person."

    struct Names: Equatable {
        var speakers: [String: String] = [:]   // label → name
        var tracks: [String: String] = [:]     // track → name, for this recording only
    }

    enum Saved {
        case none                       // no file
        case names(Names)
        case broken(String)             // the file (its name) can't be read
    }

    /// The speakers' names of a transcript. If there's only the old speakers.toml, it becomes speakers.json.
    static func read(_ dir: URL) -> Saved {
        let json = MeetingFolder.speakers(dir), toml = MeetingFolder.oldSpeakers(dir)
        if FileManager.default.fileExists(atPath: json.path) {
            guard let data = try? Data(contentsOf: json),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let names = o["speakers"] as? [String: String] ?? (o["speakers"] == nil ? [:] : nil),
                  let tracks = o["tracks"] as? [String: String] ?? (o["tracks"] == nil ? [:] : nil) else {
                tlog("\(json.path) can't be read")
                return .broken(file)
            }
            return .names(Names(speakers: names, tracks: tracks))
        }
        guard let text = try? String(contentsOf: toml, encoding: .utf8) else { return .none }
        guard let names = parseToml(text) else {
            tlog("\(toml.path) can't be read")
            return .broken(oldFile)
        }
        do {
            try write(dir, Names(speakers: names))
            try FileManager.default.removeItem(at: toml)
            tlog("\(dir.lastPathComponent): speakers.toml turned into speakers.json")
        } catch {
            tlog("\(dir.lastPathComponent): couldn't turn speakers.toml into speakers.json: \(error.localizedDescription)")
        }
        return .names(Names(speakers: names))
    }

    static func write(_ dir: URL, _ names: Names) throws {
        var o: [String: Any] = ["about": about, "speakers": names.speakers]
        if !names.tracks.isEmpty { o["tracks"] = names.tracks }
        let data = try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: MeetingFolder.data(dir), withIntermediateDirectories: true)
        try data.write(to: MeetingFolder.speakers(dir), options: .atomic)
    }

    /// After a transcription: the voices' labels go into speakers.json (a new file, or added to the names given before).
    /// A broken file isn't touched: it was edited by hand, refresh tells about it.
    static func addLabels(_ dir: URL, _ labels: [String]) {
        var names: Names
        switch read(dir) {
        case .none: names = Names()
        case .names(let n): names = n
        case .broken: return
        }
        let missing = labels.filter { names.speakers[$0] == nil }
        guard !missing.isEmpty else { return }
        for l in missing { names.speakers[l] = l }
        do {
            try write(dir, names)
        } catch {
            tlog("couldn't write \(file) in \(dir.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// The [speakers] table of the old speakers.toml: "label" = "name" lines (bare keys and 'literal' strings too).
    /// nil — something else is in it, so it can't be trusted.
    static func parseToml(_ text: String) -> [String: String]? {
        var out: [String: String] = [:]
        var table: String?
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var line = Substring(raw).drop { $0 == " " || $0 == "\t" }
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                guard let close = line.firstIndex(of: "]") else { return nil }
                table = line[line.index(after: line.startIndex)..<close].trimmingCharacters(in: .whitespaces)
                guard rest(line[line.index(after: close)...]) else { return nil }
                continue
            }
            guard let key = tomlString(&line, bare: true) else { return nil }
            line = line.drop { $0 == " " || $0 == "\t" }
            guard line.first == "=" else { return nil }
            line = line.dropFirst().drop { $0 == " " || $0 == "\t" }
            guard let value = tomlString(&line, bare: false), rest(line) else { return nil }
            if table == "speakers" { out[key] = value }
        }
        return out
    }

    /// Only spaces or a comment after a value.
    private static func rest(_ s: Substring) -> Bool {
        let t = s.drop { $0 == " " || $0 == "\t" }
        return t.isEmpty || t.hasPrefix("#")
    }

    /// A string at the start of s ("basic" with escapes, 'literal', or — for a key — bare); s moves past it.
    private static func tomlString(_ s: inout Substring, bare: Bool) -> String? {
        guard let q = s.first else { return nil }
        if q == "'" {
            let body = s.dropFirst()
            guard let end = body.firstIndex(of: "'") else { return nil }
            s = body[body.index(after: end)...]
            return String(body[..<end])
        }
        if q == "\"" {
            var out = ""
            var i = s.index(after: s.startIndex)
            while i < s.endIndex {
                let c = s[i]
                if c == "\"" {
                    s = s[s.index(after: i)...]
                    return out
                }
                if c == "\\" {
                    i = s.index(after: i)
                    guard i < s.endIndex else { return nil }
                    switch s[i] {
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "u", "U":
                        let n = s[i] == "u" ? 4 : 8
                        guard let end = s.index(i, offsetBy: n + 1, limitedBy: s.endIndex),
                              let v = UInt32(s[s.index(after: i)..<end], radix: 16), let u = Unicode.Scalar(v) else { return nil }
                        out.unicodeScalars.append(u)
                        i = s.index(before: end)
                    default: return nil
                    }
                } else {
                    out.append(c)
                }
                i = s.index(after: i)
            }
            return nil
        }
        guard bare else { return nil }
        let key = s.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        guard !key.isEmpty else { return nil }
        s = s[key.endIndex...]
        return String(key)
    }

    // ---------- updating transcripts ----------

    /// Names from the Names window for one transcript: a whole new speakers.json (an empty name — the label as is),
    /// then the transcript. Only a transcript the app knows, unless anyFolder (a test copy from the command line).
    static func set(_ dir: URL, _ names: Names, settings: TranscriptSettings, notify: (String, String) -> Void,
                    anyFolder: Bool = false) {
        guard anyFolder || Meetings.dirs().contains(where: { $0.standardizedFileURL.path == dir.standardizedFileURL.path }) else {
            tlog("speaker names: not a transcript folder: \(dir.path)")
            return
        }
        var clean = Names()
        for (label, name) in names.speakers {
            let n = name.trimmingCharacters(in: .whitespaces)
            clean.speakers[label] = n.isEmpty ? label : n
        }
        // an empty name — the track's own name again
        for (track, name) in names.tracks {
            let n = name.trimmingCharacters(in: .whitespaces)
            if !n.isEmpty { clean.tracks[track] = n }
        }
        do {
            try write(dir, clean)
            tlog("speaker names from the Names window: \(dir.lastPathComponent)")
            try refresh(dir, settings: settings, notify: notify)
        } catch {
            tlog("couldn't update the names in \(dir.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Update the names in these transcripts (nil — all of them). A broken one doesn't stop the rest.
    static func refreshAll(_ dirs: [URL]?, settings: TranscriptSettings, notify: (String, String) -> Void) {
        if dirs == nil { tlog("updating the names in all transcripts") }
        for dir in dirs ?? Meetings.dirs() where MeetingFolder.isTranscript(dir) {
            do {
                try refresh(dir, settings: settings, notify: notify)
            } catch {
                tlog("couldn't update the names in \(dir.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// transcript.md with the names as they are now — without transcribing again. raw/*.json and meta.json get the names too.
    static func refresh(_ dir: URL, settings: TranscriptSettings, notify: (String, String) -> Void) throws {
        MeetingFolder.tidy(dir)   // a folder from the command line may be of the old layout
        let metaURL = MeetingFolder.meta(dir)
        var meta = readJSON(metaURL)
        guard let src = meta["source"] as? [String: Any], var rec = meta["recording"] as? [String: Any],
              var parts = rec["participants"] as? [[String: Any]] else {
            throw TranscriberError("\(metaURL.path) can't be read")
        }
        let defaults = ["mic": settings.me, "system": settings.other]
        var speakerNames: [String: String]?
        var trackNames: [String: String]?   // nil — the file is broken: renamed tracks keep the names they have
        var brokenFile = file
        switch read(dir) {
        case .none: speakerNames = [:]; trackNames = [:]
        case .names(let n): speakerNames = n.speakers; trackNames = n.tracks
        case .broken(let f): speakerNames = nil; brokenFile = f
        }
        var told = false
        func tellBroken() {
            guard !told else { return }
            told = true
            let example = brokenFile == oldFile ? "\"Speaker 1\" = \"Name\"" : "\"Speaker 1\": \"Name\""
            notify(String(localized: "Problem in \(brokenFile)"),
                   String(localized: "Recording \(dir.lastPathComponent): couldn't read the file, so the old speaker names stay. Check the quotes: \(example)"))
        }
        var tracks: [TranscriptTrack] = []
        for i in parts.indices {
            guard let rawFile = parts[i]["raw_file"] as? String else { throw TranscriberError("meta.json has a track without raw_file") }
            let rawURL = MeetingFolder.raw(dir, rawFile)
            guard let data = try? Data(contentsOf: rawURL),
                  let before = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw TranscriberError("\(rawURL.path) can't be read")
            }
            var raw = before
            let id = raw["username"] as? String ?? ""
            // the track's own name: one from Settings → Inputs doesn't change; "Your name" and "Other people" come from
            // Settings. A track renamed for this recording keeps its own name in name_default.
            let old = raw["name_default"] as? String ?? raw["name"] as? String ?? ""
            let own = raw["name_fixed"] as? Bool == true ? old : defaults[id] ?? (old.isEmpty ? id : old)
            let renamed: String?
            if let trackNames {
                renamed = trackNames[id]
            } else {
                // the file is broken: a renamed track keeps the name it has
                renamed = raw["name_default"] != nil ? raw["name"] as? String : nil
                if renamed != nil { tellBroken() }
            }
            let trackName = renamed ?? own
            raw["name"] = trackName
            raw["name_default"] = renamed == nil ? nil : own
            parts[i]["name"] = trackName
            var speakerList: [String]?
            if var speakers = raw["speakers"] as? [[String: Any]], !speakers.isEmpty {
                if speakerNames == nil {
                    // the file is broken — the names written before stay until it's fixed
                    speakerNames = Dictionary(speakers.compactMap { sp in
                        (sp["label"] as? String).map { ($0, sp["name"] as? String ?? $0) }
                    }, uniquingKeysWith: { a, _ in a })
                    tellBroken()
                }
                var byID: [Int: String] = [:]
                for k in speakers.indices {
                    let label = speakers[k]["label"] as? String ?? ""
                    let name = speakerNames?[label] ?? label
                    speakers[k]["name"] = name
                    if let n = speakers[k]["id"] as? NSNumber { byID[n.intValue] = name }
                }
                raw["speakers"] = speakers
                parts[i]["speakers"] = speakers
                speakerList = speakers.map { $0["name"] as? String ?? "" }
                if var segs = raw["segments"] as? [[String: Any]] {
                    for k in segs.indices {
                        guard let sp = segs[k]["speaker"] else { continue }
                        segs[k]["name"] = (sp as? NSNumber).flatMap { byID[$0.intValue] } ?? trackName
                    }
                    raw["segments"] = segs
                }
            }
            if !NSDictionary(dictionary: raw).isEqual(to: before) {
                try jsonData(tidyNumbers(raw)).write(to: rawURL, options: .atomic)
            }
            let segs = raw["segments"] as? [[String: Any]] ?? []
            tracks.append(TranscriptTrack(
                role: raw["role"] as? String ?? "", name: trackName, transcribe: raw["transcribe"] as? Bool != false,
                speakerNames: speakerList,
                lines: segs.map { s in
                    Line(start: (s["start"] as? NSNumber)?.doubleValue ?? 0, end: (s["end"] as? NSNumber)?.doubleValue ?? 0,
                         name: s["name"] as? String ?? trackName, text: s["text"] as? String ?? "")
                }))
        }
        // the time zone the recording was made in: start_local carries it ("2026-10-29T09:30:12+01:00")
        guard let startLocal = rec["start_local"] as? String, let started = parseISO(startLocal) else {
            throw TranscriberError("meta.json has no start time")
        }
        let zone = isoOffset(startLocal).flatMap { TimeZone(secondsFromGMT: $0) } ?? .current
        let duration = (rec["duration_s"] as? NSNumber)?.doubleValue ?? 0
        let md = renderMarkdown(started: started, zone: zone, duration: duration, tracks: tracks,
                                apps: systemApps(src["system_source"]), lines: buildLines(tracks))
        protectManualEdits(dir, newMarkdown: md, notify: notify)
        let mdURL = MeetingFolder.transcript(dir)
        if (try? Data(contentsOf: mdURL)) != Data(md.utf8) { try Data(md.utf8).write(to: mdURL, options: .atomic) }
        rec["participants"] = parts
        meta["recording"] = rec
        meta["transcript_sha256"] = sha256(md)
        if !NSDictionary(dictionary: meta).isEqual(to: readJSON(metaURL)) {
            try jsonData(tidyNumbers(meta)).write(to: metaURL, options: .atomic)
        }
        tlog("names updated: \(dir.lastPathComponent)")
    }
}

/// "+01:00" at the end of an ISO date → seconds from GMT ("Z" — 0).
func isoOffset(_ s: String) -> Int? {
    if s.hasSuffix("Z") { return 0 }
    guard s.count >= 6 else { return nil }
    let tail = s.suffix(6)
    guard let sign = tail.first, sign == "+" || sign == "-", tail.dropFirst(3).first == ":",
          let h = Int(tail.dropFirst().prefix(2)), let m = Int(tail.suffix(2)) else { return nil }
    return (sign == "-" ? -1 : 1) * (h * 3600 + m * 60)
}

/// Numbers read from JSON are written back as they were (28.993, not 28.992999999999999).
func tidyNumbers(_ v: Any) -> Any {
    switch v {
    case let d as [String: Any]: return d.mapValues(tidyNumbers)
    case let a as [Any]: return a.map(tidyNumbers)
    case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID() && CFNumberIsFloatType(n):
        return NSDecimalNumber(string: "\(n.doubleValue)", locale: Locale(identifier: "en_US_POSIX"))
    default: return v
    }
}
