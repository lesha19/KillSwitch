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

/// Latency badge: green under 150 ms, orange under 400, red above.
struct DelayBadge: View {
    let delay: Int?

    var body: some View {
        if let delay {
            Text("\(delay) мс")
                .font(.caption.monospacedDigit())
                .foregroundStyle(delay < 150 ? .green : delay < 400 ? .orange : .red)
        }
    }
}

/// Servers of the running core, grouped as in the profile. Selector groups take a click.
struct ServerList: View {
    @Environment(KillSwitchControl.self) private var control

    var body: some View {
        if let proxies = control.proxies, !proxies.groups.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(proxies.groups) { group in
                    GroupSection(group: group, proxies: proxies)
                }
            }
        } else if control.coreRunning {
            Text("Загружаю список серверов…").foregroundStyle(.secondary).font(.callout)
        } else {
            Text("Список серверов появится после подключения.").foregroundStyle(.secondary).font(.callout)
        }
    }

    private struct GroupSection: View {
        @Environment(KillSwitchControl.self) private var control
        let group: CoreProxies.Group
        let proxies: CoreProxies
        @State private var expanded = true

        var body: some View {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(spacing: 2) {
                    ForEach(group.all, id: \.self) { name in
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
                }
            }
        }

        private func row(_ name: String) -> some View {
            let current = group.now == name
            return Button {
                if group.selectable && !current { control.coreSelect(group: group.name, proxy: name) }
            } label: {
                HStack {
                    Image(systemName: current ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(current ? Color.accentColor : .secondary)
                    ServerLabel(name: name)
                    Spacer()
                    DelayBadge(delay: proxies.delay(name))
                }
                .padding(.vertical, 5).padding(.horizontal, 8)
                .contentShape(Rectangle())
                .background(current ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(!group.selectable || control.busy)
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
