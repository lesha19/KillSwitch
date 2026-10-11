import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// «Настройки» (spec §5.4): four panes in the sidebar of the window. Lists and switches that let
/// traffic around the VPN are edited in a sheet and applied together, behind one password.
struct SettingsPaneView: View {
    let pane: SettingsPane

    var body: some View {
        switch pane {
        case .general: GeneralSettings()
        case .vpn: VPNSettings()
        case .protection: ProtectionSettings()
        case .advanced: AdvancedSettings()
        }
    }
}

/// A section's form: grouped, filling the window, scrolling when it is taller.
private struct SettingsForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
    }
}

/// A footnote kept to two lines; the rest behind «Подробнее».
private struct Footnote: View {
    let text: String
    var more: String?
    @State private var showingMore = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).foregroundStyle(.secondary).lineLimit(2)
            if let more {
                Spacer(minLength: 4)
                Button("Подробнее") { showingMore = true }
                    .buttonStyle(.link)
                    .popover(isPresented: $showingMore, arrowEdge: .bottom) {
                        Text(more).fixedSize(horizontal: false, vertical: true).frame(width: 320).padding()
                    }
            }
        }
    }
}

// MARK: Общие

private struct GeneralSettings: View {
    @Environment(KillSwitchControl.self) private var control
    @AppStorage("pauseShort") private var pauseShort = 5
    @AppStorage("pauseLong") private var pauseLong = 30
    @AppStorage("notifyVPNDropped") private var notifyVPNDropped = true
    @AppStorage("notifyPauseEnded") private var notifyPauseEnded = true
    @AppStorage("notifySubscription") private var notifySubscription = true
    @AppStorage("notifyServiceOff") private var notifyServiceOff = true

    var body: some View {
        SettingsForm {
            LaunchSection(control: control)
            Section("Уведомления") {
                Toggle("VPN оборвался и снова подключился", isOn: $notifyVPNDropped)
                Toggle("Подписка кончается или нужен ответ", isOn: $notifySubscription)
                Toggle("Пауза защиты закончилась", isOn: $notifyPauseEnded)
                Toggle("Защита или служба выключены", isOn: $notifyServiceOff)
            }
            SpeedSection()
            Section("Пауза защиты") {
                Stepper("Короткая: \(pauseShort) мин", value: $pauseShort, in: 1...60)
                Stepper("Длинная: \(pauseLong) мин", value: $pauseLong, in: 5...240, step: 5)
            }
        }
    }
}

/// «Запускать при входе», «Подключаться автоматически» and trusted Wi-Fi networks.
/// «Скорость в строке меню»: off by default; asks the core once a second only while connected.
private struct SpeedSection: View {
    @Environment(KillSwitchControl.self) private var control
    @AppStorage(KillSwitchControl.speedKey) private var showSpeed = false

    var body: some View {
        Section("Строка меню") {
            Toggle(isOn: $showSpeed) {
                Text("Скорость VPN в строке меню")
                Text("↓ загрузка и ↑ отдача через VPN, раз в секунду, пока VPN подключён.")
            }
            .onChange(of: showSpeed) { control.syncSpeed() }
            if showSpeed && control.speedUnavailable {
                Label("Служба на этом Mac не отдаёт скорость без пароля, поэтому её не видно.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct LaunchSection: View {
    @Bindable var control: KillSwitchControl
    @Environment(AutoConnector.self) private var auto
    @State private var newNetwork = ""

    var body: some View {
        @Bindable var auto = auto
        Section {
            Toggle(isOn: $control.launchAtLogin) {
                Text("Запускать при входе")
                if SMAppService.mainApp.status == .requiresApproval {
                    Text("Разреши KillSwitch в Системных настройках → Основные → Объекты входа.")
                }
            }
            Toggle(isOn: $auto.enabled) {
                Text("Подключаться автоматически")
                Text(control.coreConfigured ? String(localized: "В любой сети, после включения Mac и при смене сети. Пароль не спрашивается.")
                                            : String(localized: "Сначала добавь подписку или сервер."))
            }
            .disabled(!control.coreConfigured)
            Toggle(isOn: $auto.skipTrusted) {
                Text("Кроме доверенных сетей Wi-Fi")
                Text("Например, дома: там VPN не подключается сам, его можно отключить или поставить защиту на паузу. В остальных сетях VPN подключается всегда.")
            }
            .disabled(!auto.enabled)
            if auto.enabled && auto.skipTrusted {
                if auto.trustedNeedsLocation {
                    VStack(alignment: .leading, spacing: 6) {
                        Footnote(text: String(localized: "Без доступа к геопозиции macOS не называет сеть Wi-Fi, и все сети считаются недоверенными."),
                                 more: String(localized: "Поэтому VPN подключается в любой сети. Само местоположение KillSwitch не использует и никуда не отправляет."))
                        if auto.location == .notDetermined {
                            Button("Разрешить…") { auto.requestLocation() }
                        } else {
                            Button("Открыть настройки геопозиции") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                            }
                        }
                    }
                }
                ForEach(auto.trusted, id: \.self) { name in
                    HStack {
                        Label(name, systemImage: "wifi")
                        Spacer()
                        Button("Убрать") { auto.removeTrusted(name) }
                    }
                }
                if let ssid = auto.ssid {
                    if auto.trusted.contains(ssid) {
                        StatusLabel("Сейчас «\(ssid)» — доверенная сеть", systemImage: "house.fill", tint: .green)
                    } else {
                        Button("Добавить «\(ssid)»") { auto.addTrusted(ssid) }
                    }
                }
                HStack {
                    TextField("Имя сети Wi-Fi", text: $newNetwork).onSubmit(add)
                    Button("Добавить", action: add).disabled(newNetwork.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let last = auto.lastAction {
                Text(last).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Запуск")
        }
    }

    private func add() {
        auto.addTrusted(newNetwork)
        newNetwork = ""
    }
}

// MARK: VPN

private struct VPNSettings: View {
    @Environment(KillSwitchControl.self) private var control
    @Environment(VPNClient.self) private var client
    @AppStorage("showProfileGroups") private var showProfileGroups = false
    @State private var revealed: String?
    @State private var editing = false
    @State private var newURL = ""
    @State private var confirmRemove = false
    @State private var backupRevealed: String?
    @State private var editingBackup = false
    @State private var newBackupURL = ""
    @State private var addingServer = false
    @State private var editingApps = false

    var body: some View {
        @Bindable var client = client
        SettingsForm {
            Section("Подписка") {
                if client.hasURL && !editing {
                    LabeledContent("Ссылка") {
                        Text(revealed ?? client.maskedURL ?? "").monospaced().textSelection(.enabled)
                            .lineLimit(revealed == nil ? 1 : nil)
                    }
                    HStack {
                        Button(revealed == nil ? String(localized: "Показать") : String(localized: "Скрыть")) {
                            revealed = revealed == nil ? client.revealURL() : nil
                        }
                        Button("Изменить…") { editing = true; revealed = nil }
                        SubscriptionQRButton()
                        Spacer()
                        Button("Удалить…", role: .destructive) { confirmRemove = true }
                    }
                    SubscriptionSummary()
                } else {
                    HStack {
                        TextField("https://…", text: $newURL).onSubmit(saveURL)
                            .accessibilityLabel("Ссылка на подписку")
                        Button("Сохранить", action: saveURL).disabled(newURL.isEmpty)
                        QRScanButton()
                        if editing { Button("Отмена") { editing = false; newURL = "" } }
                    }
                }
                if client.hasURL {
                    BackupLinkRow(revealed: $backupRevealed, editing: $editingBackup, newURL: $newBackupURL)
                }
                Picker("Обновлять", selection: $client.intervalHours) {
                    Text("как просит подписка (\(Int(client.status.serverInterval / 3600)) ч)").tag(0)
                    ForEach([1, 3, 6, 12, 24, 48], id: \.self) { Text("каждые \($0) ч").tag($0) }
                }
            }

            Section("Свои серверы") {
                ForEach(client.manual) { server in
                    HStack {
                        ServerLabel(name: server.name)
                        Spacer()
                        Button("Убрать") { Task { await client.removeManual(server) } }
                    }
                }
                HStack { Button("Добавить сервер…") { addingServer = true }; QRScanButton() }
                if !client.hasURL, let error = client.lastError {
                    InlineError(error: error)
                }
            }

            Section("Маршруты") {
                LabeledContent {
                    Button("Открыть «Трафик»") { Router.shared.section = .traffic }
                } label: {
                    Text("Какие сайты идут напрямую")
                    Text("Решает подписка: KillSwitch берёт её правила как есть и ничего не добавляет от себя.")
                }
                MultihopRows()
                LabeledContent {
                    Button("Изменить…") { editingApps = true }
                } label: {
                    Text("Программы без VPN")
                    Text(control.splitApps.isEmpty ? String(localized: "Нет") : control.splitApps.joined(separator: ", "))
                }
                if let warning = SplitApps.writableWarning(SplitApps.userWritable(control.splitApps,
                                                                                  isWritable: FileManager.default.isWritableFile)) {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(control.busy || control.state == .notInstalled)

            CoreChoiceSection()

            Section("Вид") {
                Toggle("Показывать группы подписки в списке серверов", isOn: $showProfileGroups)
            }
        }
        .sheet(isPresented: $addingServer) { AddServerSheet() }
        .sheet(isPresented: $editingApps) { SplitAppsSheet() }
        .confirmationDialog("Удалить подписку?", isPresented: $confirmRemove) {
            Button("Удалить", role: .destructive) { revealed = nil; Task { await client.removeURL() } }
        } message: {
            Text("Ссылка удалится из связки ключей. VPN продолжит работать с последним списком серверов.")
        }
    }

    private func saveURL() {
        let value = newURL
        newURL = ""
        editing = false
        Task { await client.setURL(value) }
    }
}

/// «Способ подключения» (ADR 0020): the main way (Xray, the same as in Happ) or the fallback one
/// (mihomo, with the connections list). Switching asks the password once and takes the
/// subscription again in that way's format.
private struct CoreChoiceSection: View {
    @Environment(KillSwitchControl.self) private var control
    @Environment(VPNClient.self) private var client

    var body: some View {
        Section("Способ подключения") {
            Picker("Способ подключения", selection: Binding(get: { control.coreChoice }, set: { client.switchCore(to: $0) })) {
                Text("Основной — как в Happ").tag(CoreChoice.xray)
                Text("Запасной").tag(CoreChoice.mihomo)
            }
            .pickerStyle(.radioGroup).labelsHidden()
            .disabled(control.busy || client.updating || control.state == .notInstalled
                      || !FileManager.default.fileExists(atPath: CoreChoice.xray.binary))
            Footnote(text: String(localized: "Если сайты открываются через раз, попробуй другой способ. Смена спросит пароль и заново возьмёт подписку."),
                     more: String(localized: "Основной способ работает так же, как Happ. Запасной умеет показывать соединения в окне «Трафик» и двойной VPN, но у некоторых сайты в нём открываются хуже."))
        }
    }
}

/// «Резервная ссылка» (#11): asked when the main link fails, directly and then through the VPN.
private struct BackupLinkRow: View {
    @Environment(VPNClient.self) private var client
    @Binding var revealed: String?
    @Binding var editing: Bool
    @Binding var newURL: String

    var body: some View {
        if let masked = client.maskedBackupURL, !editing {
            LabeledContent("Резервная ссылка") {
                Text(revealed ?? masked).monospaced().textSelection(.enabled).lineLimit(revealed == nil ? 1 : nil)
            }
            HStack {
                Button(revealed == nil ? String(localized: "Показать") : String(localized: "Скрыть")) {
                    revealed = revealed == nil ? client.revealBackupURL() : nil
                }
                Button("Изменить…") { editing = true; revealed = nil }
                Spacer()
                Button("Убрать") { revealed = nil; client.removeBackupURL() }
            }
        } else {
            LabeledContent {
                HStack {
                    TextField("https://…", text: $newURL).onSubmit(save).accessibilityLabel("Резервная ссылка на подписку")
                    Button("Сохранить", action: save).disabled(newURL.isEmpty)
                    if editing { Button("Отмена") { editing = false; newURL = "" } }
                }
            } label: {
                Text("Резервная ссылка")
                Text("Если основная не открывается, KillSwitch возьмёт подписку по этой.")
            }
        }
    }

    private func save() {
        client.setBackupURL(newURL)
        newURL = ""
        editing = false
    }
}

/// «Двойной VPN» and its entry server: one line, flag and name (H4-4).
private struct MultihopRows: View {
    @Environment(KillSwitchControl.self) private var control
    @State private var pending: String?

    var body: some View {
        let exit = control.currentServer
        let candidates = Multihop.candidates(control.proxies?.servers ?? [], exit: exit)
        let entry = control.multihopEntry
        Toggle(isOn: Binding(get: { entry != nil },
                             set: { on in control.setMultihop(entry: on ? (pending ?? candidates.first) : nil) })) {
            Text("Двойной VPN")
            Text("Через два сервера: вход видит твой адрес, выход — сайты. Медленнее.")
        }
        .disabled(entry == nil && candidates.isEmpty)
        if candidates.isEmpty && entry == nil {
            Text(control.coreRunning ? String(localized: "Нужно хотя бы два сервера.") : String(localized: "Подключись, чтобы выбрать сервер входа."))
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Picker("Сервер входа", selection: Binding(
                get: { entry ?? pending ?? candidates.first ?? "" },
                set: { new in
                    pending = new
                    if entry != nil, new != entry { control.setMultihop(entry: new) }
                })) {
                if let entry, !candidates.contains(entry) { Text(ServerName.display(entry)).tag(entry) }
                ForEach(candidates, id: \.self) { Text(ServerName.display($0)).tag($0) }
            }
            if let entry, entry == exit {
                StatusLabel("Вход и выход — один и тот же сервер: выбери другой сервер входа.",
                            systemImage: "exclamationmark.triangle.fill", tint: .orange).font(.caption)
            }
        }
    }
}

/// «Добавить сервер…»: a share link or a WireGuard file.
private struct AddServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(VPNClient.self) private var client
    @State private var link = ""
    @State private var importingWireGuard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Добавить сервер").font(.headline)
            HStack {
                TextField("Ссылка (vless://, trojan://, ss://, …)", text: $link).onSubmit(add)
                    .accessibilityLabel("Ссылка на сервер")
                Button("Вставить") {
                    if let text = NSPasteboard.general.string(forType: .string) { link = text }
                }
            }
            Text("Ссылки и ключи хранятся в связке ключей. Сервер появится в списке с пометкой «свой».")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = client.lastError { InlineError(error: error) }
            HStack {
                Button("Файл WireGuard…") { importingWireGuard = true }
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Добавить…", action: add).keyboardShortcut(.defaultAction).disabled(link.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .fileImporter(isPresented: $importingWireGuard,
                      allowedContentTypes: [UTType(filenameExtension: "conf") ?? .plainText, .plainText]) { result in
            guard case .success(let url) = result else { return }
            Task {
                await client.importWireGuard(file: url)
                if client.lastError == nil { dismiss() }
            }
        }
    }

    private func add() {
        let value = link
        Task {
            await client.addLink(value)
            if client.lastError == nil { dismiss() }
        }
    }
}

// MARK: Защита

private struct ProtectionSettings: View {
    @Environment(KillSwitchControl.self) private var control
    @AppStorage("pauseShort") private var pauseShort = 5
    @AppStorage("pauseLong") private var pauseLong = 30
    @State private var confirmOff = false
    @State private var editingAccess = false

    var body: some View {
        SettingsForm {
            Section {
                LabeledContent("Статус") {
                    HStack {
                        Text(statusText)
                        switch control.state {
                        case .on:
                            Menu("Пауза") {
                                Button("\(pauseShort) мин") { control.pause(minutes: pauseShort) }
                                Button("\(pauseLong) мин") { control.pause(minutes: pauseLong) }
                                Button("До переподключения") { control.pauseUntilReconnect() }
                            }
                            .fixedSize()
                            Button("Выключить…") { confirmOff = true }
                        case .off, .paused:
                            Button("Включить") { control.turnOn() }
                        case .notInstalled, .unknown:
                            EmptyView()
                        }
                    }
                }
                Text("Интернет идёт только через VPN. Выключение и пауза спросят пароль.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Защита")
            }
            .disabled(control.busy || control.state == .notInstalled)

            Section {
                accessRow(String(localized: "Доступ к домашней сети (роутер, NAS, принтер, AirPlay)"), control.allowLAN)
                accessRow("Tailscale", control.allowTailscale)
                accessRow(String(localized: "Адреса сайтов через роутер, пока VPN выключен"), control.allowRouterDNS)
                accessRow(String(localized: "Отключать сеть при выключении Mac"), control.wifiGuard)
            } header: {
                HStack {
                    Text("Что можно без VPN")
                    Spacer()
                    Button("Изменить…") { editingAccess = true }
                        .disabled(control.busy || control.state == .notInstalled)
                }
            }

            FilterSection(filter: control.filter)
        }
        .sheet(isPresented: $editingAccess) { AccessSheet() }
        .alert("Выключить защиту без срока?", isPresented: $confirmOff) {
            Button("Пауза на \(pauseLong) минут") { control.pause(minutes: pauseLong) }
            Button("Выключить", role: .destructive) { control.turnOff() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Если VPN оборвётся, программы пойдут в интернет напрямую.")
        }
    }

    private var statusText: String {
        switch control.state {
        case .on: String(localized: "Включена")
        case .off: String(localized: "Выключена")
        case .paused(let until): String(localized: "Пауза до \(until.formatted(date: .omitted, time: .shortened))")
        case .notInstalled: String(localized: "Не установлена")
        case .unknown: String(localized: "Проверяю…")
        }
    }

    private func accessRow(_ title: String, _ on: Bool) -> some View {
        LabeledContent(title) {
            Image(systemName: on ? "checkmark" : "minus")
                .foregroundStyle(on ? Color.green : Color.secondary)
                .accessibilityLabel(on ? String(localized: "можно") : String(localized: "нельзя"))
        }
    }
}

/// «Что можно без VPN → Изменить…»: the switches as a draft, applied together.
private struct AccessSheet: View {
    @Environment(KillSwitchControl.self) private var control
    @State private var draft: [String: Bool] = [:]

    var body: some View {
        BatchSheet(title: String(localized: "Что можно без VPN"), changed: !draft.isEmpty && draft != control.switches,
                   apply: { control.setSwitches(draft) }) {
            Form {
                toggle("lan", String(localized: "Доступ к домашней сети"), String(localized: "Роутер, NAS, принтер, AirPlay — без VPN. AirDrop работает и без этого."))
                toggle("dns", String(localized: "Адреса сайтов через роутер"), String(localized: "Пока VPN выключен, роутер видит, какие сайты открывает Mac."))
                    .disabled(draft["lan"] == false)
                toggle("tailscale", "Tailscale", String(localized: "Связь между своими устройствами без VPN."))
                toggle("wifiguard", String(localized: "Отключать сеть при выключении Mac"), String(localized: "Wi-Fi и кабель включаются после загрузки, когда защита уже стоит."))
            }
            .formStyle(.grouped)
        }
        .onAppear { draft = control.switches }
    }

    private func toggle(_ key: String, _ title: String, _ hint: String) -> some View {
        Toggle(isOn: Binding(get: { draft[key] ?? false }, set: { draft[key] = $0 })) {
            Text(title)
            Text(hint)
        }
    }
}

/// Defence in depth: the macOS content filter, independent of the service's rules.
private struct FilterSection: View {
    let filter: FilterControl
    @State private var confirmRemove = false

    var body: some View {
        Section {
            HStack {
                StatusLabel(statusText, systemImage: symbol, tint: statusColor)
                Spacer()
                switch filter.status {
                case .notInstalled, .failed:
                    Button("Включить…") { filter.install() }
                case .on, .off:
                    Button("Удалить…") { confirmRemove = true }
                case .waitingForApproval:
                    Button("Открыть Системные настройки") { NSWorkspace.shared.open(SystemSettings.networkExtensions) }
                case .unknown:
                    EmptyView()
                }
            }
            Footnote(text: String(localized: "Второй уровень: macOS сама не выпустит программы мимо VPN."),
                     more: String(localized: "Даже если основную защиту кто-то снимет, macOS пропустит без VPN только домашнюю сеть, серверы VPN, Tailscale и адреса без VPN. Программы узнаются по подписи разработчика, а не по пути. Включается и выключается вместе с защитой. Видна в Системных настройках → Сеть → Фильтры."))
        } header: {
            Text("Защита macOS")
        }
        .confirmationDialog("Удалить защиту macOS?", isPresented: $confirmRemove) {
            Button("Удалить", role: .destructive) { filter.uninstall() }
        } message: {
            Text("Останется основная защита. Вернуть можно здесь же.")
        }
    }

    private var statusText: String {
        switch filter.status {
        case .unknown: String(localized: "Проверяю…")
        case .notInstalled: String(localized: "Не включена")
        case .waitingForApproval: String(localized: "Ждёт разрешения в Системных настройках")
        case .off, .on: String(localized: "Работает")
        case .failed: String(localized: "Не получилось включить")
        }
    }

    private var symbol: String {
        switch filter.status {
        case .on, .off: "checkmark.circle.fill"
        case .waitingForApproval, .failed: "exclamationmark.triangle.fill"
        default: "circle"
        }
    }

    private var statusColor: Color {
        switch filter.status {
        case .on, .off: .green
        case .failed, .waitingForApproval: .orange
        default: .secondary
        }
    }
}

// MARK: Дополнительно

private struct AdvancedSettings: View {
    @Environment(KillSwitchControl.self) private var control
    @State private var editingExceptions = false
    @State private var editingServers = false

    var body: some View {
        SettingsForm {
            Section {
                Text(control.exceptions.isEmpty ? String(localized: "Нет") : control.exceptions.joined(separator: ", "))
                    .monospaced().foregroundStyle(.secondary).lineLimit(3)
            } header: {
                HStack {
                    Text("Адреса без VPN")
                    Spacer()
                    Button("Изменить…") { editingExceptions = true }
                }
            }
            .disabled(control.busy || control.state == .notInstalled)

            Section {
                Text(control.manualServers.isEmpty ? String(localized: "Нет") : control.manualServers.joined(separator: ", "))
                    .monospaced().foregroundStyle(.secondary).lineLimit(3)
                Text("Нужны, только если ты пользуешься Happ или dropweb вместе с KillSwitch.").foregroundStyle(.secondary)
            } header: {
                HStack {
                    Text("Адреса серверов для других VPN-программ")
                    Spacer()
                    Button("Изменить…") { editingServers = true }
                }
            }
            .disabled(control.busy || control.state == .notInstalled)

            Section("Реклама и трекеры") {
                Toggle(isOn: Binding(get: { control.adBlock }, set: { control.set("adblock", $0) })) {
                    Text("Блокировать рекламу и трекеры")
                    Text("Только пока подключён VPN KillSwitch.")
                }
                .disabled(control.busy || control.state == .notInstalled)
                Footnote(text: String(localized: "Если какой-то сайт перестал работать, выключи и проверь снова."),
                         more: String(localized: "Адреса рекламы и трекеров берутся из списка, который лежит в самой программе (category-ads-all), и обновляются вместе с ней: VPN ничего не скачивает сам. Заблокированное не уходит никуда — ни через VPN, ни мимо него."))
            }

            TransportSection()

            Section("Старая схема с dropweb") {
                Toggle(isOn: Binding(get: { control.allowDirect }, set: { control.set("direct", $0) })) {
                    Text("Пускать dropweb мимо VPN (слабее защиты)")
                }
                .disabled(control.busy || control.state == .notInstalled)
                Footnote(text: String(localized: "Только если вместо KillSwitch подключается dropweb."),
                         more: String(localized: "dropweb сможет выходить на любые адреса, и любая программа может этим воспользоваться. Защита macOS ему не доверяет: пока его VPN не поднят, он доходит только до серверов VPN. Встроенному VPN это не нужно."))
            }

            ServiceSection()
        }
        .sheet(isPresented: $editingExceptions) {
            ListSheet(title: String(localized: "Адреса без VPN"), note: String(localized: "Программы смогут ходить на эти адреса без VPN."),
                      placeholder: String(localized: "Адрес, например 1.2.3.46 или 10.8.0.0/24"), original: control.exceptions,
                      apply: control.setExceptions)
        }
        .sheet(isPresented: $editingServers) {
            ListSheet(title: String(localized: "Адреса серверов для других VPN-программ"),
                      note: String(localized: "К этим адресам сможет подключиться любая программа. Серверы подписки сюда добавлять не нужно."),
                      placeholder: String(localized: "Адрес сервера"), original: control.manualServers,
                      apply: control.setManualServers)
        }
    }
}

/// «Подключение к серверу»: TLS fingerprint and multiplexing per server (Transport, ADR 0007).
private struct TransportSection: View {
    @Environment(VPNClient.self) private var client
    @State private var selected: String?

    var body: some View {
        let servers = client.transportServers
        Section {
            if servers.isEmpty {
                Text("В подписке нет серверов, у которых это можно менять.").foregroundStyle(.secondary)
            } else {
                let server = servers.first { $0.name == selected } ?? servers[0]
                let override = client.transportOverride(for: server.name) ?? .init()
                Picker("Сервер", selection: Binding(get: { server.name }, set: { selected = $0 })) {
                    ForEach(servers) { Text(ServerName.display($0.name)).tag($0.name) }
                }
                if server.canFingerprint {
                    Picker("Отпечаток TLS", selection: Binding(get: { override.fingerprint }, set: { value in
                        var o = override; o.fingerprint = value
                        Task { await client.setTransport(o, for: server.name) }
                    })) {
                        Text(Transport.fingerprintTitle(nil, subscription: server.fingerprint)).tag(String?.none)
                        ForEach(Transport.fingerprints, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                }
                if server.canMux {
                    Picker("Мультиплексирование", selection: Binding(get: { override.mux }, set: { value in
                        var o = override; o.mux = value
                        Task { await client.setTransport(o, for: server.name) }
                    })) {
                        Text(Transport.muxTitle(nil, subscription: server.mux)).tag(String?.none)
                        Text(Transport.muxTitle(Transport.off, subscription: nil)).tag(String?.some(Transport.off))
                        ForEach(Transport.muxProtocols, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                }
                Footnote(text: String(localized: "Меняй, только если сервер перестал подключаться. Трафик всё равно идёт только через VPN."),
                         more: String(localized: "Отпечаток TLS — каким браузером представляется подключение; иногда другой отпечаток проходит блокировку. Мультиплексирование работает, только если его поддерживает сервер (sing-mux): иначе сервер не подключится — верни «Как в подписке». Фрагментации TLS в ядре mihomo нет."))
            }
        } header: {
            Text("Подключение к серверу")
        }
        .disabled(client.updating)
    }
}

/// «Служба KillSwitch»: repair and removal, away from the main screen (H2-3, H5-3).
private struct ServiceSection: View {
    @Environment(KillSwitchControl.self) private var control
    @State private var confirmUninstall = false

    var body: some View {
        Section("Служба KillSwitch") {
            LabeledContent((control.daemonProblem ? String(localized: "Выключена") : String(localized: "Работает")) + String(localized: " · версия \(DeviceInfo.appVersion)")) {
                Button("Восстановить службу…") { control.install() }
            }
            HelperApprovalNote()
            ForEach(GeoDataInstall.problems(try? String(contentsOfFile: GeoDataInstall.path, encoding: .utf8)), id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Button("Удалить KillSwitch из системы…", role: .destructive) { confirmUninstall = true }
                .foregroundStyle(.red)
        }
        .disabled(control.busy || control.state == .notInstalled)
        .confirmationDialog("Удалить KillSwitch из системы?", isPresented: $confirmUninstall) {
            Button("Удалить", role: .destructive) { control.uninstall() }
        } message: {
            Text("VPN и защита будут удалены. Программы снова пойдут в интернет напрямую. Подписка останется в связке ключей.")
        }
    }
}

// MARK: Журнал защиты, О программе (the «Помощь» tab of 0.10)

/// «Журнал защиты»: what the protection did, newest first, and the diagnostics for support.
struct ProtectionLogView: View {
    @Environment(KillSwitchControl.self) private var control
    @Environment(VPNClient.self) private var client

    var body: some View {
        SettingsForm {
            Section {
                let entries = control.events.reversed().compactMap(ProtectionLog.entry)
                if entries.isEmpty {
                    Text("Пусто").foregroundStyle(.secondary)
                }
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.time).monospacedDigit().foregroundStyle(.secondary)
                        Text(entry.text).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                }
            } footer: {
                Text("Что происходило с защитой и VPN, новое сверху.").foregroundStyle(.secondary)
            }
            Section {
                Button("Скопировать диагностику") { DiagnosticsCopy.copy(control: control, client: client) }
                Text("Без ссылок, ключей и адресов серверов. Можно отправить в поддержку.").foregroundStyle(.secondary)
            }
        }
        .task { control.refreshEvents() }
    }
}

/// «О программе»: the version and updates, and tips on what can get around the protection.
struct AboutView: View {
    @Environment(Updater.self) private var updater

    var body: some View {
        SettingsForm {
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("KillSwitch").font(.title3.bold())
                        Text("Версия \(DeviceInfo.appVersion) (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer()
                    CheckForUpdatesButton(updater: updater)
                }
                Toggle(isOn: Binding(get: { updater.automaticallyUpdates }, set: { updater.automaticallyUpdates = $0 })) {
                    Text("Обновлять автоматически")
                    Text("KillSwitch ставит обновления сам, пока вы им не пользуетесь. VPN и защита при этом не прерываются.")
                }
            }
            NetworkHintsSection()
            Section("Советы") {
                LabeledContent("Выключи «Частный узел iCloud»: он может обходить защиту.") {
                    Button("Открыть настройки iCloud") {
                        NSWorkspace.shared.open(SystemSettings.iCloud)
                    }
                }
                LabeledContent("После обновления macOS перезагрузи Mac и запусти проверку утечек.") {
                    Button("Проверка утечек") { Router.shared.go(.leakTest) }
                }
            }
        }
    }
}

// MARK: «Изменить… → Применить…»

/// The frame of every batch sheet: the draft above, «Отмена» and «Применить…» below, one password
/// for everything (spec §5.4, H7-1).
private struct BatchSheet<Content: View>: View {
    let title: String
    let changed: Bool
    let apply: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
            HStack {
                Text("Спросит пароль один раз.").foregroundStyle(.secondary)
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Применить…") {
                    apply()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!changed)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// A list of addresses: add, remove, apply together.
private struct ListSheet: View {
    let title: String
    let note: String
    let placeholder: String
    let original: [String]
    let apply: ([String]) -> Void

    @State private var draft: [String] = []
    @State private var newItem = ""
    @State private var invalid = false

    var body: some View {
        BatchSheet(title: title, changed: draft != original, apply: { apply(draft) }) {
            Text(note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                if draft.isEmpty { Text("Пусто").foregroundStyle(.secondary) }
                ForEach(draft, id: \.self) { item in
                    HStack {
                        Text(item).monospaced()
                        Spacer()
                        Button("Убрать") { draft.removeAll { $0 == item } }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Убрать \(item)")
                    }
                }
            }
            .frame(height: 180)
            HStack {
                TextField(placeholder, text: $newItem).onSubmit(add)
                Button("Добавить", action: add).disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if invalid {
                StatusLabel("Нужен адрес IPv4 или IPv6, можно с маской: 10.8.0.0/24.",
                            systemImage: "exclamationmark.triangle.fill", tint: .orange).font(.caption)
            }
        }
        .onAppear { draft = original }
    }

    private func add() {
        guard let address = Batch.address(newItem) else { invalid = true; return }
        invalid = false
        if !draft.contains(address) { draft.append(address) }
        newItem = ""
    }
}

/// «Программы без VPN → Изменить…»: the user's own addition to the subscription's routing; the
/// helper lets the core out for them (ADR 0013).
private struct SplitAppsSheet: View {
    @Environment(KillSwitchControl.self) private var control
    /// Process name → app bundle path, to show the app's name and icon; local, not a setting.
    @AppStorage("splitAppPaths") private var pathsData = Data()
    @State private var draft: [String] = []

    var body: some View {
        let paths = (try? JSONDecoder().decode([String: String].self, from: pathsData)) ?? [:]
        BatchSheet(title: String(localized: "Программы без VPN"), changed: draft != control.splitApps,
                   apply: { control.setSplitApps(draft) }) {
            List {
                if draft.isEmpty { Text("Пусто").foregroundStyle(.secondary) }
                ForEach(draft, id: \.self) { name in
                    HStack {
                        if let path = paths[name] ?? (SplitApps.isPath(name) ? name : nil) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 18, height: 18)
                            Text(FileManager.default.displayName(atPath: path))
                        } else {
                            Image(systemName: "app").frame(width: 18)
                            Text(name)
                        }
                        Spacer()
                        Button("Убрать") { draft.removeAll { $0 == name } }.buttonStyle(.borderless)
                    }
                }
            }
            .frame(height: 180)
            HStack {
                Button("Добавить программы…", action: pick)
                Spacer()
            }
            Footnote(text: String(localized: "Эти программы ходят в интернет мимо VPN, остальные — через VPN."),
                     more: String(localized: "Программа узнаётся по месту, где она лежит: мимо VPN идут все её процессы, включая вспомогательные. Если программу перенести в другую папку, добавь её заново."))
        }
        .onAppear { draft = control.splitApps }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Добавить")
        panel.message = String(localized: "Программы, которые будут ходить в интернет мимо VPN")
        guard panel.runModal() == .OK else { return }
        var paths = (try? JSONDecoder().decode([String: String].self, from: pathsData)) ?? [:]
        var names: [String] = []
        for url in panel.urls {
            guard let info = Bundle(url: url)?.infoDictionary, let name = SplitApps.entry(bundle: url, infoPlist: info) else { continue }
            names.append(name)
            paths[name] = url.path
        }
        pathsData = (try? JSONEncoder().encode(paths)) ?? pathsData
        draft = SplitApps.adding(names, to: draft)
    }
}
