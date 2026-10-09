import SwiftUI

struct MenuView: View {
    @Environment(KillSwitchControl.self) private var control
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(control.state.title)
        Text(control.vpnUp ? "VPN подключён" : "VPN не подключён")

        Divider()

        switch control.state {
        case .on:
            Button("Выключить") { control.turnOff() }
            Button("Пауза 5 минут") { control.pause(minutes: 5) }
            Button("Пауза 30 минут") { control.pause(minutes: 30) }
        case .off, .paused:
            Button("Включить") { control.turnOn() }
        case .notInstalled, .unknown:
            EmptyView()
        }

        Divider()

        Button("Открыть окно") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("Выйти") { NSApp.terminate(nil) }
    }
}
