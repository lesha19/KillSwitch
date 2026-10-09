import SwiftUI

struct ContentView: View {
    @Environment(KillSwitchControl.self) private var control
    @AppStorage("pauseShort") private var pauseShort = 5
    @AppStorage("pauseLong") private var pauseLong = 30
    @State private var confirmUninstall = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(color.opacity(0.15)).frame(width: 120, height: 120)
                    Image(systemName: control.state.symbol)
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundStyle(color)
                        .contentTransition(.symbolEffect(.replace))
                }

                VStack(spacing: 6) {
                    Text(control.state.title).font(.title2.bold())
                    Text(subtitle).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }

                Label(control.vpnUp ? "VPN dropweb подключён" : "VPN dropweb не подключён",
                      systemImage: control.vpnUp ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(control.vpnUp ? .green : .orange)
                    .font(.callout)

                actions
                    .disabled(control.busy || control.state == .unknown)

                if let error = control.error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(28)

            if control.daemonProblem {
                Label("Фоновая служба защиты выключена в Системных настройках → Основные → Объекты входа. Правила пока действуют, но следить за ними некому.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .padding(.horizontal, 20).padding(.bottom, 16)
            }

            Divider()

            HStack {
                SettingsLink { Label("Настройки", systemImage: "gearshape") }
                    .buttonStyle(.link)
                Spacer()
                if control.state != .notInstalled && control.state != .unknown {
                    Button("Обновить защиту") { control.install() }
                        .buttonStyle(.link).disabled(control.busy)
                    Button("Удалить защиту…", role: .destructive) { confirmUninstall = true }
                        .buttonStyle(.link).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 380)
        .animation(.default, value: control.state)
        .confirmationDialog("Удалить защиту?", isPresented: $confirmUninstall) {
            Button("Удалить", role: .destructive) { control.uninstall() }
        } message: {
            Text("Правила снимутся, программы снова смогут выходить в интернет без VPN. Понадобится пароль.")
        }
    }

    @ViewBuilder private var actions: some View {
        switch control.state {
        case .notInstalled:
            Button { control.install() } label: {
                Text("Установить защиту").frame(maxWidth: .infinity)
            }
            .controlSize(.large).buttonStyle(.borderedProminent)
            Text("Попросит пароль.").font(.caption).foregroundStyle(.secondary)
        case .on:
            Button { control.turnOff() } label: {
                Text("Выключить").frame(maxWidth: .infinity)
            }
            .controlSize(.large).buttonStyle(.borderedProminent).tint(.red)
            Text("Выключение и пауза просят пароль.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Пауза \(pauseShort) мин") { control.pause(minutes: pauseShort) }
                Button("Пауза \(pauseLong) мин") { control.pause(minutes: pauseLong) }
            }
        case .off, .paused, .unknown:
            Button { control.turnOn() } label: {
                Text("Включить").frame(maxWidth: .infinity)
            }
            .controlSize(.large).buttonStyle(.borderedProminent).tint(.green)
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

    private var subtitle: String {
        switch control.state {
        case .on: "Интернет только через VPN.\nДомашняя сеть доступна."
        case .off: "Программы выходят в интернет и без VPN."
        case .paused(let until): "Включится сама в \(until.formatted(date: .omitted, time: .shortened))."
        case .notInstalled: "Программы выходят в интернет и без VPN."
        case .unknown: " "
        }
    }
}
