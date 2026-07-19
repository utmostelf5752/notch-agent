import AppKit

// The product rename changes the bundle identifier, so macOS gives Eave a new
// defaults domain. Copy the settings that belong to the app once, before the
// AppState singleton reads them.
private func migrateNotchAgentDefaultsIfNeeded() {
    let defaults = UserDefaults.standard
    let migrationKey = "eave.didMigrateNotchAgentDefaults"
    guard !defaults.bool(forKey: migrationKey),
          let legacy = defaults.persistentDomain(forName: "com.jagruth.notchagent")
    else { return }

    let keys: [(legacy: String, current: String)] = [
        ("notchStyle", "notchStyle"),
        ("stealthMode", "stealthMode"),
        ("panelStyle", "panelStyle"),
        ("glassPanel", "glassPanel"),
        ("panelWidth", "panelWidth"),
        ("panelHeight", "panelHeight"),
        ("toggleShortcutKeyCode", "toggleShortcutKeyCode"),
        ("toggleShortcutModifiers", "toggleShortcutModifiers"),
        ("toggleShortcutKeyLabel", "toggleShortcutKeyLabel"),
        ("NotchAgent.cursorContextChoice", "Eave.cursorContextChoice"),
        ("chatgptAccountState", "chatgptAccountState"),
        ("chatgptAccountEmail", "chatgptAccountEmail"),
    ]
    for key in keys where defaults.object(forKey: key.current) == nil {
        if let value = legacy[key.legacy] {
            defaults.set(value, forKey: key.current)
        }
    }
    defaults.set(true, forKey: migrationKey)
}

migrateNotchAgentDefaultsIfNeeded()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Accessory: no dock icon, no menu bar entry. Quit with Cmd+Q while the panel
// is open, or `pkill Eave`.
app.setActivationPolicy(.accessory)
app.run()
