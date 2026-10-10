import SwiftUI

/// The main screen (spec §5.1), the same in the menu bar popover and in the window: the summary
/// status, one notice, the server, one big button, two quick switches and the subscription.
struct HomeView: View {
    enum Style { case popover, window }
    var style: Style = .window
    /// Closes the popover (StatusItem); `dismiss` cannot reach an AppKit popover.
    var close: (() -> Void)?

    @Environment(KillSwitchControl.self) private var control
    @Environment(VPNClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingServers = false

    var body: some View {
        Group {
            if showingServers {
                ServersScreen(back: { showingServers = false })
            } else {
                HomeContent(style: style, chooseServer: chooseServer)
            }
        }
        .frame(width: style == .popover ? 340 : nil)
        .frame(maxWidth: style == .window ? 440 : nil)
        .animation(reduceMotion ? nil : .default, value: showingServers)   // spec §9.7
        // the helper is asked often only while something shows its answers
        .onAppear { control.viewAppeared() }
        .onDisappear { control.viewDisappeared() }
        // Esc: back from the server list, then closes the popover
        .onExitCommand {
            if showingServers { showingServers = false } else if style == .popover { if let close { close() } else { dismiss() } }
        }
    }

    /// The popover shows the list in place; the window has «Серверы» in its sidebar.
    private func chooseServer() {
        if style == .popover { showingServers = true } else { Router.shared.go(.section(.servers)) }
    }
}

/// The widget's «Выключить» (or a pause) arrives as a Darwin notification, which any program can
/// post: the main window asks before anything that could bring up the password prompt.
struct WidgetRequestAlert: ViewModifier {
    @Environment(KillSwitchControl.self) private var control

    func body(content: Content) -> some View {
        let request = control.widgetRequest
        content.alert(request == .pause5 ? String(localized: "Поставить защиту на паузу?") : String(localized: "Выключить защиту?"),
                      isPresented: Binding(get: { request != nil }, set: { if !$0 { control.answerWidgetRequest(nil) } })) {
            Button(request == .pause5 ? String(localized: "Пауза на 5 минут") : String(localized: "Выключить"), role: .destructive) {
                control.answerWidgetRequest(request)
            }
            Button("Отмена", role: .cancel) { control.answerWidgetRequest(nil) }
        } message: {
            Text("Об этом попросил виджет. Если вы его не нажимали, нажмите «Отмена».")
        }
    }
}

private struct HomeContent: View {
    let style: HomeView.Style
    let chooseServer: () -> Void

    @Environment(KillSwitchControl.self) private var control
    @Environment(VPNClient.self) private var client

    var body: some View {
        let status = control.status(client)
        VStack(spacing: 14) {
            if style == .popover {
                HStack {
                    Text("KillSwitch").font(.headline)
                    Spacer()
                    ActionsMenu(style: style)
                }
            }
            hero(status)
                .overlay(alignment: .topTrailing) {
                    if style == .window { ActionsMenu(style: style) }
                }
            TopErrorBanner(chooseServer: chooseServer) { NoticeBanner(chooseServer: chooseServer) }
            if status.showsServer {
                ServerRow(action: chooseServer)
            }
            buttons(status)
            if status.showsServer {
                QuickSwitches()
            }
            if client.hasURL {
                Divider()
                SubscriptionLine()
            }
        }
        .padding(16)
    }

    private func hero(_ status: Status) -> some View {
        VStack(spacing: 6) {
            Image(status.icon)
                .resizable().scaledToFit()
                .frame(width: 56, height: 56)
                .foregroundStyle(status.tone.color)
                .accessibilityHidden(true)
            Text(status.homeTitle(detail)).font(.title2.bold()).multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            let line = status.homeLine(detail)
            if !line.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(status.tone.color).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text(line).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var detail: Status.Detail {
        let server = control.currentServer
        return Status.Detail(server: server.map(ServerName.display), ping: server.flatMap(control.delay(of:)),
                             switched: control.recentSwitch, otherVPN: control.otherVPNName,
                             otherVPNStopFailed: control.otherVPNStopFailed)
    }

    @ViewBuilder private func buttons(_ status: Status) -> some View {
        VStack(spacing: 8) {
            let primary = status.primary
            let remedy = control.otherVPNRemedy
            Button { perform(primary) } label: {
                Text(primary == .replaceOtherVPN ? OtherVPN.buttonTitle(remedy, name: control.otherVPNName) : primary.title)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .modifier(Prominent(on: primary == .connect || primary == .replaceOtherVPN))
            .keyboardShortcut(primary.isConnection ? KeyboardShortcut("k") : nil)
            .disabled(!status.primaryEnabled || control.busy || (primary == .connect && !control.coreConfigured)
                      || (primary == .replaceOtherVPN && remedy == .none))
            if let secondary = status.secondary {
                Button(secondary.title) { perform(secondary) }
                    .disabled(control.busy)
            }
        }
    }

    private func perform(_ action: Status.Action) {
        switch action {
        case .install, .addSubscription: Router.shared.go(.onboarding)
        case .repair: control.install()
        case .openLoginItems: NSWorkspace.shared.open(SystemSettings.loginItems)
        case .connect: control.coreOn()
        case .cancel, .disconnect: control.coreOff()
        case .chooseServer: chooseServer()
        case .enableProtection, .resumeProtection: control.turnOn()
        case .replaceOtherVPN:
            switch control.otherVPNRemedy {
            case .stop: control.replaceOtherVPN()
            case .openApp: if let app = control.otherVPNApp { NSWorkspace.shared.open(app) }
            case .none: break
            }
        }
    }
}

private struct Prominent: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
    }
}

extension Status {
    /// The server row and the quick switches make sense once the VPN can be used.
    var showsServer: Bool {
        switch self {
        case .connecting, .stuck, .protected, .connectedUnprotected, .blocked, .unprotected: true
        default: false
        }
    }
}

extension Status.Tone {
    var color: Color {
        switch self {
        case .good: .green
        case .warning: .orange
        case .neutral: .secondary
        }
    }
}

extension Status.Action {
    var isConnection: Bool { self == .connect || self == .disconnect || self == .cancel || self == .replaceOtherVPN }
}

/// «🇱🇹 Литва   37 мс  ›»: opens the server choice.
private struct ServerRow: View {
    let action: () -> Void
    @Environment(KillSwitchControl.self) private var control

    var body: some View {
        let server = control.currentServer
        let title = control.coreRunning ? server.map(ServerName.display)
            : control.pendingChoice?.title ?? control.lastServer.map(ServerName.display)
        Button(action: action) {
            HStack {
                Text(title ?? String(localized: "Выбрать сервер")).lineLimit(1)
                Spacer()
                if let server {
                    PingView(ping: ServerPicker.Ping(delay: control.delay(of: server), timedOut: control.timedOut(server)))
                }
                Image(systemName: "chevron.right").foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("l")
        .accessibilityLabel(String(localized: "Сервер: \(title.map { _ in spoken } ?? String(localized: "не выбран"))"))
        .accessibilityHint("Открыть выбор сервера")
        .help("Выбрать сервер (⌘L)")
    }

    private var spoken: String {
        if control.coreRunning, let server = control.currentServer { return ServerName.spoken(server) }
        if let pending = control.pendingChoice {
            return pending.isFastest ? ServerPicker.fastestTitle : ServerName.spoken(pending.name)
        }
        return control.lastServer.map(ServerName.spoken) ?? String(localized: "не выбран")
    }
}

/// «Двойной VPN»: each change asks for the password. Which sites go around the VPN is the
/// subscription's business (ADR 0013), shown in «Трафик».
private struct QuickSwitches: View {
    @Environment(KillSwitchControl.self) private var control

    var body: some View {
        let exit = control.currentServer
        let candidates = Multihop.candidates(control.proxies?.servers ?? [], exit: exit)
        VStack(spacing: 6) {
            row(Text(multihopTitle(exit: exit)), String(localized: "Двойной VPN"),
                isOn: Binding(get: { control.multihopEntry != nil },
                              set: { control.setMultihop(entry: $0 ? candidates.first : nil) }))
                .disabled(control.multihopEntry == nil && candidates.isEmpty)
                .help("Через два сервера: вход видит твой адрес, выход — сайты. Спросит пароль.")
        }
        .disabled(control.busy)
    }

    /// Label on the left, switch on the right, one VoiceOver element.
    private func row(_ label: Text, _ spoken: String, isOn: Binding<Bool>) -> some View {
        HStack {
            label
            Spacer()
            Toggle(spoken, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
                .accessibilityHint("Спросит пароль")
        }
    }

    private func multihopTitle(exit: String?) -> String {
        guard let entry = control.multihopEntry else { return String(localized: "Двойной VPN") }
        let flag = { (name: String?) in name.flatMap { ServerName($0).flag } ?? "🌐" }
        return String(localized: "Двойной VPN: \(flag(entry)) → \(flag(exit))")
    }
}

/// «StorkVPN · Премиум   38 из 100 ГБ / до 2 ноября   ⟳».
private struct SubscriptionLine: View {
    @Environment(VPNClient.self) private var client

    var body: some View {
        let usage = client.status.usage
        VStack(spacing: 2) {
            HStack {
                Text(client.status.title ?? String(localized: "Подписка")).lineLimit(1)
                Spacer()
                if let usage { Text(Russian.traffic(used: usage.used, total: usage.total)).foregroundStyle(.secondary) }
            }
            HStack {
                if let expire = usage?.expire {
                    Text(expire < Date() ? String(localized: "закончилась \(Self.day(expire))") : String(localized: "до \(Self.day(expire))")).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await client.update(interactive: true) }
                } label: {
                    if client.updating { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.borderless)
                .disabled(client.updating)
                .help("Обновить подписку (⌘R)")
                .accessibilityLabel(client.updating ? String(localized: "Подписка обновляется") : String(localized: "Обновить подписку"))
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM"
        return formatter.string(from: date)
    }
}

/// Priorities 2–7 of the main screen's notices (the error banner, priority 1, goes first).
private struct NoticeBanner: View {
    let chooseServer: () -> Void
    @Environment(KillSwitchControl.self) private var control
    @Environment(VPNClient.self) private var client
    @AppStorage("filterNoticeDismissed") private var filterDismissed = false

    var body: some View {
        let filterIncomplete: Bool = switch control.filter.status {
        case .notInstalled, .failed, .waitingForApproval: control.state != .notInstalled
        default: false
        }
        let notice = HomeNotice.pick(HomeNotice.Input(
            otherVPN: control.otherVPNActive,
            usage: client.status.usage, newServers: client.needsConfirmation,
            filterIncomplete: filterIncomplete, filterDismissed: filterDismissed, now: Date(),
            serversDown: control.serversDown, networkCause: control.networkCause,
            filterUpdateWaiting: control.filter.updateWaitingForApproval,
            helperApproval: control.helperApprovalBanner && [.needsApproval, .needsRegistration].contains(control.helperAvailability)))
        if let notice {
            switch notice {
            case .otherVPN:
                EmptyView()   // the summary on top says it, with the button (ADR 0009); lower notices wait
            case .network(let cause):
                Banner(icon: "wifi.exclamationmark", title: notice.title, message: notice.message) {
                    if cause == .serversBlocked {
                        if let fastest = control.proxies.flatMap({ ServerPicker.entries($0).first(where: \.isFastest) }) {
                            Button(ServerPicker.fastestTitle) { control.choose(fastest) }.disabled(control.busy)
                        }
                        Button("Выбрать сервер…", action: chooseServer)
                    } else {   // three buttons do not fit; the check repeats every minute anyway
                        Button("Проверить снова") { control.recheckNetwork() }.disabled(control.probing)
                    }
                }
            case .serversDown:
                Banner(icon: "antenna.radiowaves.left.and.right.slash", title: notice.title, message: notice.message) {
                    if let fastest = control.proxies.flatMap({ ServerPicker.entries($0).first(where: \.isFastest) }) {
                        Button(ServerPicker.fastestTitle) { control.choose(fastest) }.disabled(control.busy)
                    }
                    Button("Выбрать сервер…", action: chooseServer)
                }
            case .expired, .ending:
                if let url = client.status.accountURL {
                    Banner(icon: "calendar.badge.exclamationmark", title: notice.title, message: notice.message) {
                        Button("Продлить…") { NSWorkspace.shared.open(url) }
                    }
                } else {
                    Banner(icon: "calendar.badge.exclamationmark", title: notice.title, message: notice.message) { EmptyView() }
                }
            case .trafficLow:
                Banner(icon: "gauge.with.dots.needle.100percent", title: notice.title, message: notice.message) { EmptyView() }
            case .newServers:
                Banner(icon: "server.rack", title: notice.title, message: notice.message) {
                    Button("Разрешить…") { Task { await client.confirmNewServers() } }.disabled(client.updating)
                }
            case .filterOff:
                Banner(icon: "lock.trianglebadge.exclamationmark", tint: .yellow, title: notice.title, message: notice.message,
                       dismiss: { filterDismissed = true }, dismissHelp: String(localized: "Не напоминать")) {
                    if control.filter.status == .waitingForApproval {
                        Button("Открыть Системные настройки") { NSWorkspace.shared.open(SystemSettings.networkExtensions) }
                    } else {
                        Button("Включить…") { control.filter.install() }
                    }
                }
            case .filterUpdateWaiting:
                Banner(icon: "arrow.triangle.2.circlepath", title: notice.title, message: notice.message) {
                    Button("Открыть Системные настройки") { NSWorkspace.shared.open(SystemSettings.networkExtensions) }
                }
            case .helperApproval:
                Banner(icon: "lock.shield", title: notice.title, message: notice.message,
                       dismiss: { control.dismissHelperApprovalBanner() }) {
                    Button("Открыть Объекты входа") { HelperClient.openLoginItems() }
                }
            }
        }
    }
}

/// «⋯»: everything that is not the main action (spec §5.1).
struct ActionsMenu: View {
    let style: HomeView.Style
    @Environment(KillSwitchControl.self) private var control
    @Environment(VPNClient.self) private var client
    @Environment(Updater.self) private var updater
    @AppStorage("pauseShort") private var pauseShort = 5
    @AppStorage("pauseLong") private var pauseLong = 30
    @State private var confirmTurnOff = false
    @State private var confirmQuit = false

    var body: some View {
        Menu {
            protectionItems
            Divider()
            Button("Проверить пинг всех серверов") { Task { await control.testAllDelays() } }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!control.coreRunning || control.proxies == nil || !control.testing.isEmpty)
            if client.hasURL {
                Button("Обновить подписку") { Task { await client.update(interactive: true) } }
                    .keyboardShortcut("r")
                    .disabled(client.updating)
            }
            Button("Проверка утечек…") { Router.shared.go(.leakTest) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            if style == .popover {
                Button("Открыть окно KillSwitch") { Router.shared.go(.openWindow) }
                    .keyboardShortcut("0")
            }
            Button("Настройки…") { Router.shared.go(.settings) }
                .keyboardShortcut(",")
            Menu("Помощь") {
                Button("Как это работает") { Router.shared.go(.help) }
                Button("Скопировать диагностику") { DiagnosticsCopy.copy(control: control, client: client) }
                CheckForUpdatesButton(updater: updater)
            }
            Divider()
            Button("Выйти из KillSwitch…") { confirmQuit = true }
        } label: {
            Image(systemName: "ellipsis.circle").imageScale(.large)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Действия")
        .accessibilityLabel("Действия")
        .alert("Выключить защиту без срока?", isPresented: $confirmTurnOff) {
            Button("Пауза на \(pauseLong) минут") { control.pause(minutes: pauseLong) }
                .keyboardShortcut(.defaultAction)
            Button("Выключить", role: .destructive) { control.turnOff() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Если VPN оборвётся, программы пойдут в интернет напрямую.")
        }
        .alert("Выйти из KillSwitch?", isPresented: $confirmQuit) {
            Button("Выйти") { NSApp.terminate(nil) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("VPN и защита продолжат работать в фоне. Управлять ими можно будет, снова открыв KillSwitch.")
        }
    }

    @ViewBuilder private var protectionItems: some View {
        switch control.state {
        case .paused(let until):
            let minutes = max(1, Int((until.timeIntervalSinceNow / 60).rounded(.up)))
            Button("Возобновить защиту (осталось \(Russian.plural(minutes, String(localized: "минута"), String(localized: "минуты"), String(localized: "минут"))))") { control.turnOn() }
        case .on:
            Menu("Пауза защиты") {
                ForEach(Array(Set([pauseShort, pauseLong, 60])).sorted(), id: \.self) { minutes in
                    Button(minutes == 60 ? String(localized: "1 час") : Russian.plural(minutes, String(localized: "минута"), String(localized: "минуты"), String(localized: "минут"))) {
                        control.pause(minutes: minutes)
                    }
                }
                Button("До переподключения") { control.pauseUntilReconnect() }
            }
            Button("Выключить защиту…") { confirmTurnOff = true }
        case .off:
            Button("Включить защиту") { control.turnOn() }
        case .notInstalled, .unknown:
            EmptyView()
        }
    }
}
