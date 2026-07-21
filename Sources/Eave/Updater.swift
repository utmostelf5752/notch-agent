import AppKit
import Combine
import Sparkle

// Sparkle auto-update wiring. Checks are scheduled (SUEnableAutomaticChecks
// in Info.plist suppresses Sparkle's first-launch permission dialog) and
// updates download in the background; the user only sees the final
// "ready to install, relaunch?" prompt. The appcast comes from the rolling
// GitHub release (SUFeedURL), EdDSA-verified against SUPublicEDKey.
//
// Also feeds the Settings > About tab: `check()` probes the appcast without
// downloading and publishes the outcome as `status`; `updateNow()` runs the
// full interactive Sparkle flow (download, install, relaunch).
final class Updater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = Updater()

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case error(String)
    }

    @Published private(set) var status: Status = .idle

    private var controller: SPUStandardUpdaterController!

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.automaticallyDownloadsUpdates = true
    }

    var currentVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return short ?? "dev"
    }

    var buildNumber: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    // Probe-only check for the About tab: hits the appcast, reports through
    // `status`, never downloads or shows Sparkle UI.
    func check() {
        guard status != .checking else { return }
        status = .checking
        controller.updater.checkForUpdateInformation()
    }

    // Full interactive flow. An LSUIElement app is never active, and an
    // inactive app's update window can appear behind whatever the user is
    // working in — activate first so the dialog is seen.
    func updateNow() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // User-initiated check from the status-item menu — same interactive flow.
    func checkForUpdates() {
        updateNow()
    }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        DispatchQueue.main.async { self.status = .available(item.displayVersionString) }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        DispatchQueue.main.async { self.status = .upToDate }
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
