import SwiftUI

@main
struct KillSwitchApp: App {
    @State private var control: KillSwitchControl
    @State private var client: VPNClient

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
