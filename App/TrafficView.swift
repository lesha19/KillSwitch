import AppKit
import SwiftUI

/// «Трафик» (spec §5.6, ADR 0013): where traffic goes and why. The routing is the subscription's;
/// the window shows its rules as the core has them, the live connections and a check of one address.
struct TrafficView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case rules, connections, check
        var id: String { rawValue }

        var title: String {
            switch self {
            case .rules: String(localized: "Правила")
            case .connections: String(localized: "Соединения")
            case .check: String(localized: "Проверить адрес")
            }
        }
    }

    @Environment(KillSwitchControl.self) private var control
    @AppStorage("trafficTab") private var tab: Tab = .rules

    /// The main way of connecting (Xray, ADR 0020) lists no live connections; its rules are walked
    /// by «Проверить адрес» since ADR 0027.
    static func tabs(_ core: CoreChoice) -> [Tab] { core.hasConnections ? Tab.allCases : [.rules, .check] }

    var body: some View {
        let tabs = Self.tabs(control.coreChoice)
        let shown = tabs.contains(tab) ? tab : .rules
        VStack(spacing: 0) {
            if tabs.count > 1 {
                Picker("Раздел", selection: $tab) {
                    ForEach(tabs) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .padding(.top, 14).padding(.bottom, 6)
            }
            switch shown {
            case .rules: RulesTab()
            case .connections: ConnectionsTab()
            case .check: CheckAddressTab()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { control.readRouting() }
    }
}

// MARK: - shared pieces

/// «Напрямую», «🇱🇹 Литва», «Блок» with its colour; a group shows the server it has chosen now.
private struct RouteBadge: View {
    @Environment(KillSwitchControl.self) private var control
    let route: TrafficRoute
    var showLeaf = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: Self.symbol(route.kind)).foregroundStyle(Self.color(route.kind)).imageScale(.small)
                .accessibilityHidden(true)
            Text(text).lineLimit(1).truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }

    private var leaf: String? {
        guard showLeaf, case .vpn(let name) = route, let leaf = control.proxies?.leaf(of: name), leaf != name else { return nil }
        return leaf
    }

    private var text: String {
        guard case .vpn(let name) = route else { return route.title }
        if let leaf { return "\(name) → \(Self.flagged(leaf))" }
        return Self.flagged(name)
    }

    private var spoken: String {
        guard case .vpn(let name) = route else { return route.title }
        let base = String(localized: "Через VPN: \(ServerName.spoken(name))")
        return leaf.map { base + ", " + ServerName.spoken($0) } ?? base
    }

    static func flagged(_ name: String) -> String {
        if ServerName.startsWithEmoji(name) { return name }
        return ServerName(name).flag.map { "\($0) \(name)" } ?? name
    }

    static func symbol(_ kind: TrafficRoute.Kind) -> String {
        switch kind {
        case .direct: "arrow.up.right.circle.fill"
        case .vpn: "lock.circle.fill"
        case .block: "nosign"
        }
    }

    static func color(_ kind: TrafficRoute.Kind) -> Color {
        switch kind {
        case .direct: .orange
        case .vpn: .green
        case .block: .red
        }
    }
}

/// A search field in the native look, for the top of a tab.
private struct SearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .accessibilityLabel("Очистить")
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

private struct NoReport: View {
    var body: some View {
        ContentUnavailableView {
            Label("Правил пока нет", systemImage: "list.bullet.rectangle")
        } description: {
            Text("Они появятся, когда подписка будет загружена в VPN. Если VPN уже работает, обнови подписку: служба защиты старой версии не сообщает правила.")
        }
    }
}

// MARK: - «Правила»

private struct RulesTab: View {
    @Environment(KillSwitchControl.self) private var control
    @State private var search = ""

    var body: some View {
        if let report = control.routing {
            content(report)
        } else {
            NoReport()
        }
    }

    private func content(_ report: RoutingReport) -> some View {
        let runs = Self.runs(report.rules.filter { matches($0.rule) })
        return Form {
            Section {
                summary(report)
            }
            if runs.isEmpty {
                Text("Ничего не найдено").foregroundStyle(.secondary)
            }
            ForEach(runs) { run in
                Section {
                    // row ids are unique across the whole Form: macOS lays a grouped Form out as one
                    // list, and equal ids in two sections put a footer in place of a row
                    ForEach(run.items.map { ("rule-\($0.offset)", $0.rule) }, id: \.0) { _, rule in
                        RuleRow(rule: rule, report: report, search: search)
                    }
                } header: {
                    let route = TrafficRoute(target: RoutingRule(run.items[0].rule.rule)?.target ?? "")
                    HStack {
                        RouteBadge(route: route)
                        Spacer()
                        Text(Self.count(run.items.count)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            let dropped = report.dropped(leftOut: UserDefaults.standard.stringArray(forKey: RoutingReport.leftOutKey) ?? [])
            if !dropped.isEmpty || !report.tidied.isEmpty {
                DroppedSection(report: report, dropped: dropped)
            }
            AddedSection(report: report)
            TakenSection(report: report)
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .top, spacing: 0) {
            SearchField(prompt: String(localized: "Найти правило, сайт или сервер"), text: $search)
                .frame(maxWidth: 420).padding(.horizontal, 20).padding(.vertical, 6)
        }
    }

    private func summary(_ report: RoutingReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Куда идёт трафик, решает подписка").font(.headline)
            } icon: {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.tint)
            }
            Text("Ядро сверяет каждое соединение с правилами сверху вниз: первое подходящее решает, пойдёт оно через VPN, напрямую или будет заблокировано. Если не подошло ни одно, соединение идёт напрямую. KillSwitch маршруты не меняет — только то, что ты включил сам.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if report.egress.isEmpty {
                StatusLabel("Всё идёт через VPN: напрямую подписка ничего не отправляет", systemImage: "lock.fill", tint: .green)
            } else {
                ForEach(report.egressReasons, id: \.self) { reason in
                    StatusLabel(String(localized: "Мимо VPN: \(reason)"), systemImage: "arrow.up.right.circle", tint: .orange)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func matches(_ rule: String) -> Bool {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        if rule.lowercased().contains(needle) { return true }
        guard let parsed = RoutingRule(rule) else { return false }
        if parsed.typeTitle.lowercased().contains(needle) || parsed.route.title.lowercased().contains(needle) { return true }
        if parsed.type == "RULE-SET", let provider = control.routing?.provider(parsed.payload) {
            return provider.payload?.contains { $0.lowercased().contains(needle) } ?? false
        }
        return false
    }

    /// «1 правило», «3 правила», «5 правил».
    static func count(_ n: Int) -> String {
        let (tens, ones) = (n % 100, n % 10)
        if (11...14).contains(tens) || ones == 0 || ones >= 5 { return String(localized: "\(n) правил") }
        return ones == 1 ? String(localized: "\(n) правило") : String(localized: "\(n) правила")
    }

    /// Consecutive rules with the same target, kept in order: «Напрямую · 6», «Сервер · 1».
    struct Run: Identifiable {
        var id: String { "run-\(items[0].offset)" }
        var items: [(offset: Int, rule: RoutingReport.Rule)]
    }

    static func runs(_ rules: [RoutingReport.Rule]) -> [Run] {
        var result: [Run] = []
        for (offset, rule) in rules.enumerated() {
            let target = RoutingRule(rule.rule)?.target
            if let last = result.last?.items.last, RoutingRule(last.rule.rule)?.target == target {
                result[result.count - 1].items.append((offset, rule))
            } else {
                result.append(Run(items: [(offset, rule)]))
            }
        }
        return result
    }
}

private struct RuleRow: View {
    @Environment(KillSwitchControl.self) private var control
    let rule: RoutingReport.Rule
    let report: RoutingReport
    let search: String
    @State private var expanded = false

    var body: some View {
        let parsed = RoutingRule(rule.rule)
        if let parsed, parsed.type == "RULE-SET", let provider = report.provider(parsed.payload) {
            let open = expanded || !search.isEmpty
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    line(parsed, chevron: open)
                }
                .buttonStyle(.plain)
                .accessibilityHint(open ? "Свернуть набор" : "Показать набор")
                if open {
                    ProviderDetails(provider: provider, live: control.connections?.providers[provider.name], search: search)
                }
            }
        } else {
            line(parsed, chevron: nil)
        }
    }

    /// `chevron`: nil for a rule with nothing to show, else whether it is open.
    private func line(_ parsed: RoutingRule?, chevron: Bool?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(rule.index.map { String($0 + 1) } ?? "•")
                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary).frame(minWidth: 22, alignment: .trailing)
                .accessibilityLabel(rule.index.map { String(localized: "Правило \($0 + 1)") } ?? String(localized: "Твоё правило"))
            VStack(alignment: .leading, spacing: 2) {
                Text(parsed?.typeTitle ?? rule.rule).font(.callout)
                if let parsed, !parsed.payload.isEmpty {
                    Text(parsed.payloadText).font(parsed.isLogic ? .callout : .callout.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(3)
                }
            }
            Spacer(minLength: 8)
            if rule.from == .killswitch {
                Text("твоё").font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .help("Добавлено по твоему выбору в «Дополнительно», раньше правил подписки")
            }
            if rule.from == .profile {
                Text("профиль").font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .help(String(localized: "Из профиля маршрутизации «\(rule.profile ?? "")», раньше правил подписки"))
            }
            if let parsed, parsed.noResolve {
                Text("без DNS").font(.caption).foregroundStyle(.secondary)
                    .help("Ядро не узнаёт адрес сайта ради этого правила: оно сработает, только если соединение уже идёт на адрес")
            }
            if let chevron {
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(chevron ? 90 : 0)).accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct ProviderDetails: View {
    let provider: RoutingReport.Provider
    let live: CoreConnections.ProviderInfo?
    let search: String
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let host = provider.host {
                    LabeledContent("Откуда", value: host)
                }
                if let count = live?.count ?? provider.count {
                    LabeledContent("Записей", value: count.formatted())
                }
                if let updated = live.flatMap({ ISO8601DateFormatter().date(from: $0.updatedAt) }), updated.timeIntervalSince1970 > 0 {
                    LabeledContent("Обновлён") { Text(updated, format: .relative(presentation: .named)) }
                } else if provider.type == "http" {
                    LabeledContent("Обновлён", value: String(localized: "узнаю, когда VPN подключён"))
                }
                if let interval = provider.interval, interval > 0 {
                    LabeledContent("Обновляется", value: String(localized: "раз в \(Duration.seconds(interval).formatted(.units(allowed: [.days, .hours, .minutes], width: .wide)))"))
                }
                LabeledContent("Где", value: provider.typeTitle)
            }
            .font(.callout)
            if let payload = provider.payload, !payload.isEmpty {
                let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
                let shown = needle.isEmpty ? payload : payload.filter { $0.lowercased().contains(needle) }
                let limit = showAll ? shown.count : min(shown.count, 12)
                Text(shown.prefix(limit).joined(separator: "\n"))
                    .font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                if shown.count > limit {
                    Button(String(localized: "Показать все (\(shown.count))")) { showAll = true }.buttonStyle(.link)
                }
            } else if provider.type == "http" {
                Text("Содержимое ядро скачивает само, здесь видны только размер и время обновления.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 32).padding(.bottom, 2)
    }
}

private struct DroppedSection: View {
    let report: RoutingReport
    let dropped: [RoutingReport.Dropped]

    var body: some View {
        Section {
            ForEach(dropped.indices.map { ("dropped-\($0)", dropped[$0]) }, id: \.0) { _, item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.item).font(.callout.monospaced()).textSelection(.enabled).lineLimit(2)
                        Spacer()
                        Text(item.index.map { String(localized: "\(item.sectionTitle) \($0 + 1)") } ?? item.sectionTitle)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(item.reasonText).font(.callout).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            ForEach(report.tidied.indices.map { ("tidied-\($0)", report.tidied[$0]) }, id: \.0) { _, added in
                VStack(alignment: .leading, spacing: 2) {
                    Text(added.title).font(.callout)
                    Text(added.why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !added.lines.isEmpty {
                        Text(added.lines.joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Что не взято из подписки")
        } footer: {
            Text("Остальное из подписки работает как обычно: одно неподходящее правило не ломает весь импорт.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct AddedSection: View {
    let report: RoutingReport

    var body: some View {
        Section {
            ForEach(report.additions.indices.map { ("added-\($0)", report.additions[$0]) }, id: \.0) { _, added in
                AddedRow(added: added)
            }
        } header: {
            Text("Добавлено KillSwitch")
        } footer: {
            Text("Это механика приложения: она держит DNS и запасные серверы внутри VPN и не решает, какие сайты идут напрямую.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct AddedRow: View {
    let added: RoutingReport.Added
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label {
                Text(added.title).font(.callout.bold())
            } icon: {
                Image(systemName: Self.symbol(added.kind)).foregroundStyle(.tint)
            }
            Text(added.why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !added.lines.isEmpty {
                let limit = expanded ? added.lines.count : min(added.lines.count, 4)
                Text(added.lines.prefix(limit).joined(separator: "\n"))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                if added.lines.count > limit {
                    Button(String(localized: "Ещё \(added.lines.count - limit)")) { expanded = true }.buttonStyle(.link).font(.caption)
                }
            }
        }
        .padding(.vertical, 2)
    }

    static func symbol(_ kind: String) -> String {
        switch kind {
        case "dns-group", "dns-servers": "network.badge.shield.half.filled"
        case "pinning": "pin"
        case "overrides": "slider.horizontal.3"
        case "provider-proxy": "arrow.down.circle"
        case "sniffer": "eye"
        case "adblock": "hand.raised"
        case "doh": "lock.shield"
        case "hosts": "list.bullet.rectangle"
        case "splitapps": "app.badge"
        case "multihop": "point.3.connected.trianglepath.dotted"
        default: "plus.circle"
        }
    }
}

/// «Взято из подписки»: the sniffer and the DNS policy, with their values.
private struct TakenSection: View {
    let report: RoutingReport

    var body: some View {
        Section {
            if report.sniffer.from == .subscription {
                LabeledContent {
                    Text(report.sniffer.value.text).font(.caption.monospaced()).multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                } label: {
                    Text("Распознавание сайтов (sniffer)")
                    Text("Как в подписке")
                }
            }
            ForEach(report.dnsRows, id: \.key) { row in
                LabeledContent {
                    Text(row.value).font(.caption.monospaced()).multilineTextAlignment(.trailing).textSelection(.enabled)
                } label: {
                    Text(row.key).monospaced()
                    Text(Self.dnsTitle(row.key))
                }
            }
            LabeledContent {
                Text(report.dns.servers.joined(separator: "\n")).font(.caption.monospaced()).multilineTextAlignment(.trailing)
            } label: {
                Text("Остальные DNS-запросы")
                Text("KillSwitch, через VPN")
            }
        } header: {
            Text("DNS и распознавание сайтов")
        }
    }

    static func dnsTitle(_ key: String) -> String {
        switch key {
        case "direct-nameserver": String(localized: "DNS для сайтов, идущих напрямую")
        case "nameserver-policy": String(localized: "Свой DNS для отдельных сайтов")
        case "fake-ip-filter": String(localized: "Сайты с настоящими адресами")
        case "respect-rules": String(localized: "DNS-запросы идут по правилам")
        case "direct-nameserver-follow-policy": String(localized: "Прямой DNS следует политике")
        default: String(localized: "Из подписки")
        }
    }
}

// MARK: - «Соединения»

private struct ConnectionsTab: View {
    @Environment(KillSwitchControl.self) private var control
    @State private var search = ""
    @State private var kind: TrafficRoute.Kind?
    @State private var paused = false
    @State private var now = Date()

    var body: some View {
        VStack(spacing: 0) {
            if control.connectionsUnavailable {
                ContentUnavailableView {
                    Label("Список недоступен", systemImage: "arrow.triangle.2.circlepath")
                } description: {
                    Text("Служба защиты старше приложения. Обнови её в «Настройки › Защита», и соединения появятся здесь.")
                }
            } else if !control.coreRunning {
                ContentUnavailableView {
                    Label("VPN не подключён", systemImage: "lock.slash")
                } description: {
                    Text("Соединения видны, пока работает VPN KillSwitch.")
                }
            } else {
                header
                Divider()
                list
            }
        }
        .onAppear { control.watchConnections(!paused) }
        .onDisappear { control.watchConnections(false) }
        .onChange(of: paused) { _, value in control.watchConnections(!value) }
        .onChange(of: control.connections) { now = Date() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            SummaryBar(bytes: control.connections?.bytesByKind ?? [:])
            HStack(spacing: 10) {
                Picker("Показать", selection: $kind) {
                    Text("Все").tag(TrafficRoute.Kind?.none)
                    ForEach(TrafficRoute.Kind.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                SearchField(prompt: String(localized: "Программа, сайт, правило"), text: $search)
                Button {
                    paused.toggle()
                } label: {
                    Label(paused ? String(localized: "Продолжить") : String(localized: "Пауза"),
                          systemImage: paused ? "play.fill" : "pause.fill")
                }
                .help(paused ? "Снова обновлять каждую секунду" : "Остановить список, чтобы его рассмотреть")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var list: some View {
        let rows = control.connections?.filtered(kind: kind, search: search) ?? []
        return Table(rows) {
            TableColumn("Программа") { c in ProgramCell(connection: c) }
                .width(min: 80, ideal: 100)
            TableColumn("Куда") { c in
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.destination).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Text(c.network.uppercased() + (c.port.isEmpty ? "" : " · " + c.port))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .width(min: 100, ideal: 136)
            TableColumn("Правило") { c in
                let title = RoutingRule.title(type: CoreConnections.Connection.ruleType(c.rule))
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.rulePayload.isEmpty ? title : c.rulePayload).lineLimit(1).truncationMode(.middle)
                    if !c.rulePayload.isEmpty {
                        Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .help(c.ruleText)
                .accessibilityElement(children: .ignore).accessibilityLabel(c.ruleText)
            }
            .width(min: 70, ideal: 96)
            TableColumn("Маршрут") { c in
                RouteBadge(route: c.route, showLeaf: false).help(c.chains.reversed().joined(separator: " → "))
            }
            .width(min: 70, ideal: 96)
            TableColumn("↓ ↑") { c in
                VStack(alignment: .trailing, spacing: 1) {
                    Text("↓ " + Self.bytes(c.download))
                    Text("↑ " + Self.bytes(c.upload)).font(.caption).foregroundStyle(.secondary)
                }
                .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "Получено \(Self.bytes(c.download)), отправлено \(Self.bytes(c.upload))"))
            }
            .width(min: 60, ideal: 70)
            TableColumn("Время") { c in
                Text(Self.duration(c.duration(now: now))).monospacedDigit().foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 36, ideal: 44)
        }
        .overlay {
            if rows.isEmpty {
                Text(control.connections == nil ? String(localized: "Загружаю…") : String(localized: "Соединений нет"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: count)
    }

    /// «0:12», «30:05», «1:10:10».
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let tail = String(format: "%02d", s % 60)
        if s < 3600 { return "\(s / 60):\(tail)" }
        return "\(s / 3600):" + String(format: "%02d", s % 3600 / 60) + ":" + tail
    }
}

/// The program's icon (its app bundle) and name.
private struct ProgramCell: View {
    let connection: CoreConnections.Connection

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: ProgramIcons.icon(connection.bundlePath))
                .resizable().frame(width: 16, height: 16).accessibilityHidden(true)
            Text(name).lineLimit(1)
        }
        .help(connection.processPath)
    }

    private var name: String {
        if let path = connection.bundlePath { return FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "") }
        return connection.programName.isEmpty ? String(localized: "Неизвестно") : connection.programName
    }
}

@MainActor
private enum ProgramIcons {
    static var cache: [String: NSImage] = [:]
    static let generic = NSWorkspace.shared.icon(for: .unixExecutable)

    static func icon(_ bundle: String?) -> NSImage {
        guard let bundle else { return generic }
        if let image = cache[bundle] { return image }
        let image = NSWorkspace.shared.icon(forFile: bundle)
        cache[bundle] = image
        return image
    }
}

/// How the bytes of the open connections split between direct, VPN and blocked.
private struct SummaryBar: View {
    let bytes: [TrafficRoute.Kind: Int64]

    var body: some View {
        let total = max(1, bytes.values.reduce(0, +))
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(TrafficRoute.Kind.allCases, id: \.self) { kind in
                        let value = bytes[kind] ?? 0
                        if value > 0 {
                            RoundedRectangle(cornerRadius: 3).fill(RouteBadge.color(kind).gradient)
                                .frame(width: max(4, geo.size.width * CGFloat(value) / CGFloat(total)))
                        }
                    }
                    if bytes.values.reduce(0, +) == 0 {
                        RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.2))
                    }
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
            HStack(spacing: 16) {
                ForEach(TrafficRoute.Kind.allCases, id: \.self) { kind in
                    HStack(spacing: 5) {
                        Circle().fill(RouteBadge.color(kind)).frame(width: 8, height: 8).accessibilityHidden(true)
                        Text(kind.title)
                        Text(ConnectionsTab.bytes(bytes[kind] ?? 0)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                Spacer()
                Text("в открытых соединениях").foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }
}

// MARK: - «Проверить адрес»

private struct CheckAddressTab: View {
    @Environment(KillSwitchControl.self) private var control
    @State private var query = ""
    @State private var result: (target: String, result: AddressCheck.Result)?
    @State private var invalid = false
    /// The helper wrote the Xray report before ADR 0027: no rules to walk.
    @State private var outdated = false

    var body: some View {
        if let report = control.routing {
            Form {
                Section {
                    HStack {
                        TextField("Сайт или адрес", text: $query, prompt: Text(verbatim: "ya.ru, 77.88.8.8"))
                            .textFieldStyle(.roundedBorder).labelsHidden().font(.body.monospaced())
                            .onSubmit { run(report) }
                        Button("Проверить") { run(report) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if invalid {
                        StatusLabel("Это не похоже на сайт или IP-адрес", systemImage: "exclamationmark.triangle", tint: .orange)
                    }
                    if outdated {
                        StatusLabel("Ответа нет: служба KillSwitch старой версии не сохраняет правила для проверки. Обнови службу.",
                                    systemImage: "questionmark.circle", tint: .orange)
                    }
                } footer: {
                    Text("Проверка проходит правила так же, как ядро, для обычного открытия сайта: TCP, порт 443. Ничего не отправляется в сеть.")
                        .foregroundStyle(.secondary)
                }
                if let result {
                    verdict(result.target, result.result)
                }
            }
            .formStyle(.grouped)
            .onAppear { if !query.isEmpty, result == nil { run(report) } }
        } else {
            NoReport()
        }
    }

    private func run(_ report: RoutingReport) {
        guard let target = AddressCheck.Target(query) else { invalid = true; result = nil; return }
        invalid = false
        let geo = GeoData.bundled
        let context = AddressCheck.Context(providers: report.providers,
                                           geosite: { geo.site($0, contains: $1) },
                                           geoip: { geo.ip($0, inCountry: $1) })
        let answer = report.isXray ? AddressCheck.check(target, report: report, context: context)
                                   : AddressCheck.check(target, rules: report.rules.map(\.rule), context: context)
        outdated = answer == nil
        result = answer.map { (target.host ?? target.ip ?? query, $0) }
    }

    @ViewBuilder
    private func verdict(_ target: String, _ result: AddressCheck.Result) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: RouteBadge.symbol(result.route.kind)).font(.system(size: 30))
                        .foregroundStyle(RouteBadge.color(result.route.kind)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target).font(.callout.monospaced()).foregroundStyle(.secondary)
                        Text(Self.headline(result)).font(.title3.bold())
                    }
                }
                if case .vpn = result.route {
                    RouteBadge(route: result.route)
                }
                if let rule = result.rule, let position = result.position {
                    Text(String(localized: "Сработает \(number(position)): \(describe(rule))"))
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                } else if control.routing?.isXray == true {
                    Text("Ни одно правило не подходит: ядро отправит соединение так, как подписка велит по умолчанию.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Ни одно правило не подходит: ядро отправит соединение напрямую, как делает mihomo по умолчанию.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
        if !result.isExact {
            Section {
                ForEach(result.caveats, id: \.position) { caveat in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "\(number(caveat.position).capitalizedFirst): \(describe(caveat.rule))")).font(.callout).lineLimit(2)
                        Text(caveat.reason).font(.callout).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Label("Ответ приблизительный", systemImage: "questionmark.circle")
            } footer: {
                if control.routing?.isXray == true {
                    Text("Эти правила стоят выше и могут сработать раньше, но здесь их не проверить.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Эти правила стоят выше и могут сработать раньше, но здесь их не проверить. Точный ответ — во вкладке «Соединения», когда сайт открыт при подключённом VPN.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// «правило 9» as «Правила» numbers it (the subscription's order), «твоё правило» for KillSwitch's.
    private func number(_ position: Int) -> String { Self.number(position, control.routing) }

    static func number(_ position: Int, _ report: RoutingReport?) -> String {
        guard let rule = report?.rules[safe: position] else { return String(localized: "правило \(position + 1)") }
        return rule.index.map { String(localized: "правило \($0 + 1)") } ?? String(localized: "твоё правило")
    }

    /// Xray's rules are shown as the report writes them («domain=geosite:youtube → …»).
    private func describe(_ text: String) -> String { control.routing?.isXray == true ? text : Self.describe(text) }

    /// «Категория сайтов category-ru → Напрямую».
    static func describe(_ text: String) -> String {
        guard let rule = RoutingRule(text) else { return text }
        let what = rule.payload.isEmpty ? rule.typeTitle : "\(rule.typeTitle) \(rule.payloadText)"
        return "\(what) → \(RouteBadge.flagged(rule.route.title))"
    }

    static func headline(_ result: AddressCheck.Result) -> String {
        switch result.route.kind {
        case .direct: String(localized: "Напрямую, мимо VPN")
        case .vpn: String(localized: "Через VPN")
        case .block: String(localized: "Заблокировано")
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
