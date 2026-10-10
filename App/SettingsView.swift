import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            VPNSettings().tabItem { Label("VPN", systemImage: "network.badge.shield.half.filled") }
            AccessSettings().tabItem { Label("Что пропускать", systemImage: "checklist") }
            ServerSettings().tabItem { Label("Серверы VPN", systemImage: "network") }
            ExceptionSettings().tabItem { Label("Исключения", systemImage: "list.bullet") }
            CheckSettings().tabItem { Label("Проверка", systemImage: "checkmark.shield") }
            GeneralSettings().tabItem { Label("Общие", systemImage: "gearshape") }
        }
        .frame(width: 480)
    }
}

private struct AccessSettings: View {
    @Environment(KillSwitchControl.self) private var control

    var body: some View {
        Form {
            Section {
                toggle("Домашняя сеть", "Роутер, NAS, принтер, AirPlay.", key: "lan", value: control.allowLAN)
                toggle("Адреса сайтов через роутер", "Пока VPN выключен, Mac может узнавать адреса сайтов у роутера. Само содержимое не уходит, но видно, куда ходит Mac.", key: "dns", value: control.allowRouterDNS)
                    .disabled(!control.allowLAN)
                toggle("Сторонний клиент dropweb мимо VPN", "Только для старой схемы с dropweb вместо встроенного VPN: его ядро сможет выходить на любые адреса. Это слабее защиты: любая программа может запустить то ядро со своим конфигом. Фильтр macOS этому ядру не доверяет: пока туннель dropweb не поднят, оно доходит только до серверов VPN. Встроенному VPN это не нужно.", key: "direct", value: control.allowDirect)
                toggle("Отключать сеть при выключении Mac", "Wi-Fi, кабель и iPhone по USB отключаются при выключении Mac и включаются сами после загрузки, когда защита уже стоит. Так при загрузке ничего не утекает. Не спасает при внезапном выключении (сел аккумулятор, сбой).", key: "wifiguard", value: control.wifiGuard)
                toggle("Tailscale", "Связь между своими устройствами без VPN: напрямую (только системная служба Tailscale) и через ретрансляторы Tailscale вне дома. Фильтр macOS доверяет только подписанному приложению Tailscale (с сайта или из App Store); tailscaled из Homebrew без VPN доходит лишь до ретрансляторов.", key: "tailscale", value: control.allowTailscale)
            } footer: {
                Text("Каждое изменение спросит пароль.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(control.busy || control.state == .notInstalled)
    }

    private func toggle(_ title: String, _ hint: String, key: String, value: Bool) -> some View {
        Toggle(isOn: Binding(get: { value }, set: { control.set(key, $0) })) {
            Text(title)
            Text(hint)
        }
    }
}

private struct ServerSettings: View {
    @Environment(KillSwitchControl.self) private var control

    var body: some View {
        // found servers first, then ones that are allowed but no longer in any profile
        let rows = control.foundServers + control.servers.filter { !control.foundServers.contains($0) }
        Form {
            Section {
                if rows.isEmpty {
                    Text("Пусто. Серверы из подписки добавляются сами при каждом обновлении.").foregroundStyle(.secondary)
                }
                ForEach(rows, id: \.self) { server in
                    HStack {
                        Text(server).monospaced()
                        Spacer()
                        if control.servers.contains(server) {
                            Label("пропускается", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Button("Убрать", role: .destructive) { control.removeServer(server) }
                        } else {
                            Label("закрыт", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                        }
                    }
                }
                if control.foundServers.contains(where: { !control.servers.contains($0) }) {
                    Button("Пропускать найденные серверы") { control.allowFoundServers() }
                }
            } header: {
                Text("Серверы VPN")
            } footer: {
                Text("Без VPN доступны только эти адреса. Серверы встроенного VPN пропускаются сами при обновлении подписки. Здесь же видны серверы сторонних клиентов (Happ, dropweb), если они есть: к ним сможет подключиться любая программа. Изменения спросят пароль.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(control.busy || control.state == .notInstalled)
    }
}

private struct CheckSettings: View {
    @Environment(KillSwitchControl.self) private var control
    @Environment(VPNClient.self) private var client

    var body: some View {
        Form {
            Section {
                LeakTestView.OpenButton(title: "Открыть «Проверка утечек»…")
            } footer: {
                Text("Какой адрес видят сайты по IPv4 и IPv6 и кто узнаёт для тебя адреса сайтов (DNS).")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button(control.leakRunning ? "Проверяю…" : "Проверить утечку") { control.checkLeak() }
                    .disabled(control.leakRunning)
                ForEach(control.leakResults) { result in
                    if result.leaked {
                        Label("\(result.interface): утечка, интернет идёт мимо VPN", systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    } else {
                        Label("\(result.interface): защищено", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                if let ip = control.externalIP {
                    LabeledContent("Внешний адрес") { Text(ip).monospaced().textSelection(.enabled) }
                }
            } header: {
                Text("Утечка")
            } footer: {
                Text("Проверка пытается выйти в интернет напрямую через физические интерфейсы. Ответ значит утечку.")
                    .foregroundStyle(.secondary)
            }
            Section("События защиты") {
                if control.events.isEmpty {
                    Text("Пусто").foregroundStyle(.secondary)
                } else {
                    Text(control.events.joined(separator: "\n")).monospaced().font(.caption).textSelection(.enabled)
                }
            }
            Section {
                Button("Скопировать диагностику") { DiagnosticsCopy.copy(control: control, client: client) }
            } footer: {
                Text("Версия, состояние защиты и ядра, последние ошибки — без ссылок, ключей и адресов серверов. Можно отправить в поддержку.")
                    .foregroundStyle(.secondary)
            }
            Section("Советы") {
                Text("Выключи «Частный узел iCloud» (Private Relay): он может обходить фильтр.")
                Text("После каждого обновления macOS перезагрузи Mac и нажми проверку.")
                Text("Для полной защиты при загрузке выключай Wi-Fi перед выключением Mac.")
            }
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .task { control.refreshEvents() }
    }
}

private struct ExceptionSettings: View {
    @Environment(KillSwitchControl.self) private var control
    @State private var newAddress = ""

    var body: some View {
        Form {
            Section {
                if control.exceptions.isEmpty {
                    Text("Пусто").foregroundStyle(.secondary)
                }
                ForEach(control.exceptions, id: \.self) { address in
                    HStack {
                        Text(address).monospaced()
                        Spacer()
                        Button("Убрать", role: .destructive) { control.removeException(address) }
                    }
                }
                HStack {
                    TextField("Адрес, например 1.2.3.46 или 10.8.0.0/24", text: $newAddress)
                        .onSubmit(add)
                    Button("Добавить", action: add).disabled(newAddress.isEmpty)
                }
            } header: {
                Text("Всегда без VPN")
            } footer: {
                Text("Программы смогут ходить на эти адреса без VPN. Адреса серверов VPN добавляются на вкладке «Серверы VPN». Каждое изменение спросит пароль.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(control.busy || control.state == .notInstalled)
    }

    private func add() {
        control.addException(newAddress)
        newAddress = ""
    }
}

private struct GeneralSettings: View {
    @Environment(KillSwitchControl.self) private var control
    @AppStorage("pauseShort") private var pauseShort = 5
    @AppStorage("pauseLong") private var pauseLong = 30
    @AppStorage("notifyVPNDropped") private var notifyVPNDropped = true
    @AppStorage("notifyPauseEnded") private var notifyPauseEnded = true

    var body: some View {
        @Bindable var control = control
        Form {
            Section("Пауза") {
                Stepper("Короткая: \(pauseShort) мин", value: $pauseShort, in: 1...60)
                Stepper("Длинная: \(pauseLong) мин", value: $pauseLong, in: 5...240, step: 5)
            }
            Section("Уведомления") {
                Toggle("VPN отключился, интернет перекрыт", isOn: $notifyVPNDropped)
                Toggle("Пауза закончилась", isOn: $notifyPauseEnded)
            }
            AutoConnectSection(control: control)
            FilterSection(filter: control.filter)
        }
        .formStyle(.grouped)
    }
}

/// «Запускать при входе», «Подключаться автоматически» and trusted Wi-Fi networks.
private struct AutoConnectSection: View {
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
                Text("При запуске программы и при смене сети. Пароль не спрашивается: если он нужен, придёт уведомление. Ручное «Отключить» действует до следующей смены сети.")
            }
            .disabled(!control.coreConfigured)
            Toggle(isOn: $auto.skipTrusted) {
                Text("Не подключаться в доверенных сетях Wi-Fi")
                Text("Например, дома. В остальных сетях VPN подключается всегда.")
            }
            .disabled(!auto.enabled)
            if auto.enabled && auto.skipTrusted {
                if !auto.locationAllowed {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("macOS называет сеть Wi-Fi только программам с доступом к геопозиции. Пока доступа нет, все сети считаются недоверенными и VPN подключается всегда. Само местоположение KillSwitch не использует.", systemImage: "location.slash")
                            .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
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
                        Button("Убрать", role: .destructive) { auto.removeTrusted(name) }
                    }
                }
                if let ssid = auto.ssid, !auto.trusted.contains(ssid) {
                    Button("Добавить текущую сеть «\(ssid)»") { auto.addTrusted(ssid) }
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
            Text("Автоподключение")
        } footer: {
            if !control.coreConfigured {
                Text("Сначала добавь подписку или сервер.").foregroundStyle(.secondary)
            }
        }
    }

    private func add() {
        auto.addTrusted(newNetwork)
        newNetwork = ""
    }
}

/// Second layer: macOS content filter, independent of pf.
private struct FilterSection: View {
    let filter: FilterControl

    var body: some View {
        Section {
            HStack {
                Text(statusText).foregroundStyle(statusColor)
                Spacer()
                switch filter.status {
                case .notInstalled, .failed:
                    Button("Установить") { filter.install() }
                case .on, .off:
                    Button("Удалить", role: .destructive) { filter.uninstall() }
                case .waitingForApproval, .unknown:
                    EmptyView()
                }
            }
        } header: {
            Text("Второй слой: фильтр macOS")
        } footer: {
            Text("Отдельная от правил pf проверка внутри macOS. Пока VPN не подключён, пропускает только домашнюю сеть, серверы VPN, ретрансляторы Tailscale и исключения, а из программ — наше ядро VPN и приложение Tailscale, узнавая их по подписи разработчика, а не по пути, — даже если правила pf кто-то снял. Включается и выключается вместе с защитой. Виден в Системных настройках → Сеть → Фильтры.")
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        switch filter.status {
        case .unknown: "Проверяю…"
        case .notInstalled: "Не установлен"
        case .waitingForApproval: "Разреши в Системных настройках → Основные → Объекты входа и расширения → Сетевые расширения"
        case .off: "Установлен, выключен"
        case .on: "Работает"
        case .failed(let message): "Ошибка: \(message)"
        }
    }

    private var statusColor: Color {
        switch filter.status {
        case .on: .green
        case .failed, .waitingForApproval: .orange
        default: .secondary
        }
    }
}

/// Subscription, servers added by hand and routing of the built-in VPN.
private struct VPNSettings: View {
    @Environment(KillSwitchControl.self) private var control
    @Environment(VPNClient.self) private var client
    @State private var revealed: String?
    @State private var editing = false
    @State private var newURL = ""
    @State private var newLink = ""
    @State private var confirmRemove = false
    @State private var importingWireGuard = false

    var body: some View {
        @Bindable var client = client
        Form {
            Section {
                if client.hasURL && !editing {
                    LabeledContent("Ссылка") {
                        Text(revealed ?? client.maskedURL ?? "").monospaced().textSelection(.enabled)
                            .lineLimit(revealed == nil ? 1 : nil)
                    }
                    HStack {
                        Button(revealed == nil ? "Показать" : "Скрыть") {
                            revealed = revealed == nil ? client.revealURL() : nil
                        }
                        Button("Изменить…") { editing = true; revealed = nil }
                        Spacer()
                        Button("Удалить", role: .destructive) { confirmRemove = true }
                    }
                } else {
                    HStack {
                        SecureField("https://…", text: $newURL).onSubmit(saveURL)
                        Button("Сохранить", action: saveURL).disabled(newURL.isEmpty)
                        if editing { Button("Отмена") { editing = false; newURL = "" } }
                    }
                }
                Picker("Обновлять", selection: $client.intervalHours) {
                    Text("как просит подписка (\(Int(client.status.serverInterval / 3600)) ч)").tag(0)
                    ForEach([1, 3, 6, 12, 24, 48], id: \.self) { Text("каждые \($0) ч").tag($0) }
                }
                if client.hasURL {
                    SubscriptionSummary()
                }
            } header: {
                Text("Подписка")
            } footer: {
                Text("Ссылка хранится в связке ключей этого Mac. При обновлении сервер видит обезличенный номер этого Mac (для лимита устройств), версию macOS и модель. Если обновление не удалось, VPN продолжает работать со старым профилем.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if client.manual.isEmpty {
                    Text("Пусто").foregroundStyle(.secondary)
                }
                ForEach(client.manual) { server in
                    HStack {
                        ServerLabel(name: server.name)
                        Spacer()
                        Button("Убрать", role: .destructive) { Task { await client.removeManual(server) } }
                    }
                }
                HStack {
                    SecureField("vless://, trojan://, ss://, hysteria2://, tuic://, wireguard://", text: $newLink).onSubmit(addLink)
                        .accessibilityLabel("Ссылка на сервер")
                    Button("Добавить", action: addLink).disabled(newLink.isEmpty)
                }
                HStack {
                    Button("Вставить из буфера") { pasteFromClipboard() }
                        .help("Ссылки или текст файла WireGuard из буфера обмена, не показывая их на экране")
                    Button("Файл WireGuard…") { importingWireGuard = true }
                        .help("Файл .conf из WireGuard или от провайдера")
                }
                // with a subscription the summary above shows the same error
                if !client.hasURL, let error = client.lastError {
                    Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Свои серверы")
            } footer: {
                Text("Серверы по ссылкам и из файлов WireGuard появятся в списке отдельной группой «\(ProfileMerger.manualGroup)». Ссылки и ключи хранятся в связке ключей. DNS из файла WireGuard не используется: адреса узнаёт само ядро. Каждое изменение может спросить пароль.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: Binding(get: { control.coreDirect }, set: { control.set("coredirect", $0) })) {
                    Text("Прямой выход для российских сайтов")
                    Text("Российские сайты и адреса открываются напрямую, без VPN: быстрее и без капч, но провайдер видит, что ты на них заходишь. Остальное — через VPN. Спросит пароль.")
                }
                .disabled(control.busy || control.state == .notInstalled)
            } header: {
                Text("Маршрутизация")
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $importingWireGuard,
                      allowedContentTypes: [UTType(filenameExtension: "conf") ?? .plainText, .plainText]) { result in
            if case .success(let url) = result { Task { await client.importWireGuard(file: url) } }
        }
        .confirmationDialog("Удалить подписку?", isPresented: $confirmRemove) {
            Button("Удалить", role: .destructive) { revealed = nil; Task { await client.removeURL() } }
        } message: {
            Text("Ссылка удалится из связки ключей. Ядро продолжит работать с последним профилем, пока его не заменят.")
        }
    }

    private func saveURL() {
        let value = newURL
        newURL = ""
        editing = false
        Task { await client.setURL(value) }
    }

    private func addLink() {
        let value = newLink
        newLink = ""
        Task { await client.addLink(value) }
    }

    /// A wg-quick file is several lines, which a text field would flatten.
    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        Task { await client.addLink(text) }
    }
}
