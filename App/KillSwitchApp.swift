import SwiftUI

@main
struct KillSwitchApp: App {
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
    }

    var body: some Scene {
        Window("KillSwitch", id: "main") {
            HomeView(style: .window)
                .environment(control)
                .environment(client)
                .environment(updater)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) { CheckForUpdatesButton(updater: updater) }
            CommandMenu("VPN") {
                Button("Скопировать диагностику") { DiagnosticsCopy.copy(control: control, client: client) }
            }
        }

        Window("Начало работы", id: OnboardingView.windowID) {
            OnboardingView()
                .environment(control)
                .environment(client)
                .environment(leakTester)
                .environment(autoConnector)
        }
        .windowResizability(.contentSize)

        Window("Проверка утечек", id: LeakTestView.windowID) {
            LeakTestView()
                .environment(control)
                .environment(leakTester)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environment(control)
                .environment(client)
                .environment(autoConnector)
        }

        MenuBarExtra {
            MenuView()
                .environment(control)
                .environment(client)
                .environment(updater)
        } label: {
            MenuBarLabel(status: control.status(client))
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
            .accessibilityLabel(status.accessibilityLabel)
            .help(status.accessibilityLabel)
            .onChange(of: status.title) { _, title in
                guard throttle.allow("status", now: Date()) else { return }
                AccessibilityNotification.Announcement("KillSwitch: " + title).post()
            }
            .onChange(of: status == .notInstalled, initial: true) { _, notInstalled in
                guard notInstalled, !offeredSetup else { return }
                offeredSetup = true
                openWindow(id: OnboardingView.windowID)
                NSApp.activate()
            }
    }
}
