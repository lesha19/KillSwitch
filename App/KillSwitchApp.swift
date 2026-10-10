import SwiftUI

@main
struct KillSwitchApp: App {
    @State private var control: KillSwitchControl
    @State private var client: VPNClient
    @State private var leakTester = LeakTester()

    init() {
        let control = KillSwitchControl()
        _control = State(initialValue: control)
        _client = State(initialValue: VPNClient(control: control))
    }

    var body: some Scene {
        Window("KillSwitch", id: "main") {
            ContentView()
                .environment(control)
                .environment(client)
        }
        .windowResizability(.contentSize)
        .commands {
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
        }

        MenuBarExtra {
            MenuView()
                .environment(control)
                .environment(client)
        } label: {
            Image(systemName: control.connection == .connected ? Connection.connected.symbol : control.state.symbol)
        }
    }
}
