// Automatic updates with Sparkle 2 — in the release only. `build.sh release` builds with the package trait
// Updates; the development build has neither this code nor Sparkle, and never looks for updates.
//
// The feed (SUFeedURL, an appcast.xml on GitHub Releases) and the public EdDSA key (SUPublicEDKey) are in
// Info.plist, written by build.sh. Sparkle installs an update only if its DMG is signed with the matching
// private key, which lives in the keychain of whoever publishes releases (menubar/appcast.sh signs with it).
//
// Koe has no Dock icon, so a scheduled check that finds an update while the person is busy doesn't pop up a
// window: the menu gets an "Update to Koe X…" item instead (Sparkle's "gentle reminders").
import AppKit
#if Updates
import Sparkle
#endif

@MainActor
final class Updates: NSObject, ObservableObject {
    static let shared = Updates()

    /// Whether this build can update itself at all (false in the development build).
    static var supported: Bool {
        #if Updates
        true
        #else
        false
        #endif
    }

    /// A newer version that a scheduled check found and didn't show yet ("0.9.1"); the menu offers it
    /// (the menu is built anew each time it opens).
    @Published private(set) var pending: String?

    #if Updates
    private var controller: SPUStandardUpdaterController?
    #endif

    func start() {
        #if Updates
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        #endif
    }

    /// Check for Updates… in the menu (and Update to Koe X…): shows what was found, or "You're up to date".
    func checkNow() {
        #if Updates
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
        #endif
    }

    /// Settings → Other → Check for updates automatically. Sparkle keeps it in the app's defaults (SUEnableAutomaticChecks).
    var automaticallyChecks: Bool {
        get {
            #if Updates
            controller?.updater.automaticallyChecksForUpdates ?? false
            #else
            false
            #endif
        }
        set {
            #if Updates
            controller?.updater.automaticallyChecksForUpdates = newValue
            objectWillChange.send()
            #endif
        }
    }

    fileprivate func setPending(_ version: String?) { pending = version }
}

#if Updates
extension Updates: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle shows a found update itself only when it's the right moment (right after launch, or the person asked);
    /// otherwise Koe shows it in the menu.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            if handleShowingUpdate {
                NSApp.activate(ignoringOtherApps: true)
            } else {
                setPending(version)
            }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { setPending(nil) }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { setPending(nil) }
    }
}

/// --update-test FEED_URL [--expect-rejected]: check, download and install an update from FEED_URL with no windows,
/// answering "Install and Relaunch" to everything, as a person clicking through Sparkle's windows would. The app is
/// replaced and started again (as after a real update). With --expect-rejected the update must be refused (a bad
/// signature): the exit code is 0 only if Sparkle reported an error and installed nothing. For testing the release.
@MainActor
final class UpdateTest: NSObject, SPUUpdaterDelegate, SPUUserDriver {
    let feed: String
    let expectRejected: Bool
    var updater: SPUUpdater!

    init(feed: String, expectRejected: Bool) {
        self.feed = feed
        self.expectRejected = expectRejected
    }

    func run() {
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        do {
            try updater.start()
        } catch {
            finish("couldn't start the updater: \(error.localizedDescription)", ok: false)
        }
        print("installed: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?")) at \(Bundle.main.bundlePath)")
        print("feed: \(feed)")
        updater.checkForUpdates()
    }

    func finish(_ line: String, ok: Bool) {
        print(line)
        exit(ok ? 0 : 1)
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? { MainActor.assumeIsolated { feed } }

    nonisolated func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    nonisolated func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { print("checking…") }
    nonisolated func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        print("found: \(appcastItem.displayVersionString) (\(appcastItem.versionString)) at \(appcastItem.fileURL?.absoluteString ?? "?")")
        reply(.install)
    }
    nonisolated func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    nonisolated func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    nonisolated func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        MainActor.assumeIsolated { finish("no update found: \(error.localizedDescription)", ok: false) }
    }
    nonisolated func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let ns = error as NSError
        let reason = [ns.localizedDescription, (ns.userInfo[NSUnderlyingErrorKey] as? NSError)?.localizedDescription]
            .compactMap { $0 }.joined(separator: " — ")
        MainActor.assumeIsolated {
            finish(expectRejected ? "rejected, as expected: \(reason)" : "error: \(reason)", ok: expectRejected)
        }
    }
    nonisolated func showDownloadInitiated(cancellation: @escaping () -> Void) { print("downloading…") }
    nonisolated func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    nonisolated func showDownloadDidReceiveData(ofLength length: UInt64) {}
    nonisolated func showDownloadDidStartExtractingUpdate() { print("downloaded, checking and unpacking…") }
    nonisolated func showExtractionReceivedProgress(_ progress: Double) {}
    nonisolated func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        MainActor.assumeIsolated {
            if expectRejected { finish("the update was accepted, but it should have been rejected", ok: false) }
        }
        print("ready: install and relaunch")
        reply(.install)
    }
    nonisolated func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        print("installing…")
    }
    nonisolated func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        print("installed and relaunched: \(relaunched)")
        acknowledgement()
    }
    nonisolated func dismissUpdateInstallation() {}
}
#endif
