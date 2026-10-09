import SwiftUI

struct MenuView: View {
    @Environment(KillSwitchControl.self) private var control
    @AppStorage("pauseShort") private var pauseShort = 5
    @AppStorage("pauseLong") private var pauseLong = 30
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(control.state.title)
        Text(control.vpnUp ? "VPN подключён" : "VPN не подключён")

        if control.coreInstalled && control.coreConfigured {
            Button(control.coreRunning ? "Выключить своё ядро" : "Включить своё ядро") {
                control.coreRunning ? control.coreOff() : control.coreOn()
            }
        }

        Divider()

        switch control.state {
        case .on:
            Button("Выключить") { control.turnOff() }
            Button("Пауза \(pauseShort) мин") { control.pause(minutes: pauseShort) }
            Button("Пауза \(pauseLong) мин") { control.pause(minutes: pauseLong) }
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
        SettingsLink { Text("Настройки…") }
        Button("Выйти") { NSApp.terminate(nil) }
    }
}
