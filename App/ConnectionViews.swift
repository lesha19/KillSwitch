import SwiftUI

extension Connection {
    var title: String {
        switch self {
        case .unavailable: String(localized: "VPN не установлен")
        case .disconnected: String(localized: "Отключено")
        case .connecting: String(localized: "Подключение…")
        case .connected: String(localized: "Подключено")
        case .otherApp: String(localized: "VPN другой программы")
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

extension Protection {
    var symbol: String {
        switch self {
        case .on: "lock.shield.fill"
        case .off, .paused: "shield.slash"
        case .notInstalled, .unknown: "shield"
        }
    }

    var title: String {
        switch self {
        case .on: String(localized: "Защита включена")
        case .off: String(localized: "Без защиты")
        case .paused: String(localized: "Пауза защиты")
        case .notInstalled: String(localized: "Защита не установлена")
        case .unknown: String(localized: "Проверяю…")
        }
    }
}

extension KillSwitchControl {
    var connection: Connection {
        // another VPN: a 198.18 tunnel that is not ours, or any tunnel taking the routes (OtherVPN.tunnels)
        let other = vpnUp || !otherTunnels.isEmpty
        if state == .notInstalled || !coreInstalled { return other ? .otherApp : .unavailable }
        // Our tunnel is told by its address: another VPN's tunnel next to the running core is not
        // a connection through it.
        if coreRunning { return ownTunnelUp ? .connected : other ? .otherApp : .connecting }
        return other ? .otherApp : .disconnected
    }

    /// The server traffic goes through right now, following nested groups.
    var currentServer: String? {
        guard let proxies, let main = proxies.mainGroup else { return nil }
        return proxies.leaf(of: main.name)
    }

    /// The summary of spec §2 (see Status).
    func status(_ client: VPNClient) -> Status {
        Status.summary(Status.Input(
            protection: state, connection: connection, foreignVPN: foreignVPN != nil, daemonProblem: daemonProblem,
            coreInstalled: coreInstalled, needsRepair: needsRepair || helperOutdated && !upgradingHelper,
            hasServers: coreConfigured || client.hasURL || !client.manual.isEmpty,
            connectingSince: connectingSince, now: clock, standby: protectionStandby, vpnOn: vpnOn,
            tunnelWasUp: tunnelWasUp, rulesMissing: rulesMissing))
    }
}

/// Flag + name of a server.
struct ServerLabel: View {
    let name: String
    var font: Font = .body

    var body: some View {
        let parts = ServerName(name)
        HStack(spacing: 6) {
            // a name with its own emoji (⚡ Auto) gets no 🌐 in front
            if let flag = parts.flag { Text(flag).font(font) } else if !ServerName.startsWithEmoji(name) { Text("🌐").font(font) }
            Text(parts.title.isEmpty ? name : parts.title).font(font).lineLimit(1).truncationMode(.tail)
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
                    InlineError(error: error)
                }
            }
        } else if let error = control.proxiesError, control.coreRunning {
            VStack(alignment: .leading, spacing: 6) {
                InlineError(error: error)
                Button("Повторить") { control.loadProxies(force: true) }
            }
        } else if control.proxies?.groups.isEmpty == true {
            Text("В подписке нет серверов. Проверь ссылку подписки.").foregroundStyle(.secondary).font(.callout)
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
                .help("Сортировать серверы по пингу")
            Button {
                Task { await control.testAllDelays() }
            } label: {
                if testingAll { ProgressView().controlSize(.small) } else { Label("Проверить пинг", systemImage: "speedometer") }
            }
            .buttonStyle(.borderless)
            .disabled(!control.testing.isEmpty)
            .help("Проверить пинг всех серверов")
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
                        Text(group.type == "URLTest" ? String(localized: "сам выбирает быстрый") : String(localized: "автоматически"))
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
                    PingView(ping: ServerPicker.Ping(delay: control.delay(of: name), timedOut: control.timedOut(name)))
                }
                .padding(.vertical, 5).padding(.horizontal, 8)
                .contentShape(Rectangle())
                .background(current ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(!group.selectable || control.busy)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label.title.isEmpty ? name : label.title)
            .accessibilityValue([current ? String(localized: "выбран") : nil,
                                 control.delay(of: name).map { String(localized: "\($0) миллисекунд") },
                                 control.timedOut(name) ? String(localized: "не ответил") : nil].compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(current ? .isSelected : [])
            .accessibilityHint(group.selectable && !current ? String(localized: "Подключиться через этот сервер") : "")
        }
    }
}

/// Traffic and expiry of the subscription.
struct SubscriptionSummary: View {
    @Environment(VPNClient.self) private var client

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(client.status.title ?? String(localized: "Подписка")).font(.headline)
                Spacer()
                Button {
                    Task { await client.update(interactive: true) }
                } label: {
                    if client.updating { ProgressView().controlSize(.small) } else { Label("Обновить", systemImage: "arrow.clockwise") }
                }
                .buttonStyle(.borderless)
                .disabled(client.updating || !client.hasURL)
                .help("Обновить подписку (⌘R)")
                .accessibilityLabel(client.updating ? String(localized: "Подписка обновляется") : String(localized: "Обновить подписку"))
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
                    let text = expire < Date() ? String(localized: "Подписка закончилась \(expire.formatted(date: .long, time: .omitted))")
                                               : String(localized: "Действует до \(expire.formatted(date: .long, time: .omitted))")
                    if expire.timeIntervalSinceNow < 3 * 86400 {
                        StatusLabel(text, systemImage: "exclamationmark.triangle.fill", tint: .orange).font(.caption)
                    } else {
                        Text(text).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let last = client.status.lastUpdate {
                Text("Обновлено \(last.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
            }
            if let source = client.status.source {
                Text("Откуда: \(source.label)").font(.caption).foregroundStyle(.secondary)
            }
            if client.needsConfirmation {
                HStack {
                    if client.routingChanged {
                        StatusLabel("Нужно подтверждение: подписка меняет правила «напрямую», часть трафика пойдёт мимо VPN",
                                    systemImage: "exclamationmark.triangle.fill", tint: .orange).font(.caption)
                    } else {
                        StatusLabel("Нужно подтверждение: в подписке новые серверы",
                                    systemImage: "exclamationmark.triangle.fill", tint: .orange).font(.caption)
                    }
                    Button("Подтвердить…") { Task { await client.confirmNewServers() } }
                        .controlSize(.small)
                        .disabled(client.updating)
                        .help(!client.routingChanged ? "Разрешить новые серверы подписки (спросит пароль)"
                              : "Разрешить новые правила «напрямую» подписки (спросит пароль)")
                }
            }
            if client.needsPassword {
                StatusLabel("Подписка изменилась. Нажми «Обновить», чтобы применить (спросит пароль).",
                            systemImage: "exclamationmark.triangle.fill", tint: .orange).font(.caption)
            }
            if let error = client.lastError {
                InlineError(error: error)
            }
        }
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .binary)
    }
}
