import SwiftUI

struct ContentView: View {
    @Environment(KillSwitchControl.self) private var control

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 64))
                .foregroundStyle(color)

            VStack(spacing: 6) {
                Text(title).font(.title2.bold())
                Text(subtitle).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }

            Label(control.vpnUp ? "VPN dropweb подключён" : "VPN dropweb не подключён",
                  systemImage: control.vpnUp ? "network" : "network.slash")
                .foregroundStyle(control.vpnUp ? .green : .orange)

            if control.state == .notInstalled {
                Text("Защита не установлена. Запусти в Терминале:\n~/KillSwitch/Helper/install.sh")
                    .font(.callout).multilineTextAlignment(.center).textSelection(.enabled)
            } else {
                VStack(spacing: 10) {
                    if control.state == .on {
                        Button("Выключить") { control.turnOff() }
                            .controlSize(.large).buttonStyle(.borderedProminent).tint(.red)
                        HStack {
                            Button("Пауза 5 минут") { control.pause(minutes: 5) }
                            Button("Пауза 30 минут") { control.pause(minutes: 30) }
                        }
                    } else {
                        Button("Включить") { control.turnOn() }
                            .controlSize(.large).buttonStyle(.borderedProminent).tint(.green)
                    }
                }
                .disabled(control.busy || control.state == .unknown)
            }

            if let error = control.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(32)
        .frame(width: 360)
    }

    private var icon: String {
        switch control.state {
        case .on: "lock.shield.fill"
        case .off, .paused: "shield.slash"
        case .notInstalled, .unknown: "shield"
        }
    }

    private var color: Color {
        switch control.state {
        case .on: .green
        case .off: .red
        case .paused: .orange
        case .notInstalled, .unknown: .gray
        }
    }

    private var title: String {
        switch control.state {
        case .on: "Защита включена"
        case .off: "Защита выключена"
        case .paused: "Защита на паузе"
        case .notInstalled: "Не установлена"
        case .unknown: "Проверяю…"
        }
    }

    private var subtitle: String {
        switch control.state {
        case .on: "Интернет только через VPN. Домашняя сеть доступна."
        case .off: "Программы выходят в интернет и без VPN."
        case .paused(let until): "Включится сама в \(until.formatted(date: .omitted, time: .shortened))."
        case .notInstalled, .unknown: ""
        }
    }
}
