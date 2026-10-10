import SwiftUI

struct MenuView: View {
    @Environment(KillSwitchControl.self) private var control
    @Environment(VPNClient.self) private var client
    @Environment(Updater.self) private var updater
    @AppStorage("pauseShort") private var pauseShort = 5
    @AppStorage("pauseLong") private var pauseLong = 30
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let connection = control.connection
        Text(connection.title)
        if connection == .connected || connection == .connecting, let server = control.currentServer {
            let name = ServerName(server)
            let delay = control.delay(of: server).map { " · \($0) мс" } ?? ""
            Text("\(name.flag ?? "🌐") \(name.title.isEmpty ? server : name.title)\(delay)")
        }
        if connection == .connected || connection == .connecting, let entry = control.multihopEntry {
            Text(Multihop.chain(entry: entry, exit: control.currentServer))
        }
        if control.foreignVPN != nil {
            Text("⚠︎ Работает VPN другой программы")
        }

        switch connection {
        case .connected, .connecting:
            Button("Отключить") { control.coreOff() }.disabled(control.busy)
        case .disconnected:
            Button("Подключить") { control.coreOn() }.disabled(control.busy || !control.coreConfigured)
        case .otherApp, .unavailable:
            EmptyView()
        }

        if let proxies = control.proxies {
            let groups = proxies.groups.filter(\.selectable)
            if !groups.isEmpty {
                Menu("Сервер") {
                    ForEach(groups) { group in
                        Section(group.name) {
                            ForEach(group.all, id: \.self) { name in
                                Toggle(isOn: Binding(get: { group.now == name },
                                                     set: { if $0 { control.coreSelect(group: group.name, proxy: name) } })) {
                                    let label = ServerName(name)
                                    Text("\(label.flag ?? "🌐") \(label.title.isEmpty ? name : label.title)")
                                }
                            }
                        }
                    }
                }
            }
        }
        if control.coreRunning, let proxies = control.proxies, !proxies.groups.isEmpty {
            Button(control.testing.isEmpty ? "Проверить пинг" : "Проверяю пинг…") {
                Task { await control.testAllDelays() }
            }
            .disabled(!control.testing.isEmpty)
            if let main = proxies.mainGroup, main.selectable {
                Button("Выбрать лучший сервер") { Task { await control.selectBest(group: main) } }
                    .disabled(!control.testing.isEmpty || control.busy)
            }
        }
        if client.hasURL {
            Button(client.updating ? "Обновляю подписку…" : "Обновить подписку") {
                Task { await client.update(interactive: true) }
            }
            .keyboardShortcut("r")
            .disabled(client.updating)
            if client.needsConfirmation {
                Button("Нужно подтверждение: в подписке новые серверы…") {
                    Task { await client.confirmNewServers() }
                }
                .disabled(client.updating)
            }
        }

        Divider()

        Text(control.state.title)
        switch control.state {
        case .on:
            Button("Выключить защиту") { control.turnOff() }
            Button("Пауза \(pauseShort) мин") { control.pause(minutes: pauseShort) }
            Button("Пауза \(pauseLong) мин") { control.pause(minutes: pauseLong) }
        case .off, .paused:
            Button("Включить защиту") { control.turnOn() }
        case .notInstalled, .unknown:
            EmptyView()
        }

        Divider()

        Button("Открыть окно") {
            openWindow(id: "main")
            NSApp.activate()
        }
        LeakTestView.OpenButton()
        SettingsLink { Text("Настройки…") }.keyboardShortcut(",")
        CheckForUpdatesButton(updater: updater)
        Button("Скопировать диагностику") { DiagnosticsCopy.copy(control: control, client: client) }
        Button("Выйти") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
