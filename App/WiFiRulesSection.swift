import CoreLocation
import SwiftUI

/// «Сети Wi‑Fi» (#39, spec §5.4): per network only «Подключаться автоматически» and
/// «Предпочитаемый сервер» (WiFiRules); protection is never turned off for a network. macOS names
/// the Wi-Fi only with Location access, so it is asked for on the first «Добавить текущую сеть»,
/// after saying why; without it the rules are greyed out with the reason.
struct WiFiRulesSection: View {
    @Environment(AutoConnector.self) private var auto
    @Environment(KillSwitchControl.self) private var control
    @Environment(VPNClient.self) private var client
    @State private var explainingLocation = false

    private var denied: Bool { auto.location == .denied || auto.location == .restricted }

    var body: some View {
        Section {
            if denied {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Без доступа к геопозиции macOS не называет сеть Wi‑Fi, поэтому правила для сетей не работают.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Открыть настройки геопозиции") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                    }
                }
            }
            ForEach(auto.rules) { rule in
                row(rule).disabled(denied)
            }
            addButton
            if let note = auto.ruleNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Сети Wi‑Fi")
        } footer: {
            Text("Правило срабатывает, когда Mac подключается к этой сети. Защита работает в любой сети: выключить её для сети нельзя.")
                .foregroundStyle(.secondary)
        }
        .alert("Доступ к геопозиции", isPresented: $explainingLocation) {
            Button("Продолжить") { auto.addCurrentNetwork() }
            Button("Отменить", role: .cancel) {}
        } message: {
            Text("macOS называет сеть Wi‑Fi только программам с доступом к геопозиции. KillSwitch читает лишь имя сети: само местоположение не используется, имена сетей остаются на этом Mac.")
        }
    }

    @ViewBuilder private var addButton: some View {
        if let ssid = auto.ssid, WiFiRules.rule(for: ssid, in: auto.rules) != nil {
            EmptyView()
        } else if auto.location == .notDetermined {
            Button("Добавить текущую сеть") { explainingLocation = true }
                .disabled(!auto.onWiFi)
        } else if !denied {
            VStack(alignment: .leading, spacing: 4) {
                Button("Добавить текущую сеть") { auto.addCurrentNetwork() }
                    .disabled(auto.ssid == nil)
                if auto.ssid == nil {
                    Text("Mac сейчас не подключён к Wi‑Fi.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func row(_ rule: WiFiRules.Rule) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(rule.ssid, systemImage: "wifi")
                if rule.ssid == auto.ssid {
                    Text("сейчас").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Убрать") { auto.removeRule(rule.ssid) }
                    .accessibilityLabel("Убрать сеть «\(rule.ssid)»")
            }
            Toggle(isOn: binding(rule, \.autoConnect)) {
                Text("Подключаться автоматически")
                Text("Даже если общее «Подключаться автоматически» выключено.")
            }
            .accessibilityLabel("Подключаться автоматически в сети «\(rule.ssid)»")
            Picker("Предпочитаемый сервер", selection: binding(rule, \.server)) {
                Text("Не менять").tag(String?.none)
                ForEach(entries) { entry in
                    Text(entry.title).tag(String?.some(entry.name))
                }
                if let name = rule.server, !entries.contains(where: { $0.name == name }) {
                    Text("\(ServerName.display(name)) — нет в подписке").tag(String?.some(name))
                }
            }
            .accessibilityLabel("Предпочитаемый сервер в сети «\(rule.ssid)»")
        }
    }

    private var entries: [ServerPicker.Entry] {
        (control.proxies ?? client.profileProxies).map { ServerPicker.entries($0, subscription: client.activeID) } ?? []
    }

    private func binding<Value>(_ rule: WiFiRules.Rule, _ field: WritableKeyPath<WiFiRules.Rule, Value>) -> Binding<Value> {
        Binding(get: { rule[keyPath: field] }, set: { value in
            var changed = rule
            changed[keyPath: field] = value
            auto.update(changed)
        })
    }
}
