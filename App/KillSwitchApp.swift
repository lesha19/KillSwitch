import SwiftUI

@main
struct KillSwitchApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var control: KillSwitchControl
    @State private var client: VPNClient
    @State private var leakTester = LeakTester()
    @State private var autoConnector: AutoConnector
    @State private var updater: Updater

    init() {
        let control = KillSwitchControl()
        let client = VPNClient(control: control)
        let updater = Updater()
        _control = State(initialValue: control)
        _client = State(initialValue: client)
        _updater = State(initialValue: updater)
        _autoConnector = State(initialValue: AutoConnector(control: control))
        Notifier.shared.control = control
        Notifier.shared.client = client
        ShortcutTarget.control = control
        ShortcutTarget.client = client
        // spec §5.1, Р3: the menu bar icon; a click opens the main screen as a popover, a right
        // click a compact menu (ADR 0010)
        DispatchQueue.main.async { StatusItem.install(control: control, client: client, updater: updater) }
    }

    var body: some Scene {
        // The one window (ADR 0008): a `Window`, not a `WindowGroup`, so there is never a second
        // one; macOS restores its size and place. No `Settings` scene: ⌘, opens «Настройки» here.
        Window("KillSwitch", id: MainWindow.id) {
            MainWindow()
                .environment(control)
                .environment(client)
                .environment(leakTester)
                .environment(autoConnector)
                .environment(updater)
        }
        .defaultSize(width: 860, height: 640)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) { CheckForUpdatesButton(updater: updater) }
            CommandGroup(replacing: .appSettings) {
                Button("Настройки…") { Router.shared.go(.settings) }.keyboardShortcut(",")
            }
            CommandMenu("VPN") {
                Button("Главная") { Router.shared.go(.section(.home)) }.keyboardShortcut("0")
                Button("Серверы") { Router.shared.go(.servers) }.keyboardShortcut("l")
                Button("Проверка утечек") { Router.shared.go(.leakTest) }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Журнал защиты") { Router.shared.go(.section(.log)) }
                Divider()
                Button("Скопировать диагностику") { DiagnosticsCopy.copy(control: control, client: client) }
            }
            CommandGroup(replacing: .help) {
                Button("Как это работает") { Router.shared.go(.help) }
            }
        }
    }
}

/// `killswitch://…` links (the widget opens `killswitch://home`) land in a section of the window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls {
                if let route = Navigation.route(url: url) { Router.shared.go(route) }
            }
        }
    }
}
