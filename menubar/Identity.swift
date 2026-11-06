// Who this app is and where it keeps its things: all names and paths are here, and only here.
//
// Everything comes from the bundle ID and the name in Info.plist, which build.sh sets. The development
// build (com.tsarionov.koe.dev) and the release (com.tsarionov.koe) are both named "Koe" and differ only in
// the settings in build.sh — the code is the same. Data and logs live in folders named by bundle ID,
// so the app never touches other folders (such as those of another Koe build).
import Foundation

let home = FileManager.default.homeDirectoryForCurrentUser

enum Identity {
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.tsarionov.koe.dev"
    static let isDev = bundleID.hasSuffix(".dev")
    static let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Koe"

    static let supportDir = home.appendingPathComponent("Library/Application Support/\(bundleID)")
    static let logsDir = home.appendingPathComponent("Library/Logs/\(bundleID)")
    static let stateDir = supportDir.appendingPathComponent("state")
    static let inboxDir = supportDir.appendingPathComponent("inbox")
    static let settingsFile = supportDir.appendingPathComponent("settings.json")
    static let pipelineLog = logsDir.appendingPathComponent("pipeline.log")
    static let pipelineOutput = logsDir.appendingPathComponent("pipeline.out.log")
    static let recorderLog = logsDir.appendingPathComponent("recorder.log")

    /// The transcripts folder until another one is chosen in Settings: ~/Documents/Koe Dev for the development
    /// build (kept apart from a release on the same Mac), ~/Documents/Koe for the release.
    static let defaultMeetingsFolder = home.appendingPathComponent(isDev ? "Documents/Koe Dev" : "Documents/\(appName)").path

    /// The "Looks like a call started" suggestion: off by default in the development build,
    /// otherwise next to another Koe both would send the same notification.
    static let suggestCallsByDefault = !isDev
}
