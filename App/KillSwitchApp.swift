import SwiftUI

@main
struct KillSwitchApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var control: KillSwitchControl
    @State private var client: VPNClient
    @State private var leakTester = LeakTester()
    @State private var autoConnector: AutoConnector
    @State private var updater = Updater()

    init() {
        let control = KillSwitchControl()
        _control = State(initialValue: control)
        _client = State(initialValue: VPNClient(control: control))
        _autoConnector = State(initialValue: AutoConnector(control: control))
        Notifier.shared.control = control
        Notifier.shared.client = _client.wrappedValue
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

        // spec §5.1, Р3: a click on the icon opens the main screen as a popover
        MenuBarExtra {
            HomeView(style: .popover)
                .environment(control)
                .environment(client)
                .environment(updater)
        } label: {
            MenuBarLabel(status: control.status(client))
        }
        .menuBarExtraStyle(.window)
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

/// The menu bar icon of the summary status. A change of the status is announced to VoiceOver,
/// at most every 5 s (spec §9.2). On a Mac without the service it opens «Начало работы» once.
private struct MenuBarLabel: View {
    let status: Status
    @State private var throttle = Throttle(interval: 5)
    @State private var offeredSetup = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(status.icon)
            .onAppear { Router.shared.openWindow = { openWindow(id: MainWindow.id) } }
            .accessibilityLabel(status.accessibilityLabel)
            .help(status.accessibilityLabel)
            .onChange(of: status.title) { _, title in
                guard throttle.allow("status", now: Date()) else { return }
                AccessibilityNotification.Announcement("KillSwitch: " + title).post()
            }
            .onChange(of: status == .notInstalled, initial: true) { _, notInstalled in
                guard notInstalled, !offeredSetup else { return }
                offeredSetup = true
                Router.shared.openWindow = { openWindow(id: MainWindow.id) }   // may run before onAppear
                Router.shared.go(.onboarding)
            }
    }
}
