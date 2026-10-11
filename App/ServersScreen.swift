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
    @State private var query = ""
    @State private var highlighted: String?
    @State private var choosingEntry = false
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
                list
                Picker("Порядок", selection: $sort) {
                    ForEach(ServerPicker.Sort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Порядок серверов: как в подписке, быстрые сверху или по имени")
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

    private var proxies: CoreProxies? { control.proxies ?? client.profileProxies }

    @ViewBuilder private var list: some View {
        if let proxies {
            let all = entries(proxies)
            let sections = ServerPicker.sections(all, favourites: favourites, query: query, sort: sort,
                                                 delays: delays(all))
            let current = choosingEntry ? control.multihopEntry : currentName(proxies)
            if sections.fastest == nil && sections.favourites.isEmpty && sections.all.isEmpty {
                empty(query.isEmpty ? String(localized: "В подписке нет серверов.") : String(localized: "Ничего не нашлось."))
            } else {
                List(selection: $highlighted) {
                    if let fastest = sections.fastest {
                        row(fastest, current: current)
                    }
                    if !sections.favourites.isEmpty {
                        Section("Избранные") { ForEach(sections.favourites) { row($0, current: current) } }
                    }
                    Section("Все") { ForEach(sections.all) { row($0, current: current) } }
                }
                .listStyle(.inset)
                .frame(minHeight: 280, maxHeight: back == nil ? .infinity : 420)
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first {
                        Button(favourites.contains(id) ? String(localized: "Убрать из избранного") : String(localized: "Добавить в избранное")) { toggleFavourite(id) }
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let entry = all.first(where: { $0.id == id }) { choose(entry) }
                }
            }
            if let error = control.coreError { InlineError(error: error) }
        } else if control.coreRunning, let error = control.proxiesError {
            InlineError(error: error)
            Button("Перезапустить VPN") { control.restartCore() }
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

    private func empty(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
    }

    private func row(_ entry: ServerPicker.Entry, current: String?) -> some View {
        ServerPickerRow(entry: entry, current: entry.name == current, favourite: favourites.contains(entry.name),
                        ping: ping(entry), leaf: entry.isFastest ? proxies?.leaf(of: entry.name) : nil,
                        choose: { choose(entry) }, toggleFavourite: { toggleFavourite(entry.name) })
            .tag(entry.id)
    }

    /// The exit list is the whole picker; the entry list has servers only, never the exit.
    private func entries(_ proxies: CoreProxies) -> [ServerPicker.Entry] {
        let all = ServerPicker.entries(proxies)
        guard choosingEntry else { return all }
        let candidates = Set(Multihop.candidates(all.filter { !$0.isFastest }.map(\.name), exit: control.currentServer))
        return all.filter { candidates.contains($0.name) }
    }

    private func currentName(_ proxies: CoreProxies) -> String? {
        if control.coreRunning, control.proxies != nil { return ServerPicker.selected(proxies) }
        return control.pendingChoice?.name
    }

    private func choose(_ entry: ServerPicker.Entry) {
        if choosingEntry {
            control.setMultihop(entry: entry.name)
        } else {
            control.choose(entry)
            back?()
        }
    }

    private func ping(_ entry: ServerPicker.Entry) -> ServerPicker.Ping {
        ServerPicker.Ping(delay: control.delay(of: entry.name), timedOut: control.timedOut(entry.name))
    }

    private func delays(_ entries: [ServerPicker.Entry]) -> [String: Int] {
        var result: [String: Int] = [:]
        for entry in entries {
            if let delay = control.delay(of: entry.name) { result[entry.name] = delay } else if control.timedOut(entry.name) { result[entry.name] = CoreDelay.timeout }
        }
        return result
    }

    /// Names of the favourites now: they are kept by server identity, so a rename keeps them.
    private var favourites: Set<String> {
        ServerIdentity.names(favouritesText.split(separator: "\n").map(String.init), keys: client.serverKeys)
    }

    private func toggleFavourite(_ name: String) {
        let key = client.serverKeys[name] ?? name
        var list = favouritesText.split(separator: "\n").map(String.init)
        if list.contains(key) || list.contains(name) { list.removeAll { $0 == key || $0 == name } } else { list.append(key) }
        favouritesText = list.joined(separator: "\n")
    }
}

private struct ServerPickerRow: View {
    let entry: ServerPicker.Entry
    let current: Bool
    let favourite: Bool
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
            Text(entry.title).lineLimit(1)
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
        .accessibilityLabel(entry.isFastest ? ServerPicker.fastestTitle : ServerName.spoken(entry.name) + (entry.own ? String(localized: ", свой") : ""))
        .accessibilityValue([ping.spoken, current ? String(localized: "выбран") : "", favourite ? String(localized: "в избранном") : ""]
            .filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(current ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint("Подключиться через этот сервер")
        .accessibilityAction(named: favourite ? String(localized: "Убрать из избранного") : String(localized: "Добавить в избранное"), toggleFavourite)
    }
}

/// «37 мс» with signal bars: three when fast, one when slow, none without an answer — the shape
/// carries the meaning, the colour only helps (spec §9.3).
struct PingView: View {
    let ping: ServerPicker.Ping

    var body: some View {
        if let bars = ping.bars {
            HStack(spacing: 3) {
                Image(systemName: "cellularbars", variableValue: bars)
                    .foregroundStyle(color)
                    .imageScale(.small)
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
