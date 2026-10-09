import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AccessSettings().tabItem { Label("Что пропускать", systemImage: "checklist") }
            ServerSettings().tabItem { Label("Серверы VPN", systemImage: "network") }
            ExceptionSettings().tabItem { Label("Исключения", systemImage: "list.bullet") }
            CheckSettings().tabItem { Label("Проверка", systemImage: "checkmark.shield") }
            GeneralSettings().tabItem { Label("Общие", systemImage: "gearshape") }
        }
        .frame(width: 480)
    }
}

private struct AccessSettings: View {
    @Environment(KillSwitchControl.self) private var control

    var body: some View {
        Form {
            Section {
                toggle("Домашняя сеть", "Роутер, NAS, принтер, AirPlay.", key: "lan", value: control.allowLAN)
                toggle("Адреса сайтов через роутер", "Пока VPN выключен, Mac может узнавать адреса сайтов у роутера. Само содержимое не уходит, но видно, куда ходит Mac.", key: "dns", value: control.allowRouterDNS)
                    .disabled(!control.allowLAN)
                toggle("Сайты мимо VPN через dropweb", "Ядро dropweb сможет выходить на любые адреса, а не только к серверам VPN. Это слабее защиты: любая программа может запустить ядро со своим конфигом и выйти мимо VPN.", key: "direct", value: control.allowDirect)
                toggle("Отключать сеть при выключении Mac", "Wi-Fi, кабель и iPhone по USB отключаются при выключении Mac и включаются сами после загрузки, когда защита уже стоит. Так при загрузке ничего не утекает. Не спасает при внезапном выключении (сел аккумулятор, сбой).", key: "wifiguard", value: control.wifiGuard)
                toggle("Tailscale напрямую", "Прямая связь Tailscale между своими устройствами без VPN. Только для системной службы Tailscale.", key: "tailscale", value: control.allowTailscale)
            } footer: {
                Text("Каждое изменение спросит пароль.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(control.busy || control.state == .notInstalled)
    }

    private func toggle(_ title: String, _ hint: String, key: String, value: Bool) -> some View {
        Toggle(isOn: Binding(get: { value }, set: { control.set(key, $0) })) {
            Text(title)
            Text(hint)
        }
    }
}

private struct ServerSettings: View {
    @Environment(KillSwitchControl.self) private var control

    var body: some View {
        // found servers first, then ones that are allowed but no longer in any profile
        let rows = control.foundServers + control.servers.filter { !control.foundServers.contains($0) }
        Form {
            Section {
                if rows.isEmpty {
                    Text("Серверы не найдены. Подключись в dropweb или Happ хотя бы раз.").foregroundStyle(.secondary)
                }
                ForEach(rows, id: \.self) { server in
                    HStack {
                        Text(server).monospaced()
                        Spacer()
                        if control.servers.contains(server) {
                            Label("пропускается", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Button("Убрать", role: .destructive) { control.removeServer(server) }
                        } else {
                            Label("закрыт", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                        }
                    }
                }
                if control.foundServers.contains(where: { !control.servers.contains($0) }) {
                    Button("Пропускать найденные серверы") { control.allowFoundServers() }
                }
            } header: {
                Text("Серверы VPN")
            } footer: {
                Text("Без VPN доступны только эти адреса, и к ним сможет подключиться любая программа. Сайты, которые Happ отправляет мимо VPN (российские, Apple, Steam), при включённой защите открываться не будут. Изменения спросят пароль.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(control.busy || control.state == .notInstalled)
    }
}

private struct CheckSettings: View {
    @Environment(KillSwitchControl.self) private var control

    var body: some View {
        Form {
            Section {
                Button(control.leakRunning ? "Проверяю…" : "Проверить утечку") { control.checkLeak() }
                    .disabled(control.leakRunning)
                ForEach(control.leakResults) { result in
                    if result.leaked {
                        Label("\(result.interface): утечка, интернет идёт мимо VPN", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    } else {
                        Label("\(result.interface): защищено", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                if let ip = control.externalIP {
                    LabeledContent("Внешний адрес") { Text(ip).monospaced().textSelection(.enabled) }
                }
            } header: {
                Text("Утечка")
            } footer: {
                Text("Проверка пытается выйти в интернет напрямую через физические интерфейсы. Ответ значит утечку.")
                    .foregroundStyle(.secondary)
            }
            Section("События защиты") {
                if control.events.isEmpty {
                    Text("Пусто").foregroundStyle(.secondary)
                } else {
                    Text(control.events.joined(separator: "\n")).monospaced().font(.caption).textSelection(.enabled)
                }
            }
            Section("Советы") {
                Text("Выключи «Частный узел iCloud» (Private Relay): он может обходить фильтр.")
                Text("После каждого обновления macOS перезагрузи Mac и нажми проверку.")
                Text("Для полной защиты при загрузке выключай Wi-Fi перед выключением Mac.")
            }
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .task { control.refreshEvents() }
    }
}

private struct ExceptionSettings: View {
    @Environment(KillSwitchControl.self) private var control
    @State private var newAddress = ""

    var body: some View {
        Form {
            Section {
                if control.exceptions.isEmpty {
                    Text("Пусто").foregroundStyle(.secondary)
                }
                ForEach(control.exceptions, id: \.self) { address in
                    HStack {
                        Text(address).monospaced()
                        Spacer()
                        Button("Убрать", role: .destructive) { control.removeException(address) }
                    }
                }
                HStack {
                    TextField("Адрес, например 1.2.3.46 или 10.8.0.0/24", text: $newAddress)
                        .onSubmit(add)
                    Button("Добавить", action: add).disabled(newAddress.isEmpty)
                }
            } header: {
                Text("Всегда без VPN")
            } footer: {
                Text("Программы смогут ходить на эти адреса без VPN. Адреса серверов VPN добавляются на вкладке «Серверы VPN». Каждое изменение спросит пароль.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(control.busy || control.state == .notInstalled)
    }

    private func add() {
        control.addException(newAddress)
        newAddress = ""
    }
}

private struct GeneralSettings: View {
    @Environment(KillSwitchControl.self) private var control
    @AppStorage("pauseShort") private var pauseShort = 5
    @AppStorage("pauseLong") private var pauseLong = 30
    @AppStorage("notifyVPNDropped") private var notifyVPNDropped = true
    @AppStorage("notifyPauseEnded") private var notifyPauseEnded = true

    var body: some View {
        @Bindable var control = control
        Form {
            Section("Пауза") {
                Stepper("Короткая: \(pauseShort) мин", value: $pauseShort, in: 1...60)
                Stepper("Длинная: \(pauseLong) мин", value: $pauseLong, in: 5...240, step: 5)
            }
            Section("Уведомления") {
                Toggle("VPN отключился, интернет перекрыт", isOn: $notifyVPNDropped)
                Toggle("Пауза закончилась", isOn: $notifyPauseEnded)
            }
            Section {
                Toggle("Запускать при входе", isOn: $control.launchAtLogin)
            }
        }
        .formStyle(.grouped)
    }
}
