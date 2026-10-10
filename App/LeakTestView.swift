import SwiftUI

/// «Проверка утечек»: public address over IPv4 and IPv6, DNS resolvers, one verdict.
struct LeakTestView: View {
    @Environment(KillSwitchControl.self) private var control
    @Environment(LeakTester.self) private var tester

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    verdictHeader
                    Button {
                        Task {
                            await tester.run(vpnConnected: control.vpnUp, otherVPN: control.otherVPNActive,
                                             otherVPNName: control.otherVPNName,
                                             probe: control.state == .on ? { await control.probeDirectExits() } : nil)
                        }
                    } label: {
                        Text(tester.running ? String(localized: "Проверяю…") : String(localized: "Проверить")).frame(maxWidth: .infinity)
                    }
                    .controlSize(.large).buttonStyle(.borderedProminent)
                    .disabled(tester.running)
                    if tester.running {
                        ProgressView(tester.step).controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }

            NetworkHintsSection()

            if let result = tester.result {
                if !result.verdict.findings.isEmpty {
                    Section {
                        ForEach(Array(result.verdict.findings.enumerated()), id: \.offset) { _, finding in
                            StatusLabel(finding.text, systemImage: finding.isLeak ? "xmark.octagon.fill" : "info.circle",
                                        tint: finding.isLeak ? .red : .secondary)
                        }
                    }
                }
                Section("Адрес в интернете") {
                    ForEach(result.ipv4, id: \.source) { row in
                        LabeledContent("IPv4 (\(row.source))") {
                            Text(row.ip ?? String(localized: "нет ответа")).monospaced().textSelection(.enabled)
                        }
                    }
                    if let exit = result.exit, exit.country != nil || exit.org != nil {
                        LabeledContent("Где") { Text([exit.country, exit.org].compactMap { $0 }.joined(separator: " · ")) }
                    }
                    LabeledContent("IPv6") {
                        if let v6 = result.ipv6 {
                            Text(v6.ip).monospaced().textSelection(.enabled)
                        } else {
                            StatusLabel("недоступен", systemImage: "checkmark.circle.fill", tint: .green)
                        }
                    }
                }
                Section {
                    if result.resolvers.isEmpty {
                        Text("Нет данных").foregroundStyle(.secondary)
                    }
                    ForEach(result.resolvers) { resolver in
                        LabeledContent {
                            Text([resolver.country, resolver.org].compactMap { $0 }.joined(separator: " · "))
                        } label: {
                            Text(resolver.ip).monospaced().textSelection(.enabled)
                        }
                    }
                } header: {
                    Text("Кто узнаёт адреса сайтов (DNS)")
                } footer: {
                    Text("Здесь не должно быть твоего провайдера. Серверы в другой стране — нормально: это DNS, через который работает VPN.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if let home = tester.home {
                    LabeledContent("Без VPN") {
                        Text([home.ipv4, home.org].compactMap { $0 }.joined(separator: " · ")).textSelection(.enabled)
                    }
                    if let date = tester.homeDate {
                        LabeledContent("Запомнено") { Text(date.formatted(date: .abbreviated, time: .shortened)) }
                    }
                    Button("Забыть", role: .destructive) { tester.forgetHome() }
                } else {
                    Text("Неизвестен. Чтобы проверка могла узнать твоего провайдера среди DNS-серверов, один раз запусти её с отключённым VPN и выключенной (или на паузе) защитой.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Твой обычный адрес")
            } footer: {
                Text("Хранится только на этом Mac. Проверка обращается к api.ipify.org, am.i.mullvad.net и bash.ws так же, как любая программа: без ссылок подписки, ключей и данных о Mac.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var verdictHeader: some View {
        if let verdict = tester.result?.verdict {
            let color: Color = !verdict.clean ? .red : verdict.findings.contains(.vpnOff) || verdict.otherVPN ? .orange : .green
            Image(systemName: verdict.clean ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 44)).foregroundStyle(color)
                .accessibilityHidden(true)
            Text(verdict.title).font(.title2.bold())
            if verdict.needsHomeReference && verdict.clean {
                Text("Твой обычный адрес неизвестен, поэтому DNS-серверы провайдера не с чем сравнить — посмотри список ниже.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Image(systemName: "shield.lefthalf.filled").font(.system(size: 44)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Проверка утечек").font(.title2.bold())
            Text("Проверит, может ли что-то выйти мимо VPN, какой адрес видят сайты и кто узнаёт для тебя адреса сайтов.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Tips about «Частный узел iCloud» and overlay networks (NetworkHints): only what is there, never
/// blocking; nothing shows when there is nothing to say. In «Проверка утечек» and «О программе».
struct NetworkHintsSection: View {
    @Environment(KillSwitchControl.self) private var control
    @State private var hints: [NetworkHints.Hint] = []

    var body: some View {
        Group {
            if !hints.isEmpty {
                Section("Стоит знать") {
                    ForEach(hints, id: \.title) { hint in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(hint.title, systemImage: hint == .privateRelay ? "icloud" : "point.3.connected.trianglepath.dotted")
                                .font(.callout.bold())
                            Text(hint.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            if hint == .privateRelay {
                                Button("Открыть настройки iCloud") { NSWorkspace.shared.open(SystemSettings.iCloud) }
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .onAppear { hints = control.networkHints() }
    }
}
