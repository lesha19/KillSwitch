import SwiftUI

/// What the VPN connection is doing, as the user sees it.
enum Connection: Equatable {
    case unavailable    // helper or core not installed
    case disconnected
    case connecting     // core started, tunnel not up yet
    case connected
    case otherApp       // a tunnel is up, but not ours (Happ, dropweb…)

    var title: String {
        switch self {
        case .unavailable: "VPN не установлен"
        case .disconnected: "Не подключено"
        case .connecting: "Подключаюсь…"
        case .connected: "Подключено"
        case .otherApp: "VPN другой программы"
        }
    }

    var color: Color {
        switch self {
        case .connected: .green
        case .connecting, .otherApp: .orange
        case .disconnected: .red
        case .unavailable: .gray
        }
    }

    var symbol: String {
        switch self {
        case .connected: "lock.shield.fill"
        case .connecting: "shield.lefthalf.filled"
        case .otherApp: "shield"
        case .disconnected, .unavailable: "shield.slash"
        }
    }
}

extension KillSwitchControl {
    var connection: Connection {
        if state == .notInstalled || !coreInstalled { return vpnUp ? .otherApp : .unavailable }
        if coreRunning { return vpnUp ? .connected : .connecting }
        return vpnUp ? .otherApp : .disconnected
    }

    /// The server traffic goes through right now, following nested groups.
    var currentServer: String? {
        guard let proxies, let main = proxies.mainGroup else { return nil }
        return proxies.leaf(of: main.name)
    }
}

/// Flag + name of a server.
struct ServerLabel: View {
    let name: String
    var font: Font = .body

    var body: some View {
        let parts = ServerName(name)
        HStack(spacing: 6) {
            Text(parts.flag ?? "🌐").font(font)
            Text(parts.title.isEmpty ? name : parts.title).font(font).lineLimit(1).truncationMode(.tail)
        }
    }
}

/// Latency badge: green under 150 ms, orange under 400, red above; "нет ответа" after a failed test.
struct DelayBadge: View {
    let delay: Int?
    var timedOut = false

    var body: some View {
        if let delay {
            Text("\(delay) мс")
                .font(.caption.monospacedDigit())
                .foregroundStyle(delay < 150 ? .green : delay < 400 ? .orange : .red)
                .accessibilityLabel("Пинг \(delay) миллисекунд")
        } else if timedOut {
            Text("нет ответа").font(.caption).foregroundStyle(.red)
                .accessibilityLabel("Сервер не ответил")
        }
    }
}

/// Servers of the running core, grouped as in the profile. Selector groups take a click.
struct ServerList: View {
    @Environment(KillSwitchControl.self) private var control
    @AppStorage("sortByLatency") private var sortByLatency = false

    var body: some View {
        if let proxies = control.proxies, !proxies.groups.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                toolbar
                ForEach(proxies.groups) { group in
                    GroupSection(group: group, sortByLatency: sortByLatency)
                }
                if let error = control.coreError {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if let error = control.proxiesError, control.coreRunning {
            VStack(alignment: .leading, spacing: 6) {
                Label("Список серверов недоступен", systemImage: "exclamationmark.triangle").font(.headline)
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Повторить") { control.loadProxies(force: true) }
            }
        } else if control.proxies?.groups.isEmpty == true {
            Text("В профиле нет групп серверов. Проверь подписку.").foregroundStyle(.secondary).font(.callout)
        } else if control.coreRunning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Загружаю список серверов…").foregroundStyle(.secondary).font(.callout)
            }
        } else {
            Text("Список серверов появится после подключения.").foregroundStyle(.secondary).font(.callout)
        }
    }

    private var toolbar: some View {
        let testingAll = control.testing.contains(KillSwitchControl.allGroupsKey)
        return HStack {
            Text("Серверы").font(.title3.bold())
            Spacer()
            Toggle("По пингу", isOn: $sortByLatency)
                .toggleStyle(.checkbox).font(.callout)
                .help("Сортировать серверы по задержке")
            Button {
                Task { await control.testAllDelays() }
            } label: {
                if testingAll { ProgressView().controlSize(.small) } else { Label("Проверить пинг", systemImage: "speedometer") }
            }
            .buttonStyle(.borderless)
            .disabled(!control.testing.isEmpty)
            .help("Проверить задержку всех серверов")
            .accessibilityLabel("Проверить пинг всех серверов")
        }
    }

    private struct GroupSection: View {
        @Environment(KillSwitchControl.self) private var control
        let group: CoreProxies.Group
        let sortByLatency: Bool
        @State private var expanded = true

        var body: some View {
            let names = sortByLatency ? CoreDelay.sorted(group.all, delays: delays) : group.all
            DisclosureGroup(isExpanded: $expanded) {
                VStack(spacing: 2) {
                    if names.isEmpty {
                        Text("В группе нет серверов.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(names, id: \.self) { name in
                        row(name)
                    }
                }
                .padding(.top, 4)
            } label: {
                HStack {
                    Text(group.name).font(.headline)
                    if !group.selectable {
                        Text(group.type == "URLTest" ? "сам выбирает быстрый" : "автоматически")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if control.testing.contains(group.name) {
                        ProgressView().controlSize(.small).accessibilityLabel("Проверяю пинг")
                    } else {
                        Button {
                            Task { await control.testDelay(group: group) }
                        } label: { Image(systemName: "speedometer") }
                        .buttonStyle(.borderless)
                        .disabled(!control.testing.isEmpty)
                        .help("Проверить пинг группы")
                        .accessibilityLabel("Проверить пинг группы \(group.name)")
                        if group.selectable {
                            Button("Лучший") { Task { await control.selectBest(group: group) } }
                                .buttonStyle(.borderless)
                                .disabled(!control.testing.isEmpty || control.busy)
                                .help("Проверить пинг и выбрать самый быстрый сервер")
                                .accessibilityLabel("Выбрать самый быстрый сервер в группе \(group.name)")
                        }
                    }
                }
            }
        }

        /// What the list sorts by: measured or historical delay, timeouts marked.
        private var delays: [String: Int] {
            var delays: [String: Int] = [:]
            for name in group.all {
                if let delay = control.delay(of: name) {
                    delays[name] = delay
                } else if control.timedOut(name) {
                    delays[name] = CoreDelay.timeout
                }
            }
            return delays
        }

        private func row(_ name: String) -> some View {
            let current = group.now == name
            let label = ServerName(name)
            return Button {
                if group.selectable && !current { control.coreSelect(group: group.name, proxy: name) }
            } label: {
                HStack {
                    Image(systemName: current ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(current ? Color.accentColor : .secondary)
                        .accessibilityHidden(true)
                    ServerLabel(name: name)
                    Spacer()
                    DelayBadge(delay: control.delay(of: name), timedOut: control.timedOut(name))
                }
                .padding(.vertical, 5).padding(.horizontal, 8)
                .contentShape(Rectangle())
                .background(current ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(!group.selectable || control.busy)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label.title.isEmpty ? name : label.title)
            .accessibilityValue([current ? "выбран" : nil,
                                 control.delay(of: name).map { "\($0) миллисекунд" },
                                 control.timedOut(name) ? "не ответил" : nil].compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(current ? .isSelected : [])
            .accessibilityHint(group.selectable && !current ? "Подключиться через этот сервер" : "")
        }
    }
}

/// Traffic and expiry of the subscription.
struct SubscriptionSummary: View {
    @Environment(VPNClient.self) private var client

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(client.status.title ?? "Подписка").font(.headline)
                Spacer()
                Button {
                    Task { await client.update(interactive: true) }
                } label: {
                    if client.updating { ProgressView().controlSize(.small) } else { Label("Обновить", systemImage: "arrow.clockwise") }
                }
                .buttonStyle(.borderless)
                .disabled(client.updating || !client.hasURL)
            }
            if let usage = client.status.usage {
                if let total = usage.total {
                    ProgressView(value: Double(min(usage.used, total)), total: Double(total))
                        .tint(Double(usage.used) / Double(total) > 0.9 ? .red : .accentColor)
                    Text("Трафик: \(Self.bytes(usage.used)) из \(Self.bytes(total))").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Трафик: \(Self.bytes(usage.used)), без ограничения").font(.caption).foregroundStyle(.secondary)
                }
                if let expire = usage.expire {
                    Text(expire < Date() ? "Подписка закончилась \(expire.formatted(date: .long, time: .omitted))"
                                         : "Действует до \(expire.formatted(date: .long, time: .omitted))")
                        .font(.caption).foregroundStyle(expire.timeIntervalSinceNow < 3 * 86400 ? .orange : .secondary)
                }
            }
            if let last = client.status.lastUpdate {
                Text("Обновлено \(last.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
            }
            if client.needsPassword {
                Text("Пришёл новый профиль. Нажми «Обновить», чтобы применить (попросит пароль).")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let error = client.lastError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .binary)
    }
}

/// First run: paste the subscription URL.
struct SubscriptionOnboarding: View {
    @Environment(VPNClient.self) private var client
    @State private var url = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Добавь подписку").font(.headline)
            Text("Вставь ссылку подписки (Remnawave, любая подписка mihomo/Clash). Ссылка хранится в связке ключей.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                SecureField("https://…", text: $url).onSubmit(save)
                Button("Добавить", action: save).disabled(url.isEmpty || client.updating)
            }
            if client.updating { ProgressView().controlSize(.small) }
            if let error = client.lastError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func save() {
        let value = url
        url = ""
        Task { await client.setURL(value) }
    }
}
