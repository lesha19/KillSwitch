import Foundation

/// Why nothing works while connected (ADR 0006): `ks probe` tries a TCP handshake from the
/// physical interface to a Russian address that the mobile «white lists» keep open and to foreign
/// ones; the core's health checks say whether our servers answer.
enum NetworkCause: Equatable {
    case noNetwork
    case noInternet
    /// Only whitelisted Russian addresses answer: the operator's «white lists».
    case whitelist
    /// The internet works, our servers do not answer: most likely blocked.
    case serversBlocked

    /// `ks probe`: "link=0|1 ru=0|1 foreign=0|1".
    struct Probe: Equatable {
        let link: Bool
        let ru: Bool
        let foreign: Bool

        init(link: Bool, ru: Bool, foreign: Bool) {
            self.link = link
            self.ru = ru
            self.foreign = foreign
        }

        init?(_ output: String) {
            var values: [String: Bool] = [:]
            for pair in output.split(whereSeparator: \.isWhitespace) {
                let parts = pair.split(separator: "=")
                guard parts.count == 2, parts[1] == "0" || parts[1] == "1" else { return nil }
                values[String(parts[0])] = parts[1] == "1"
            }
            guard let link = values["link"], let ru = values["ru"], let foreign = values["foreign"] else { return nil }
            self.init(link: link, ru: ru, foreign: foreign)
        }
    }

    /// nil: the network is fine and the servers answer (or the core has not said yet).
    static func classify(_ probe: Probe, serversAnswer: Bool?) -> NetworkCause? {
        if !probe.link { return .noNetwork }
        if !probe.ru && !probe.foreign { return .noInternet }
        if !probe.foreign { return .whitelist }
        return serversAnswer == false ? .serversBlocked : nil
    }

    /// From the core's health checks: does any server of the profile answer; nil without servers.
    static func serversAnswer(_ proxies: CoreProxies) -> Bool? {
        let servers = proxies.servers
        guard !servers.isEmpty else { return nil }
        return servers.contains { proxies.alive($0) != false }
    }

    /// The server the person picked (`chosen`, as displayed) while the core still uses it and it
    /// stopped answering: KillSwitch never moves to another server by itself (ADR 0036), the person
    /// picks. nil for a group («Самый быстрый» moves by itself) or a server picked away from since.
    static func serverDown(chosen: String?, proxies: CoreProxies) -> String? {
        guard let chosen, proxies.groups.first(where: { $0.name == chosen }) == nil,
              ServerPicker.selected(proxies) == chosen, proxies.alive(chosen) == false else { return nil }
        return ServerName.display(chosen)
    }

    static let probeInterval: TimeInterval = 60

    /// Only when nothing answers (every server, or the chosen one), at most once a minute.
    /// Never while another VPN is up: it took the routes, and the main screen already says so (ADR 0009).
    static func shouldProbe(serversAnswer: Bool?, serversDown: Bool, last: Date?, now: Date, otherVPN: Bool = false) -> Bool {
        guard !otherVPN, serversAnswer == false || serversDown else { return false }
        guard let last else { return true }
        return now.timeIntervalSince(last) > probeInterval
    }

    var title: String {
        switch self {
        case .noNetwork: String(localized: "Нет подключения к сети")
        case .noInternet: String(localized: "Интернета нет")
        case .whitelist: String(localized: "Оператор пускает только на российские сайты")
        case .serversBlocked: String(localized: "Серверы VPN недоступны")
        }
    }

    var message: String {
        switch self {
        case .noNetwork:
            String(localized: "Mac не подключён ни к Wi‑Fi, ни к кабелю. Подключись к сети — VPN включится сам.")
        case .noInternet:
            String(localized: "Сеть есть, но в интернет она не пускает: не открываются ни российские, ни зарубежные сайты. ")
                + String(localized: "Проверь роутер или баланс у оператора. Wi‑Fi в кафе или отеле — нужна страница входа: ")
                + String(localized: "поставь защиту на паузу на 5 минут.")
        case .whitelist:
            String(localized: "Похоже, мобильный интернет работает по «белым спискам»: открываются только разрешённые ")
                + String(localized: "российские сайты, VPN и зарубежные сайты закрыты. Это делает оператор, KillSwitch тут ")
                + String(localized: "не поможет. Подключись к Wi‑Fi или попробуй позже.")
        case .serversBlocked:
            String(localized: "Интернет работает, а наши серверы не отвечают — скорее всего, их блокирует провайдер. ")
                + String(localized: "Выбери другой сервер или «Самый быстрый», обнови подписку. Не помогло — напиши ")
                + String(localized: "в поддержку VPN-сервиса.")
        }
    }
}
