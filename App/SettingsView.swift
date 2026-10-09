import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AccessSettings().tabItem { Label("Что пропускать", systemImage: "checklist") }
            HappSettings().tabItem { Label("Happ", systemImage: "network") }
            ExceptionSettings().tabItem { Label("Исключения", systemImage: "list.bullet") }
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

private struct HappSettings: View {
    @Environment(KillSwitchControl.self) private var control

    var body: some View {
        Form {
            Section {
                if control.happServers.isEmpty {
                    Text("Серверы Happ не найдены. Подключись в Happ хотя бы раз.").foregroundStyle(.secondary)
                }
                ForEach(control.happServers, id: \.self) { server in
                    HStack {
                        Text(server).monospaced()
                        Spacer()
                        if control.exceptions.contains(server) {
                            Label("пропускается", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Label("закрыт", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                        }
                    }
                }
                if control.happServers.contains(where: { !control.exceptions.contains($0) }) {
                    Button("Пропускать серверы Happ") { control.allowHappServers() }
                }
            } header: {
                Text("Серверы Happ")
            } footer: {
                Text("Happ нельзя отличить от других программ, поэтому пропускаются адреса его серверов. Сайты, которые Happ отправляет мимо VPN (российские, Apple, Steam), при включённой защите открываться не будут. Добавление спросит пароль.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(control.busy || control.state == .notInstalled)
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
                Text("Программы смогут ходить на эти адреса без VPN. Чтобы работал Happ, добавь сюда адреса его серверов. Каждое изменение спросит пароль.")
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
