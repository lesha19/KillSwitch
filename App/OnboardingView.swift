import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// «Начало работы» (spec §4): a fixed 520×440 sheet of the main window with step dots. Opens by
/// itself on a Mac without the service and by «Начать настройку…» / «Добавить подписку…»; can be
/// closed anytime (✕, Esc on the first step).
struct OnboardingView: View {
    @Environment(KillSwitchControl.self) private var control
    @Environment(\.dismiss) private var dismiss
    @Environment(VPNClient.self) private var client
    @State private var steps: [Onboarding.Step] = []
    @State private var index = 0

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch steps.isEmpty ? .welcome : steps[index] {
                case .welcome: WelcomeStep(later: Array(steps.dropFirst()), next: next)
                case .subscription: SubscriptionStep(back: back, next: next)
                case .install: InstallStep(back: back, next: next)
                case .filter: FilterStep(next: next)
                case .done: DoneStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 12)
            dots.padding(.bottom, 16)
        }
        .frame(width: 520, height: 440)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(10)
            .help("Закрыть. Настройку можно продолжить кнопкой на главном экране.")
            .accessibilityLabel("Закрыть")
        }
        .onExitCommand { dismiss() }
        .onAppear(perform: start)
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(steps.indices, id: \.self) { i in
                Circle()
                    .fill(i == index ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Шаг \(index + 1) из \(steps.count)")
    }

    private func start() {
        guard steps.isEmpty else { return }
        steps = Onboarding.steps(installed: control.serviceInstalled, hasServers: control.coreConfigured,
                                 filterOn: control.filter.status == .on || control.filter.status == .off)
        index = 0
    }

    private func next() { if index + 1 < steps.count { index += 1 } }
    private func back() { if index > 0 { index -= 1 } }
}

/// Title and the text under it, the same on every step.
private struct StepHeader: View {
    let title: String
    let text: String
    var badge: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                if let badge {
                    Text(badge).font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.green.opacity(0.12), in: Capsule())
                }
            }
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WelcomeStep: View {
    let later: [Onboarding.Step]
    let next: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 64)).foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Интернет только через VPN").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text("KillSwitch подключает VPN и не выпускает программы в интернет мимо него — даже если VPN оборвётся.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Что будет дальше:").font(.headline)
                ForEach(Array(items.enumerated()), id: \.offset) { number, item in
                    HStack(spacing: 10) {
                        Text("\(number + 1)").font(.callout.monospacedDigit().bold()).foregroundStyle(.secondary).frame(width: 14)
                        Text(item)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Начать", action: next).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
    }

    private var items: [String] {
        later.compactMap {
            switch $0 {
            case .subscription: String(localized: "Ссылка на подписку")
            case .install: String(localized: "Установка (пароль Mac — один раз)")
            case .filter: String(localized: "Защита macOS (по желанию)")
            case .welcome, .done: nil
            }
        }
    }
}

private struct SubscriptionStep: View {
    let back: () -> Void
    let next: () -> Void

    @Environment(KillSwitchControl.self) private var control
    @Environment(VPNClient.self) private var client
    @Environment(LeakTester.self) private var leakTester
    @State private var text = ""
    @State private var found: Onboarding.Found?
    @State private var importingWireGuard = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(title: String(localized: "Ссылка на подписку"), text: String(localized: "Её даёт VPN-сервис: в боте или личном кабинете."))
            if let found, found.ready {
                HStack {
                    Text(client.maskedURL ?? "").monospaced().lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Изменить") { self.found = nil; fieldFocused = true }
                }
                StatusLabel(found.line(), systemImage: "checkmark.circle.fill", tint: .green)
            } else {
                HStack {
                    TextField("https://…", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .focused($fieldFocused)
                        .onSubmit(check)
                        .accessibilityLabel("Ссылка на подписку")
                    if text.isEmpty {
                        Button("Вставить", action: paste)
                    } else {
                        Button("Проверить", action: check).disabled(client.updating)
                    }
                }
                if client.updating {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Проверяю ссылку…").foregroundStyle(.secondary)
                    }
                } else if let error = client.lastError {
                    Label {
                        Text(error.title).bold() + Text(" " + error.message)
                    } icon: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Text("Есть только ссылка на сервер (vless://…)? Вставь её в это же поле.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Файл WireGuard…") { importingWireGuard = true }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Назад", action: back).keyboardShortcut(.cancelAction)
                Button("Далее", action: next)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(found?.ready != true)
            }
        }
        .onAppear {
            found = client.found
            fieldFocused = found == nil
            rememberHome()
        }
        .fileImporter(isPresented: $importingWireGuard,
                      allowedContentTypes: [UTType(filenameExtension: "conf") ?? .plainText, .plainText]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            Task { found = await client.check(text) }
        }
    }

    private func paste() {
        guard let value = NSPasteboard.general.string(forType: .string), !value.isEmpty else { return }
        text = value
        check()
    }

    private func check() {
        let value = text
        Task {
            found = await client.check(value)
            if found?.ready == true { text = "" }
        }
    }

    /// While nothing is installed the internet goes directly: the leak test learns the provider's
    /// address now, to recognise it later (spec §4, С6).
    private func rememberHome() {
        guard !control.serviceInstalled, !control.vpnUp, leakTester.home == nil, !leakTester.running else { return }
        Task { await leakTester.run(vpnConnected: false) }
    }
}

private struct InstallStep: View {
    let back: () -> Void
    let next: () -> Void

    @Environment(KillSwitchControl.self) private var control
    @Environment(VPNClient.self) private var client
    @State private var installed = false
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if installed {
                StepHeader(title: String(localized: "Подключение"), text: String(localized: "KillSwitch загрузит серверы подписки и подключит VPN."))
                Text("macOS попросит пароль администратора.")
            } else {
                StepHeader(title: String(localized: "Установка"),
                           text: String(localized: "KillSwitch поставит фоновую службу. Она работает от системы ещё до входа в учётную запись и следит, чтобы ничего не шло мимо VPN."))
                Text("macOS попросит пароль администратора — один раз.")
                Text("После установки macOS покажет уведомление «Добавлен фоновый объект» — это KillSwitch.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(installed ? String(localized: "Загружаю серверы…") : String(localized: "Устанавливаю службу и загружаю серверы…")).foregroundStyle(.secondary)
                }
            } else if let error = control.error ?? client.lastError {
                InlineError(error: error)
            }
            HelperApprovalNote()
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Назад", action: back).keyboardShortcut(.cancelAction).disabled(running)
                Button(failed ? String(localized: "Повторить") : installed ? String(localized: "Подключить…") : String(localized: "Установить…"), action: install)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(running)
            }
        }
        .onAppear { installed = control.serviceInstalled }
    }

    private var failed: Bool { !running && (control.error != nil || client.lastError != nil) }

    private func install() {
        guard let prepared = client.prepareImport() else { return }
        running = true
        Task {
            if await control.setUp(profile: prepared.file.path) {
                client.didImport(prepared)
                running = false
                next()
            } else {
                client.discard(prepared)
                running = false
            }
        }
    }
}

private struct FilterStep: View {
    let next: () -> Void

    @Environment(KillSwitchControl.self) private var control

    var body: some View {
        let filter = control.filter
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(title: String(localized: "Защита macOS"),
                       text: String(localized: "Второй уровень: macOS сама не выпустит программы мимо VPN, даже если основную защиту кто-то снимет."),
                       badge: String(localized: "Рекомендуем"))
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Нажми «Включить…» — macOS откроет Системные настройки.")
                Text("2. В разделе «Сетевые расширения» включи KillSwitch.")
            }
            status(filter.status)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                if working(filter.status) {
                    Button("Далее", action: next).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                } else {
                    Button("Пропустить", action: next).keyboardShortcut(.cancelAction)
                    Button("Включить…") { filter.install() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(filter.status == .waitingForApproval)
                }
            }
        }
    }

    private func working(_ status: FilterControl.Status) -> Bool { status == .on || status == .off }

    @ViewBuilder private func status(_ status: FilterControl.Status) -> some View {
        switch status {
        case .waitingForApproval:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Жду разрешения в Системных настройках…").foregroundStyle(.secondary)
                Spacer()
                Button("Открыть ещё раз") { NSWorkspace.shared.open(SystemSettings.networkExtensions) }
            }
        case .on, .off:
            StatusLabel("Защита macOS работает", systemImage: "checkmark.circle.fill", tint: .green)
        case .failed:
            StatusLabel("Не получилось включить. Можно пропустить и включить позже в настройках.",
                        systemImage: "exclamationmark.triangle.fill", tint: .orange)
        case .unknown, .notInstalled:
            EmptyView()
        }
    }
}

private struct DoneStep: View {
    @Environment(KillSwitchControl.self) private var control
    @Environment(VPNClient.self) private var client
    @Environment(AutoConnector.self) private var auto
    @Environment(\.dismiss) private var dismiss
    @State private var autoConnect = true
    @State private var launchAtLogin = true
    @State private var notifications = true

    var body: some View {
        let status = control.status(client)
        VStack(spacing: 10) {
            Image(status.icon)
                .resizable().scaledToFit()
                .frame(width: 56, height: 56)
                .foregroundStyle(status.tone.color)
                .accessibilityHidden(true)
            Text(status.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            if let server = control.currentServer {
                Text(ServerName.display(server) + (control.delay(of: server).map { String(localized: " · \($0) мс") } ?? ""))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $autoConnect) {
                    Text("Подключаться автоматически")
                    Text("В новых сетях и после включения Mac.")
                }
                Toggle(isOn: $launchAtLogin) { Text("Запускать KillSwitch при входе") }
                Toggle(isOn: $notifications) {
                    Text("Сообщать, если VPN оборвался или кончается подписка")
                    Text("macOS спросит разрешение на уведомления.")
                }
            }
            .toggleStyle(.checkbox)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Готово", action: finish).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
    }

    private func finish() {
        auto.enabled = autoConnect
        if control.launchAtLogin != launchAtLogin { control.launchAtLogin = launchAtLogin }
        for setting in [UserNotice.Setting.connection, .subscription, .pause, .service] {
            UserDefaults.standard.set(notifications, forKey: setting.rawValue)
        }
        if notifications {
            Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        }
        dismiss()
    }
}
