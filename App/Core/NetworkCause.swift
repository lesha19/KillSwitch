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

    static let probeInterval: TimeInterval = 60

    /// Only when nothing answers (every server, or every one of the chosen country), at most once a minute.
    static func shouldProbe(serversAnswer: Bool?, serversDown: Bool, last: Date?, now: Date) -> Bool {
        guard serversAnswer == false || serversDown else { return false }
        guard let last else { return true }
        return now.timeIntervalSince(last) > probeInterval
    }

    var title: String {
        switch self {
        case .noNetwork: "Нет подключения к сети"
        case .noInternet: "Интернета нет"
        case .whitelist: "Оператор пускает только на российские сайты"
        case .serversBlocked: "Серверы VPN недоступны"
        }
    }

    var message: String {
        switch self {
        case .noNetwork:
            "Mac не подключён ни к Wi‑Fi, ни к кабелю. Подключись к сети — VPN включится сам."
        case .noInternet:
            "Сеть есть, но в интернет она не пускает: не открываются ни российские, ни зарубежные сайты. "
                + "Проверь роутер или баланс у оператора. Wi‑Fi в кафе или отеле — нужна страница входа: "
                + "поставь защиту на паузу на 5 минут."
        case .whitelist:
            "Похоже, мобильный интернет работает по «белым спискам»: открываются только разрешённые "
                + "российские сайты, VPN и зарубежные сайты закрыты. Это делает оператор, KillSwitch тут "
                + "не поможет. Подключись к Wi‑Fi или попробуй позже."
        case .serversBlocked:
            "Интернет работает, а наши серверы не отвечают — скорее всего, их блокирует провайдер. "
                + "Выбери другой сервер или «Самый быстрый», обнови подписку. Не помогло — напиши "
                + "в поддержку VPN-сервиса."
        }
    }
}
