import AppKit
import Combine
import Sparkle

// Sparkle auto-update wiring. Checks are scheduled (SUEnableAutomaticChecks
// in Info.plist suppresses Sparkle's first-launch permission dialog) and
// updates download in the background and install themselves when the app
// quits. The appcast comes from the rolling GitHub release (SUFeedURL),
// EdDSA-verified against SUPublicEDKey.
//
// There is no Sparkle UI at all: instead of SPUStandardUpdaterController and
// its "Install / Remind Me Later / Skip" dialog, a silent SPUUserDriver
// answers every prompt itself and mirrors progress into `status`, which the
// Settings > About tab renders. "Update Now" therefore installs directly —
// the choice dialog would be dead weight when background updates already
// apply on relaunch and the button says exactly what it does.
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = Updater()

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case downloading(Double?) // fraction complete, nil before size is known
        case installing
        case error(String)
    }

    @Published private(set) var status: Status = .idle

    private var updater: SPUUpdater!
    private var driver: SilentUpdateDriver!

    private override init() {
        super.init()
        driver = SilentUpdateDriver(owner: self)
        updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: driver,
            delegate: self
        )
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = true
        // Default is daily; align with the changelog's 6-hour refresh so the
        // About tab doesn't learn about a release hours before Sparkle offers it.
        updater.updateCheckInterval = 6 * 3600
        do {
            try updater.start()
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    var currentVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return short ?? "dev"
    }

    var buildNumber: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    // Probe-only check for the About tab: hits the appcast, reports through
    // `status`, never downloads.
    func check() {
        guard status != .checking, !updater.sessionInProgress else { return }
        status = .checking
        updater.checkForUpdateInformation()
    }

    // Called when About appears so the tab reflects reality without the user
    // having to click Check for Updates. Skips states that are already
    // in-flight or already resolved to an available update.
    func probeIfStale() {
        switch status {
        case .idle, .upToDate, .error: check()
        case .checking, .available, .downloading, .installing: break
        }
    }

    // Direct install: run a user-initiated update session; the silent driver
    // answers "install" at every step, so this downloads (with progress in
    // `status`), installs, and relaunches without any dialog. If a background
    // check already staged the update, Sparkle skips straight to install.
    func updateNow() {
        updater.checkForUpdates()
    }

    // User-initiated check from the status-item menu — same direct flow.
    func checkForUpdates() {
        updateNow()
    }

    fileprivate func setStatus(_ new: Status) {
        DispatchQueue.main.async { self.status = new }
    }

    // MARK: - SPUUpdaterDelegate (probe-only path)

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        setStatus(.available(item.displayVersionString))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        DispatchQueue.main.async {
            guard self.status == .checking else { return }
            self.status = .upToDate
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        DispatchQueue.main.async {
            // didFindValidUpdate / updaterDidNotFindUpdate already resolved
            // the probe; anything still "checking" here failed outright.
            guard self.status == .checking else { return }
            if let error {
                self.status = .error(error.localizedDescription)
            } else {
                self.status = .upToDate
            }
        }
    }
}

// Answers Sparkle's prompts without showing them. Policy:
//  - user-initiated sessions (the Update Now button): install at every
//    decision point, so the update downloads, installs, and relaunches in one
//    motion with progress mirrored into Updater.status;
//  - background sessions: dismiss the prompts, which keeps Sparkle's
//    automatic behavior — the downloaded update stays staged and installs
//    itself when the app next quits or relaunches.
private final class SilentUpdateDriver: NSObject, SPUUserDriver {
    private unowned let owner: Updater

    private var userInitiated = false
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0

    init(owner: Updater) {
        self.owner = owner
    }

    // SUEnableAutomaticChecks in Info.plist should keep this from ever being
    // asked; answer the way the app is configured in case it is.
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        userInitiated = true
        owner.setStatus(.checking)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        owner.setStatus(.available(appcastItem.displayVersionString))
        if appcastItem.isInformationOnlyUpdate {
            reply(.dismiss)
            return
        }
        if state.userInitiated {
            userInitiated = true
            reply(.install)
        } else {
            // Background find (or an already-downloaded automatic update
            // asking when to install): leave it staged. Sparkle installs it
            // on quit, which is the silent-on-relaunch behavior users see.
            reply(.dismiss)
        }
    }

    // Release notes live in the in-app changelog, not the appcast.
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        owner.setStatus(.upToDate)
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        owner.setStatus(.error(error.localizedDescription))
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedLength = 0
        receivedLength = 0
        owner.setStatus(.downloading(nil))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
        receivedLength = 0
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        guard expectedLength > 0 else { return }
        let fraction = min(1, Double(receivedLength) / Double(expectedLength))
        owner.setStatus(.downloading(fraction))
    }

    func showDownloadDidStartExtractingUpdate() {
        owner.setStatus(.installing)
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Same split as showUpdateFound: the button relaunches now, the
        // background flow waits for the app to quit on its own.
        reply(userInitiated ? .install : .dismiss)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        owner.setStatus(.installing)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        userInitiated = false
        // A background session ends here after we dismissed its prompts; keep
        // ".available" (the About tab should still offer the update) but clear
        // transient progress states a failed user session may have left.
        DispatchQueue.main.async {
            switch self.owner.status {
            case .checking, .downloading, .installing:
                self.owner.setStatus(.idle)
            case .idle, .upToDate, .available, .error:
                break
            }
        }
    }
}
