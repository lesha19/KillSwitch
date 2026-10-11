import SwiftUI

/// «Запускать без окна»: the app starts in the menu bar only; the window opens from the menu bar
/// icon, the Dock or ⌘0. Read once at launch (KillSwitchApp). «Начало работы» still opens the
/// window on a Mac without the service (StatusItem).
enum StartMinimised {
    static let key = "startMinimised"

    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }
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
