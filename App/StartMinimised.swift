import SwiftUI

/// «Запускать без окна»: the app starts in the menu bar only, without a Dock icon (#51); the window
/// opens from the menu bar icon. Read once at launch (KillSwitchApp, AppDelegate). «Начало работы»
/// still opens the window on a Mac without the service (StatusItem).
enum StartMinimised {
    static let key = "startMinimised"

    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    /// This launch starts without the window: the setting, or once after an update relaunch that
    /// found the window closed (#51, UpdateRelaunch). The mark is dropped at the first read.
    static let atLaunch: Bool = {
        let defaults = UserDefaults.standard
        let marked = defaults.object(forKey: UpdateRelaunch.windowlessKey) as? TimeInterval
        defaults.removeObject(forKey: UpdateRelaunch.windowlessKey)
        return isOn || UpdateRelaunch.startsWithoutWindow(markedAt: marked, now: Date().timeIntervalSince1970)
    }()

    /// Right before the app quits to be relaunched by an update (Updater).
    @MainActor static func markRelaunch() {
        guard NSApp.activationPolicy() == .accessory else { return }   // the window is closed
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: UpdateRelaunch.windowlessKey)
    }
}

/// The row in Настройки → Общие → Запуск.
struct StartMinimisedToggle: View {
    @AppStorage(StartMinimised.key) private var on = false

    var body: some View {
        Toggle(isOn: $on) {
            Text("Запускать без окна")
            Text("Только значок в строке меню; окно открывается из него.")
        }
    }
}
