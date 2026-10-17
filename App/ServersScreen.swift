import SwiftUI

/// «Сервер» (spec §5.2): a flat, searchable list inside the popover or the window. Works before
/// connecting too: the list then comes from the cached profile and the choice waits for
/// «Подключить». With «Двойной VPN» on, a segment picks the exit or the entry server.
struct ServersScreen: View {
    /// «‹ Назад» of the popover; nil in the window, where «Серверы» is a section of the sidebar.
    let back: (() -> Void)?

    @Environment(KillSwitchControl.self) private var control
    @Environment(VPNClient.self) private var client
    /// «Порядок»; before it a checkbox «По пингу» (`sortByLatency`), which still gives the default.
    @AppStorage("serverSort") private var sort: ServerPicker.Sort =
        UserDefaults.standard.bool(forKey: "sortByLatency") ? .ping : .subscription
    @AppStorage("showProfileGroups") private var showProfileGroups = false
    @AppStorage(VPNClient.favouritesKey) private var favouritesText = ""
    @AppStorage(ServerRecents.key) private var recentsText = ""
    @State private var query = ""
    /// «Фильтр»: for this visit of the list only, so a forgotten filter never hides servers later.
    @State private var filter = ServerPicker.Filter()
    @State private var highlighted: String?
    @State private var choosingEntry = false
    /// At most 1 s: Accessibility allows a double-click interval up to ~5 s, which would swallow
    /// a deliberate quick correction of a misclick.
    @State private var choice = ServerChoice(interval: min(NSEvent.doubleClickInterval, 1))
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            header
            if control.multihopEntry != nil {
                Picker("Конец цепочки", selection: $choosingEntry) {
                    Text("Выход").tag(false)
                    Text("Вход").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if showProfileGroups && !choosingEntry {
                ScrollView { ServerList() }.frame(minHeight: 300, maxHeight: 460)
            } else {
                TextField("Поиск", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .accessibilityLabel("Поиск сервера")
                if client.activeRemoved {
                    StatusLabel("Подписка, через которую ты подключён, удалена. Блокировка работает: выбери другой сервер.",
                                systemImage: "exclamationmark.triangle.fill", tint: .orange).font(.callout)
                }
                list
                HStack {
                    Picker("Порядок", selection: $sort) {
                        ForEach(ServerPicker.Sort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .help("Порядок серверов: как в подписке, быстрые сверху или по имени")
                    Spacer()
                    let options = filterOptions
                    if !options.isEmpty { filterMenu(options) }
                }
            }
        }
        .padding(12)
        .onAppear { searchFocused = true }
        .background {
            // ⌘F: back to the search field from the list
            Button("") { searchFocused = true }.keyboardShortcut("f").hidden()
        }
    }

    private var header: some View {
        HStack {
            if let back {
                Button(action: back) { Label("Назад", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .help("Назад (Esc)")
            } else {
                Color.clear.frame(width: 60, height: 1)   // keeps the title centred over ⟳
            }
            Spacer()
            // the window titles the section «Серверы» already
            if back != nil || choosingEntry {
                Text(choosingEntry ? String(localized: "Сервер входа") : String(localized: "Сервер")).font(.headline).accessibilityAddTraits(.isHeader)
            }
            Spacer()
            Button {
                Task { await control.testAllDelays() }
            } label: {
                if control.testing.contains(KillSwitchControl.allGroupsKey) {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(!control.coreRunning || control.proxies == nil || !control.testing.isEmpty)
            .help(control.coreRunning ? String(localized: "Проверить пинг всех серверов (⇧⌘P)") : String(localized: "Пинг проверяется при подключённом VPN"))
            .accessibilityLabel("Проверить пинг всех серверов")
            .frame(width: 60, alignment: .trailing)
        }
    }

    /// The profile the helper runs: the running core's, else its cache.
    private var proxies: CoreProxies? { control.proxies ?? client.profileProxies }

    /// One block per subscription, then «Свои серверы» (ADR 0036): the one the helper runs from
    /// the running core (its choice, its ping), the others from their caches. Choosing the entry
    /// of «Двойной VPN» lists that one alone.
    private var blocks: [(block: ServerPicker.Block, proxies: CoreProxies)] {
        client.blocks.compactMap { block in
            let active = block.id == client.activeID
            guard active || !choosingEntry else { return nil }
            let proxies = active && control.coreRunning ? control.proxies ?? block.proxies : block.proxies
            return (ServerPicker.Block(id: block.id, title: block.title, entries: entries(proxies, subscription: block.id)), proxies)
        }
    }

    @ViewBuilder private var list: some View {
        let blocks = blocks
        if !blocks.isEmpty {
            let all = blocks.flatMap(\.block.entries)
            let filtered = blocks.map { ServerPicker.Block(id: $0.block.id, title: $0.block.title,
                                                           entries: ServerPicker.filtered($0.block.entries, filter, proxies: $0.proxies)) }
            let list = ServerPicker.list(filtered, favourites: favourites, recents: recents, query: query, sort: sort, delays: delays(all))
            let current = current
            if list.blocks.isEmpty && list.favourites.isEmpty {
                empty(query.isEmpty && !filter.isOn ? String(localized: "В подписке нет серверов.") : String(localized: "Ничего не нашлось."))
            } else {
                List(selection: $highlighted) {
                    if !list.recents.isEmpty && !choosingEntry {
                        Section("Недавние") { ForEach(list.recents) { row($0, current: current, tag: Self.recentTag + $0.id, named: true) } }
                    }
                    if !list.favourites.isEmpty {
                        Section("Избранное") { ForEach(list.favourites) { row($0, current: current, named: true) } }
                    }
                    ForEach(list.blocks) { block in
                        Section {
                            if let fastest = block.fastest { row(fastest, current: current) }
                            ForEach(block.servers) { row($0, current: current) }
                        } header: {
                            blockHeader(block)
                        }
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 280, maxHeight: back == nil ? .infinity : 420)
                .contextMenu(forSelectionType: String.self) { ids in
                    if let entry = ids.first.flatMap({ id in all.first { $0.id == Self.id(fromTag: id) } }), !entry.isFastest {
                        Button(favourites.contains(entry.server) ? String(localized: "Убрать из избранного") : String(localized: "Добавить в избранное")) { toggleFavourite(entry) }
                    }
                } primaryAction: { ids in
                    if let id = ids.first.map(Self.id(fromTag:)), let entry = all.first(where: { $0.id == id }) { choose(entry) }
                }
            }
            if let error = control.coreError ?? (client.error(of: client.activeID) == nil ? client.lastError : nil) { InlineError(error: error) }
        } else if control.coreRunning, let error = control.proxiesError {
            InlineError(error: error)
            // `ks core restart` needs the VPN on (ADR 0035)
            if control.vpnOn { Button("Перезапустить VPN") { control.restartCore() } }
        } else if control.coreRunning {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Загружаю список серверов…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            empty(String(localized: "Список появится после первого обновления подписки."))
        }
    }

    /// A block's title, its refresh and, where the core runs, its ping; a failed refresh shows here only
    /// (the servers stay as they were).
    @ViewBuilder private func blockHeader(_ block: ServerPicker.List.Block) -> some View {
        let subscription = client.subscriptions.first { $0.id == block.id }
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(verbatim: block.title)
                Spacer()
                if let subscription {
                    Button {
                        Task { await client.update(subscription.id, interactive: true) }
                    } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .disabled(client.updating)
                        .help("Обновить эту подписку")
                        .accessibilityLabel("Обновить подписку \(block.title)")
                }
                if block.id == client.activeID {
                    Button { Task { await control.testAllDelays() } } label: { Image(systemName: "speedometer") }
                        .buttonStyle(.borderless)
                        .disabled(!control.coreRunning || control.proxies == nil || !control.testing.isEmpty)
                        .help("Проверить пинг серверов этой подписки")
                        .accessibilityLabel("Проверить пинг серверов \(block.title)")
                }
            }
            if let error = client.error(of: block.id) {
                StatusLabel(error.title, systemImage: "exclamationmark.triangle.fill", tint: .red).font(.caption).textCase(nil)
            }
        }
    }

    /// What the filter offers over all blocks.
    private var filterOptions: ServerPicker.FilterOptions {
        var options = ServerPicker.FilterOptions(countries: [], protocols: [], groups: [])
        for (block, proxies) in blocks {
            let more = ServerPicker.filterOptions(block.entries, proxies: proxies)
            options.countries += more.countries.filter { !options.countries.contains($0) }
            options.protocols += more.protocols.filter { !options.protocols.contains($0) }
            options.groups += more.groups.filter { !options.groups.contains($0) }
        }
        return options
    }

    /// Country, protocol, group: each only when the list has more than one.
    private func filterMenu(_ options: ServerPicker.FilterOptions) -> some View {
        let summary = [filter.country, filter.protocolName, filter.group].compactMap { $0 }.joined(separator: ", ")
        return Menu {
            if !options.countries.isEmpty {
                Picker("Страна", selection: $filter.country) {
                    Text("Любая").tag(String?.none)
                    ForEach(options.countries, id: \.self) { Text(verbatim: $0).tag(String?.some($0)) }
                }
            }
            if !options.protocols.isEmpty {
                Picker("Протокол", selection: $filter.protocolName) {
                    Text("Любой").tag(String?.none)
                    ForEach(options.protocols, id: \.self) { Text(verbatim: $0).tag(String?.some($0)) }
                }
            }
            if !options.groups.isEmpty {
                Picker("Группа", selection: $filter.group) {
                    Text("Любая").tag(String?.none)
                    ForEach(options.groups, id: \.self) { Text(verbatim: $0).tag(String?.some($0)) }
                }
            }
            if filter.isOn {
                Divider()
                Button("Сбросить фильтр") { filter = .init() }
            }
        } label: {
            Label(filter.isOn ? summary : String(localized: "Фильтр"),
                  systemImage: filter.isOn ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Показать только серверы одной страны, протокола или группы")
        .accessibilityLabel(filter.isOn ? String(localized: "Фильтр: \(summary)") : String(localized: "Фильтр"))
    }

    private func empty(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
    }

    /// A server is in «Недавние» and again below: its row there has a tag of its own.
    private static let recentTag = "\u{1}recent:"

    private static func id(fromTag tag: String) -> String {
        tag.hasPrefix(recentTag) ? String(tag.dropFirst(recentTag.count)) : tag
    }

    /// `named`: the row says whose server it is («Недавние», «Избранное»).
    private func row(_ entry: ServerPicker.Entry, current: ServerID?, tag: String? = nil, named: Bool = false) -> some View {
        let block = client.blocks.first { $0.id == entry.subscription }
        let active = entry.subscription == client.activeID
        return ServerPickerRow(entry: entry, current: entry.server == current, favourite: favourites.contains(entry.server),
                               subscription: named ? block?.title : nil, description: block?.proxies.serverDescription(of: entry.name),
                               ping: active ? ping(entry) : .unknown, leaf: entry.isFastest && active ? proxies?.leaf(of: entry.name) : nil,
                               choose: { choose(entry) }, toggleFavourite: { toggleFavourite(entry) })
            .tag(tag ?? entry.id)
    }

    /// The exit list is the whole picker but the entry (ADR 0027); the entry list has servers only,
    /// never the exit. Both only in the subscription the helper runs.
    private func entries(_ proxies: CoreProxies, subscription: String) -> [ServerPicker.Entry] {
        let all = ServerPicker.entries(proxies, subscription: subscription)
        guard subscription == client.activeID else { return all }
        guard choosingEntry else {
            let exits = Set(Multihop.exits(all.map(\.name), entry: control.multihopEntry))
            return all.filter { exits.contains($0.name) }
        }
        let candidates = Set(Multihop.candidates(all.filter { !$0.isFastest }.map(\.name), exit: control.currentServer))
        return all.filter { candidates.contains($0.name) }
    }

    private var current: ServerID? {
        if choosingEntry { return control.multihopEntry.map { ServerID(subscription: client.activeID, name: $0) } }
        if control.coreRunning, let proxies = control.proxies {
            return ServerPicker.selected(proxies).map { ServerID(subscription: client.activeID, name: $0) }
        }
        return control.pendingChoice?.server
    }

    private func choose(_ entry: ServerPicker.Entry) {
        guard choice.accept() else { return }
        if choosingEntry {
            control.setMultihop(entry: entry.name)
        } else {
            Task { await client.choose(entry) }   // «Недавние» once it is chosen
            back?()
        }
    }

    private func ping(_ entry: ServerPicker.Entry) -> ServerPicker.Ping {
        ServerPicker.Ping(delay: control.delay(of: entry.name), timedOut: control.timedOut(entry.name))
    }

    /// Known only for the subscription the core runs.
    private func delays(_ entries: [ServerPicker.Entry]) -> [ServerID: Int] {
        var result: [ServerID: Int] = [:]
        for entry in entries where entry.subscription == client.activeID {
            if let delay = control.delay(of: entry.name) {
                result[entry.server] = delay
            } else if control.timedOut(entry.name) {
                result[entry.server] = CoreDelay.timeout
            }
        }
        return result
    }

    /// Each subscription's server name → identity.
    private var keys: [String: [String: String]] {
        Dictionary(client.blocks.map { ($0.id, $0.keys) }, uniquingKeysWith: { a, _ in a })
    }

    /// The favourites now: kept by (subscription, identity), so a rename keeps them.
    private var favourites: Set<ServerID> {
        Set(ServerRecents.servers(ServerRecents.list(favouritesText), keys: keys))
    }

    private var recents: [ServerID] {
        ServerRecents.servers(ServerRecents.list(recentsText), keys: keys)
    }

    private func toggleFavourite(_ entry: ServerPicker.Entry) {
        favouritesText = ServerRecents.text(ServerRecents.toggled(entry.server, keys: keys[entry.subscription] ?? [:],
                                                                  in: ServerRecents.list(favouritesText)))
    }
}

private struct ServerPickerRow: View {
    let entry: ServerPicker.Entry
    let current: Bool
    let favourite: Bool
    /// Whose server it is, in «Недавние» and «Избранное» (ADR 0036).
    let subscription: String?
    /// The subscription's few words about the server (ServerDescription), under the name.
    let description: String?
    let ping: ServerPicker.Ping
    /// The server «Самый быстрый» goes through now.
    let leaf: String?
    let choose: () -> Void
    let toggleFavourite: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: current ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(current ? Color.accentColor : .secondary)
                .accessibilityHidden(true)
            if entry.isFastest {
                Image(systemName: "bolt.fill").foregroundStyle(.secondary).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).lineLimit(1)
                if let subscription {
                    Text(verbatim: subscription).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let description {
                    Text(verbatim: description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let leaf, let flag = ServerName(leaf).flag { Text(flag).accessibilityHidden(true) }
            PingView(ping: ping)
            if !entry.isFastest && (hovering || favourite) {
                Button(action: toggleFavourite) {
                    Image(systemName: favourite ? "star.fill" : "star").foregroundStyle(favourite ? .yellow : .secondary)
                }
                .buttonStyle(.borderless)
                .help(favourite ? String(localized: "Убрать из избранного") : String(localized: "Добавить в избранное"))
                .accessibilityLabel(favourite ? String(localized: "Убрать из избранного") : String(localized: "Добавить в избранное"))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: choose)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenName)
        .accessibilityValue([ping.spoken, current ? String(localized: "выбран") : "", favourite ? String(localized: "в избранном") : ""]
            .filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(current ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint("Подключиться через этот сервер")
        .accessibilityAction(named: favourite ? String(localized: "Убрать из избранного") : String(localized: "Добавить в избранное"), toggleFavourite)
    }

    /// «Литва, свой, Netflix и YouTube»: the name without emoji, then the description.
    private var spokenName: String {
        guard !entry.isFastest else { return ServerPicker.fastestTitle }
        var parts = [ServerName.spoken(entry.name)]
        if entry.own { parts[0] += String(localized: ", свой") }
        if let subscription { parts.append(subscription) }
        if let description { parts.append(description) }
        return parts.joined(separator: ", ")
    }
}

/// «37 мс» with signal bars: three when fast, one when slow, none without an answer — the shape
/// carries the meaning, the colour only helps (spec §9.3). Without a test result nothing is drawn
/// (with Xray the result is the observatory's last probe, ADR 0023). VoiceOver reads the number, not the bars.
struct PingView: View {
    let ping: ServerPicker.Ping

    var body: some View {
        if let bars = ping.bars {
            HStack(spacing: 3) {
                PingBars(lit: bars, color: color)
                Text(ping.text).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ping.spoken)
        }
    }

    private var color: Color {
        switch ping {
        case .fast: .green
        case .medium: .orange
        case .slow, .noAnswer: .red
        case .unknown: .secondary
        }
    }
}

/// Three rising bars, `lit` of them filled; the rest stay as faint outlines of the shape.
private struct PingBars: View {
    let lit: Int
    let color: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(1...ServerPicker.Ping.maxBars, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 1)
                    .fill(bar <= lit ? AnyShapeStyle(color) : AnyShapeStyle(.quaternary))
                    .frame(width: 3, height: 4 + 3 * CGFloat(bar))
            }
        }
        .frame(height: 13, alignment: .bottom)
        .accessibilityHidden(true)
    }
}
