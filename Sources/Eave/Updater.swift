import AppKit
import Sparkle

// Sparkle auto-update wiring. Checks are scheduled (SUEnableAutomaticChecks
// in Info.plist suppresses Sparkle's first-launch permission dialog) and
// updates download in the background; the user only sees the final
// "ready to install, relaunch?" prompt. The appcast comes from the rolling
// GitHub release (SUFeedURL), EdDSA-verified against SUPublicEDKey.
final class Updater {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.automaticallyDownloadsUpdates = true
    }

    var currentVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return short ?? "dev"
    }

    // User-initiated check from the status-item menu. An LSUIElement app is
    // never active, and an inactive app's update window can appear behind
    // whatever the user is working in — activate first so the dialog is seen.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}
