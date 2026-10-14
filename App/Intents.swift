import AppIntents

/// «Быстрые команды» (spec §5.5): Подключить, Отключить, Сменить страну, Статус in Shortcuts,
/// Spotlight and Siri. They run in the app (started in the background if it is not running) and
/// do what the menu does; what needs the window is said back (Shortcuts).
@MainActor
enum ShortcutTarget {
    static weak var control: KillSwitchControl?
    static weak var client: VPNClient?

    /// The app's objects once the first check of the state is done (a few seconds at most).
    static func ready() async throws -> (KillSwitchControl, VPNClient) {
        guard let control, let client else { throw ShortcutError.notReady }
        for _ in 0..<50 where control.status(client) == .checking {
            try await Task.sleep(for: .milliseconds(100))
        }
        return (control, client)
    }

    /// Waits for the helper to finish, then for the state to show `done` (at most ~10 s more).
    static func wait(_ control: KillSwitchControl, until done: () -> Bool) async throws {
        while control.busy { try await Task.sleep(for: .milliseconds(200)) }
        for _ in 0..<50 where !done() { try await Task.sleep(for: .milliseconds(200)) }
    }

    static func said(_ text: String) -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: text))
    }
}

enum ShortcutError: Error, CustomLocalizedStringResourceConvertible {
    case notReady, refused(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: "KillSwitch ещё запускается. Попробуй ещё раз."
        case .refused(let text): "\(text)"
        }
    }
}

struct ConnectIntent: AppIntent {
    static let title: LocalizedStringResource = "Подключить VPN"
    static let description = IntentDescription("Подключает VPN KillSwitch к выбранному серверу.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (control, client) = try await ShortcutTarget.ready()
        switch Shortcuts.connect(status: control.status(client), busy: control.busy, coreConfigured: control.coreConfigured) {
        case .done(let text): return ShortcutTarget.said(text)
        case .refused(let text): throw ShortcutError.refused(text)
        case .run:
            control.coreOn()
            try await ShortcutTarget.wait(control) { control.status(client).primary == .disconnect }
            if let error = control.error { throw ShortcutError.refused(error.message) }
            return ShortcutTarget.said(Shortcuts.statusText(status: control.status(client), server: control.currentServer))
        }
    }
}

struct DisconnectIntent: AppIntent {
    static let title: LocalizedStringResource = "Отключить VPN"
    static let description = IntentDescription("Отключает VPN KillSwitch. Защита остаётся, как настроена.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (control, client) = try await ShortcutTarget.ready()
        switch Shortcuts.disconnect(status: control.status(client), busy: control.busy) {
        case .done(let text): return ShortcutTarget.said(text)
        case .refused(let text): throw ShortcutError.refused(text)
        case .run:
            control.coreOff()
            try await ShortcutTarget.wait(control) { control.status(client).primary == .connect }
            if let error = control.error { throw ShortcutError.refused(error.message) }
            return ShortcutTarget.said(Shortcuts.statusText(status: control.status(client), server: nil))
        }
    }
}

struct StatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Статус VPN"
    static let description = IntentDescription("Говорит, защищён ли Mac и через какой сервер.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let (control, client) = try await ShortcutTarget.ready()
        let text = Shortcuts.statusText(status: control.status(client), server: control.currentServer)
        return .result(value: text, dialog: IntentDialog(stringLiteral: text))
    }
}

/// A row of «Серверы»: a country, an own server or «Самый быстрый».
struct ServerEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Сервер"
    static let defaultQuery = ServerQuery()

    let id: String
    let title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }

    init(_ entry: ServerPicker.Entry) {
        id = entry.name
        title = entry.title
    }
}

struct ServerQuery: EntityStringQuery {
    @MainActor
    private static var proxies: CoreProxies? {
        ShortcutTarget.control?.proxies ?? ShortcutTarget.client?.profileProxies
    }

    @MainActor
    static var subscription: String { ShortcutTarget.client?.activeID ?? ServerID.own }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [ServerEntity] {
        Shortcuts.servers(Self.proxies, subscription: Self.subscription, named: identifiers).map(ServerEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [ServerEntity] {
        Shortcuts.servers(Self.proxies, subscription: Self.subscription, matching: string).map(ServerEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [ServerEntity] {
        Shortcuts.servers(Self.proxies, subscription: Self.subscription).map(ServerEntity.init)
    }
}

struct ChooseServerIntent: AppIntent {
    static let title: LocalizedStringResource = "Сменить страну"
    static let description = IntentDescription("Выбирает сервер из списка «Серверы». Без VPN выбор включится при следующем подключении.")

    @Parameter(title: "Сервер")
    var server: ServerEntity

    static var parameterSummary: some ParameterSummary { Summary("Сменить страну на \(\.$server)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (control, client) = try await ShortcutTarget.ready()
        let proxies = control.proxies ?? client.profileProxies
        guard let entry = Shortcuts.servers(proxies, subscription: client.activeID, named: [server.id]).first else {
            throw ShortcutError.refused(String(localized: "Такого сервера больше нет в списке."))
        }
        if control.busy { throw ShortcutError.refused(Shortcuts.busy) }
        control.choose(entry)
        return ShortcutTarget.said(Shortcuts.chosen(entry.isFastest ? entry.title : entry.name, connected: control.coreRunning))
    }
}

/// Spotlight and Siri phrases; every one has to name the app.
struct KillSwitchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ConnectIntent(),
                    phrases: ["Подключить \(.applicationName)", "Включить VPN в \(.applicationName)"],
                    shortTitle: "Подключить", systemImageName: "lock.shield")
        AppShortcut(intent: DisconnectIntent(),
                    phrases: ["Отключить \(.applicationName)", "Выключить VPN в \(.applicationName)"],
                    shortTitle: "Отключить", systemImageName: "lock.open")
        AppShortcut(intent: ChooseServerIntent(),
                    phrases: ["Сменить страну в \(.applicationName)", "Сменить страну в \(.applicationName) на \(\.$server)"],
                    shortTitle: "Сменить страну", systemImageName: "globe")
        AppShortcut(intent: StatusIntent(),
                    phrases: ["Статус \(.applicationName)", "Я защищён в \(.applicationName)?"],
                    shortTitle: "Статус", systemImageName: "checkmark.shield")
    }
}
