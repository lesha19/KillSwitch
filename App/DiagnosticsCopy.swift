import AppKit
import Foundation

/// «Скопировать диагностику»: states and recent errors for a support message. No subscription
/// URL, links, keys, UUIDs, server names or addresses — every value goes through
/// `Diagnostics.scrub`, and none of those are collected in the first place.
@MainActor
enum DiagnosticsCopy {
    static func text(control: KillSwitchControl, client: VPNClient) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        func yes(_ value: Bool) -> String { value ? "да" : "нет" }
        func date(_ value: Date?) -> String { value.map { $0.formatted(date: .numeric, time: .shortened) } ?? "—" }
        let filter: String = switch control.filter.status {
        case .unknown: "неизвестно"
        case .notInstalled: "не установлен"
        case .waitingForApproval: "ждёт разрешения"
        case .off: "выключен"
        case .on: "работает"
        case .failed(let message): "ошибка: \(message)"
        }
        var fields: [(String, String)] = [
            ("KillSwitch", version),
            ("macOS", ProcessInfo.processInfo.operatingSystemVersionString),
            ("Подключение", control.connection.title),
            ("Защита", control.state.title),
            ("Служба защиты", control.daemonProblem ? "выключена или не запущена" : "работает"),
            ("Фильтр macOS", filter),
            ("Ядро", control.coreChoice.rawValue),
            ("Ядро установлено", yes(control.coreInstalled)),
            ("Ядро настроено", yes(control.coreConfigured)),
            ("Ядро запущено", yes(control.coreRunning)),
            ("Туннель поднят", yes(control.vpnUp)),
            ("VPN KillSwitch поднят (198.18.128.1)", yes(control.ownTunnelUp)),
            ("VPN другой программы", control.foreignVPN ?? "нет"),
            ("Правил подписки", control.routing.map { "\($0.subscriptionRules.count), не взято \($0.dropped.count)" } ?? "нет данных"),
            ("Двойной VPN", yes(control.multihopEntry != nil)),
            ("Программ мимо VPN", "\(control.splitApps.count)"),
            ("Групп серверов", "\(control.proxies?.groups.count ?? 0)"),
            ("Подписка", client.hasURL ? "есть" : "нет"),
            ("Обновлена", date(client.status.lastUpdate)),
            ("Следующее обновление", date(client.nextUpdate)),
            ("Ждёт пароля для применения", yes(client.needsPassword)),
            ("Ждёт подтверждения новых серверов", yes(client.needsConfirmation && !client.routingChanged)),
            ("Ждёт подтверждения правил «напрямую»", yes(client.routingChanged)),
            ("Своих серверов", "\(client.manual.count)"),
        ]
        let errors = [control.error, control.coreError, control.proxiesError, client.lastError].compactMap { $0 }
            .map { $0.details.isEmpty ? "\($0.title): \($0.message)" : $0.details }
        for error in (control.recentErrors + errors).reduce(into: [String](), { if !$0.contains($1) { $0.append($1) } }) {
            fields.append(("Ошибка", error))
        }
        return Diagnostics.report(fields)
    }

    static func copy(control: KillSwitchControl, client: VPNClient) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(control: control, client: client), forType: .string)
    }
}
