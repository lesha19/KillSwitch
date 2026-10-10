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
            ContentView()
                .environment(control)
                .environment(client)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) { CheckForUpdatesButton(updater: updater) }
            CommandMenu("VPN") {
                LeakTestView.OpenButton()
                Button("Обновить подписку") { Task { await client.update(interactive: true) } }
                    .keyboardShortcut("r")
                    .disabled(!client.hasURL || client.updating)
                Button("Проверить пинг") { Task { await control.testAllDelays() } }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(!control.coreRunning || control.proxies == nil || !control.testing.isEmpty)
                Divider()
                Button("Скопировать диагностику") { DiagnosticsCopy.copy(control: control, client: client) }
            }
        }

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
            MenuBarIcon(symbol: control.connection == .connected ? Connection.connected.symbol : control.state.symbol,
                        paused: control.connection != .connected && control.isPaused)
        }
    }
}

/// Template shields from Assets.xcassets for the three main states; other symbols stay SF Symbols.
private struct MenuBarIcon: View {
    let symbol: String
    let paused: Bool

    var body: some View {
        switch symbol {
        case "lock.shield.fill": Image("MenuBarConnected")
        case "shield.slash": Image(paused ? "MenuBarPaused" : "MenuBarDisconnected")
        default: Image(systemName: symbol)
        }
    }
}

private extension KillSwitchControl {
    var isPaused: Bool {
        if case .paused = state { true } else { false }
    }
}
