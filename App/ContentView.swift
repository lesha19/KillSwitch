import SwiftUI

struct ContentView: View {
    @Environment(KillSwitchControl.self) private var control
    @Environment(VPNClient.self) private var client
    @AppStorage("pauseShort") private var pauseShort = 5
    @AppStorage("pauseLong") private var pauseLong = 30
    @State private var confirmUninstall = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    banners
                    if control.state == .notInstalled {
                        installCard
                    } else {
                        if !client.hasURL && client.manual.isEmpty && !control.coreConfigured {
                            card { SubscriptionOnboarding() }
                        }
                        if control.coreInstalled && (control.coreConfigured || control.coreRunning) {
                            card { ServerList() }
                        }
                        if client.hasURL {
                            card { SubscriptionSummary() }
                        }
                        card { protection }
                    }
                    if let error = control.error {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }

            Divider()
            footer
        }
        .frame(width: 460)
        .frame(minHeight: 520, idealHeight: 680)
        .animation(.default, value: control.connection)
        .onAppear { control.loadProxies(force: true) }
        .confirmationDialog("Удалить защиту?", isPresented: $confirmUninstall) {
            Button("Удалить", role: .destructive) { control.uninstall() }
        } message: {
            Text("Правила снимутся, программы снова смогут выходить в интернет без VPN. Понадобится пароль.")
        }
    }

    // MARK: connection

    private var header: some View {
        let connection = control.connection
        return VStack(spacing: 14) {
            ZStack {
                Circle().fill(connection.color.opacity(0.15)).frame(width: 110, height: 110)
                Image(systemName: connection.symbol)
                    .font(.system(size: 50, weight: .semibold))
                    .foregroundStyle(connection.color)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityHidden(true)
            Text(connection.title).font(.title.bold())
                .accessibilityAddTraits(.isHeader)
            if connection == .connected || connection == .connecting, let server = control.currentServer {
                HStack(spacing: 8) {
                    ServerLabel(name: server, font: .title3)
                    DelayBadge(delay: control.delay(of: server))
                }
            }
            Text(protectionLine).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)

            switch connection {
            case .connected, .connecting:
                Button { control.coreOff() } label: { Text("Отключить").frame(maxWidth: .infinity) }
                    .controlSize(.large).buttonStyle(.borderedProminent).tint(.red)
                    .disabled(control.busy)
            case .disconnected:
                Button { control.coreOn() } label: { Text("Подключить").frame(maxWidth: .infinity) }
                    .controlSize(.large).buttonStyle(.borderedProminent).tint(.green)
                    .disabled(control.busy || !control.coreConfigured)
                if !control.coreConfigured {
                    Text("Сначала добавь подписку или сервер.").font(.caption).foregroundStyle(.secondary)
                }
            case .otherApp:
                Text("Сейчас подключён VPN другой программы. Отключи его, чтобы подключиться здесь.")
                    .font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center)
            case .unavailable:
                if control.state != .notInstalled {
                    Text("Ядро VPN не установлено. Нажми «Обновить защиту» внизу.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var protectionLine: String {
        switch control.state {
        case .on: control.coreDirect ? "Защита от утечек включена. Российские сайты — напрямую." : "Защита от утечек включена: без VPN интернета нет."
        case .off: "Защита от утечек выключена."
        case .paused(let until): "Защита на паузе до \(until.formatted(date: .omitted, time: .shortened))."
        case .notInstalled: "Защита от утечек не установлена."
        case .unknown: " "
        }
    }

    @ViewBuilder private var banners: some View {
        if let foreign = control.foreignVPN {
            banner("Рядом с нашим VPN работает VPN другой программы (\(foreign)). Два VPN мешают друг другу и могут пускать трафик мимо — отключи второй.")
        }
        if control.daemonProblem {
            banner("Фоновая служба защиты выключена в Системных настройках → Основные → Объекты входа. Правила пока действуют, но следить за ними некому.")
        }
    }

    private func banner(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout).foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: kill switch

    private var installCard: some View {
        card {
            VStack(spacing: 8) {
                Text("Защита от утечек и ядро VPN ставятся один раз и работают от системы, ещё до входа в учётную запись.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { control.install() } label: { Text("Установить").frame(maxWidth: .infinity) }
                    .controlSize(.large).buttonStyle(.borderedProminent)
                    .disabled(control.busy)
                Text("Попросит пароль.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var protection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(control.state.title, systemImage: control.state.symbol).font(.headline)
                Spacer()
                switch control.state {
                case .on:
                    Menu("Пауза") {
                        Button("\(pauseShort) мин") { control.pause(minutes: pauseShort) }
                        Button("\(pauseLong) мин") { control.pause(minutes: pauseLong) }
                    }
                    .fixedSize()
                    Button("Выключить", role: .destructive) { control.turnOff() }
                case .off, .paused, .unknown:
                    Button("Включить") { control.turnOn() }.buttonStyle(.borderedProminent).tint(.green)
                case .notInstalled:
                    EmptyView()
                }
            }
            .disabled(control.busy || control.state == .unknown)
            Text("Пока защита включена, программы выходят в интернет только через VPN. Выключение и пауза просят пароль.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            SettingsLink { Label("Настройки", systemImage: "gearshape") }
                .buttonStyle(.link)
            Spacer()
            if control.state != .notInstalled && control.state != .unknown {
                Button("Обновить защиту") { control.install() }
                    .buttonStyle(.link).disabled(control.busy)
                Button("Удалить защиту…", role: .destructive) { confirmUninstall = true }
                    .buttonStyle(.link).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
