import Foundation

/// «Журнал защиты» (a section of the window): the helper's events.log (`YYYY-MM-DD HH:MM:SS message`,
/// English, for support) in plain words. A line it does not know stays as it is.
enum ProtectionLog {
    struct Entry: Equatable {
        /// «10.10 14:03».
        var time: String
        var text: String
    }

    static func entry(_ line: String) -> Entry? {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0].count == 10, parts[1].count == 8 else {
            return line.isEmpty ? nil : Entry(time: "", text: line)
        }
        let date = parts[0].split(separator: "-")
        let time = date.count == 3 ? "\(date[2]).\(date[1]) \(parts[1].prefix(5))" : parts[1]
        return Entry(time: time, text: describe(parts[2]))
    }

    static func describe(_ message: String) -> String {
        if message.hasSuffix(": reloading") {
            let why = message.dropLast(": reloading".count)
            if why == "pf was disabled" { return String(localized: "Защиту кто-то выключил — включена снова") }
            if why == "rules were changed or flushed" || why == "anchor missing from main ruleset" {
                return String(localized: "Защиту кто-то изменил — восстановлена")
            }
            if why.hasPrefix("tunnels changed") { return String(localized: "VPN подключился или отключился — защита обновлена") }
            if why == "initial load" { return String(localized: "Защита включилась") }
            return String(localized: "Защита обновлена")
        }
        if let gap = gap(message) { return gap }
        if message.hasPrefix("core: "), let arrow = message.range(of: " -> ") {
            return String(localized: "Выбран сервер «\(ServerName.display(String(message[arrow.upperBound...])))»")
        }
        if let refused = refusedSwitch(message) { return refused }
        if let doubleVPN = doubleVPN(message) { return doubleVPN }
        if let escalation = escalation(message) { return escalation }
        if let mtu = tunnelMTU(message) { return mtu }
        if message.hasPrefix("double VPN: ") {
            let value = message.dropFirst("double VPN: ".count)
            return value == "off" ? String(localized: "Двойной VPN выключен") : String(localized: "Двойной VPN: вход через «\(ServerName.display(String(value)))»")
        }
        if message.hasPrefix("apps outside the VPN: ") {
            let value = message.dropFirst("apps outside the VPN: ".count)
            return String(localized: "Программы без VPN: ") + (value == "none" ? String(localized: "нет") : String(value))
        }
        let known: [(String, String)] = [
            ("pause ended", String(localized: "Пауза защиты закончилась")),
            ("reload failed", String(localized: "Не получилось обновить защиту")),
            ("rules found loaded while off", String(localized: "Защита осталась включённой после выключения — снята")),
            ("main ruleset reloaded from", String(localized: "Другая программа заменила правила macOS — они загружены заново")),
            ("/etc/pf.conf has no com.apple anchor", String(localized: "Защита не действует: в /etc/pf.conf нет правил macOS")),
            ("main ruleset has no com.apple anchor", String(localized: "Другая программа заменила правила macOS — защита не действует, её правила не тронуты")),
            ("main ruleset has the com.apple anchor again", String(localized: "Правила macOS снова на месте — защита действует")),
            ("rules up: network on", String(localized: "Защита включилась после загрузки — сеть включена")),
            ("shutdown: network off", String(localized: "Mac выключается — сеть отключена")),
            ("watchdog switched off", String(localized: "Службу выключили в Объектах входа — сеть не отключалась")),
            ("network turned back on", String(localized: "Сеть включена вручную")),
            ("detailed diagnostics: on", String(localized: "Подробная диагностика включена")),
            ("detailed diagnostics: off", String(localized: "Подробная диагностика выключена, записанные соединения удалены")),
            ("connection escalation: on", String(localized: "Подбор отпечатка и транспорта включён")),
            ("connection escalation: off", String(localized: "Подбор отпечатка и транспорта выключен")),
            ("escalate reset (network changed)", String(localized: "Сеть сменилась — серверы снова подключаются так, как задано в подписке")),
            ("core on", String(localized: "VPN подключён")),
            ("core off", String(localized: "VPN отключён")),
            ("core config imported", String(localized: "Серверы подписки загружены")),
            ("xray stats port free again", String(localized: "Счётчики трафика VPN снова работают")),
            ("xray stats port", String(localized: "Порт 47891 занят другой программой — VPN работает без счётчиков трафика")),
            ("core config rolled back", String(localized: "VPN не запустился с новыми настройками — возвращены прежние")),
            ("MTU change cut short", String(localized: "Прерванная смена размера пакетов VPN отменена")),
            ("core config: the new one refused", String(localized: "Новые настройки VPN не прошли проверку — оставлены прежние")),
            ("netbird: its daemon did not start again", String(localized: "NetBird не запустился после перезапуска — следующая попытка позже")),
            ("netbird: its daemon started again", String(localized: "NetBird снова запущен")),
            ("netbird: reconnected", String(localized: "NetBird снова подключён")),
            ("netbird: did not reconnect", String(localized: "NetBird не подключился после перезапуска — подключите его заново")),
            ("another VPN tunnel", String(localized: "Рядом работает другой VPN")),
            ("other VPN tunnel gone", String(localized: "Другой VPN отключился")),
            ("server addresses changed", String(localized: "Адреса серверов обновлены")),
            ("server address change failed", String(localized: "Не получилось обновить адреса серверов")),
            ("server names not resolved through", String(localized: "Адреса серверов не нашлись через VPN — запрошены напрямую")),
            ("server names not resolved", String(localized: "Не нашлись адреса серверов")),
            ("server name", String(localized: "Адреса серверов узнаны в обход VPN — VPN ещё не подключён")),
            ("core DNS set", String(localized: "VPN настроил DNS")),
            ("core not", String(localized: "Настройки DNS восстановлены")),
            ("DNS set by an older version", String(localized: "Настройки DNS восстановлены")),
        ]
        return known.first { message.hasPrefix($0.0) }?.1 ?? message
    }

    /// The helper turned «Двойной VPN» off or back by itself (ADR 0027): `double VPN off: its entry
    /// «X»: <why>`, `double VPN off: no answer through «X»`, `double VPN off: «X» was set for the other
    /// way of connecting`, `double VPN back: «A», no answer through «B»`.
    private static func doubleVPN(_ message: String) -> String? {
        let names = quoted(message).map { ServerName.display($0) }
        if message.hasPrefix("double VPN back: "), names.count == 2 {
            return String(localized: "Через «\(names[1])» соединение не установилось — вход снова «\(names[0])»")
        }
        guard message.hasPrefix("double VPN off: ") else { return nil }
        let name = names.first ?? ""
        if message.hasPrefix("double VPN off: no answer through ") {
            return String(localized: "Двойной VPN выключен: через «\(name)» соединение не установилось")
        }
        if message.hasSuffix("was set for the other way of connecting") {
            return String(localized: "Двойной VPN выключен: он был настроен для другого способа подключения")
        }
        if message.hasSuffix(": not a server of the subscription") {
            return String(localized: "Двойной VPN выключен: сервера входа «\(name)» больше нет в подписке")
        }
        if message.hasSuffix(": it is the running server") {
            return String(localized: "Двойной VPN выключен: «\(name)» сейчас и вход, и выход")
        }
        return String(localized: "Двойной VPN выключен: сервер входа «\(name)» больше не подходит")
    }

    /// «Размер пакетов VPN» (ADR 0032): `tunnel MTU: <v>, VPN restarted`, `tunnel MTU: <v>` (the VPN
    /// was off: nothing restarted), `tunnel MTU: <v> refused, back to <old>: …` (it did not start).
    private static func tunnelMTU(_ message: String) -> String? {
        guard message.hasPrefix("tunnel MTU: ") else { return nil }
        let words = message.dropFirst("tunnel MTU: ".count).split(separator: " ").map { String($0.trimmingCharacters(in: CharacterSet(charactersIn: ",:"))) }
        func title(_ value: String) -> String { TunnelMTU.title(value == HelperCommand.mtuAuto ? nil : Int(value)) }
        guard let value = words.first else { return nil }
        if words.count >= 5, words[1] == "refused", words[2] == "back", words[3] == "to" {
            return String(localized: "VPN не запустился с размером пакетов \(title(value)) — вернули прежний: \(title(words[4]))")
        }
        if words.count >= 3, words[1] == "VPN", words[2] == "restarted" {
            return String(localized: "Размер пакетов VPN (MTU): \(title(value)), VPN перезапущен")
        }
        return String(localized: "Размер пакетов VPN (MTU): \(title(value))")
    }

    /// ADR 0035, one line per gap: `internet closed for <n> s: update|server switch|VPN off|reconnect`.
    private static func gap(_ message: String) -> String? {
        let prefix = "internet closed for "
        guard message.hasPrefix(prefix), let unit = message.range(of: " s: "),
              let seconds = Int(message[message.index(message.startIndex, offsetBy: prefix.count)..<unit.lowerBound]) else { return nil }
        let length = seconds < 60 ? String(localized: "\(seconds) с")
            : seconds % 60 == 0 ? String(localized: "\(seconds / 60) мин") : String(localized: "\(seconds / 60) мин \(seconds % 60) с")
        let why = switch message[unit.upperBound...] {
        case "update": String(localized: "обновление")
        case "server switch": String(localized: "смена сервера")
        case "VPN off": String(localized: "до отключения VPN")
        default: String(localized: "переподключение")
        }
        return String(localized: "Интернет был закрыт \(length): \(why)")
    }

    /// The «…»-quoted parts of a line, in order.
    private static func quoted(_ text: String) -> [String] {
        var result: [String] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "«"), let close = rest[open...].firstIndex(of: "»") {
            result.append(String(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return result
    }

    /// ks refused a server switch that would change what goes past the VPN (KS-10).
    private static func refusedSwitch(_ message: String) -> String? {
        // the separator is searched after the prefix: a name may begin with one (it would trap)
        let switchTo = message.dropFirst("server switch to ".count)
        guard message.hasPrefix("server switch to "), let refused = switchTo.range(of: " refused: ") else { return nil }
        let server = ServerName.display(String(switchTo[..<refused.lowerBound]))
        return String(localized: "Не переключились на «\(server)»: он пускает мимо VPN не то, что было подтверждено. Возьми подписку заново с паролем")
    }

    /// The same server another way (ADR 0030): `escalate (no answer): A fingerprint|transport X -> Y`,
    /// `escalate failed: A fingerprint|transport X -> Y, kept`. The kind is the last such word: a
    /// server name may hold one.
    private static func escalation(_ message: String) -> String? {
        // the alternatives' probes on and off, back to the subscription's way, a failure of either
        let simple: [(String, (String) -> String)] = [
            ("escalate probing failed: ", { String(localized: "Не получилось проверить другие способы подключения к «\($0)»") }),
            ("escalate probing off: ", { String(localized: "«\($0)» снова отвечает — другие способы подключения больше не проверяем") }),
            ("escalate probing: ", { String(localized: "«\($0)» не ответил дважды — проверяем другие способы подключения к нему") }),
            ("escalate settled: ", { String(localized: "«\($0)» снова работает так, как задано в подписке — вернулись к этому") }),
            ("escalate settle failed: ", { String(localized: "Не получилось вернуть «\($0)» к настройкам подписки") }),
        ]
        if let (prefix, text) = simple.first(where: { message.hasPrefix($0.0) }) {
            return text(ServerName.display(String(message.dropFirst(prefix.count))))
        }
        let failed = message.hasPrefix("escalate failed: ")
        guard failed || message.hasPrefix("escalate (no answer): ") else { return nil }
        let rest = message.drop { $0 != ":" }.dropFirst(2)
        let fingerprint = rest.range(of: " fingerprint ", options: .backwards)
        let transport = rest.range(of: " transport ", options: .backwards)
        guard let kind = [fingerprint, transport].compactMap({ $0 }).max(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let isFingerprint = kind == fingerprint
        let server = ServerName.display(String(rest[..<kind.lowerBound]))
        if failed {
            return isFingerprint ? String(localized: "Не получилось сменить отпечаток TLS для «\(server)» — оставлен прежний")
                : String(localized: "Не получилось сменить транспорт для «\(server)» — оставлен прежний")
        }
        let values = rest[kind.upperBound...]
        guard let arrow = values.range(of: " -> ") else { return nil }
        let from = String(values[..<arrow.lowerBound]), to = String(values[arrow.upperBound...])
        return isFingerprint ? String(localized: "«\(server)» не отвечал — подключаемся к нему с другим отпечатком TLS: \(to) вместо \(from)")
            : String(localized: "«\(server)» не отвечал — подключаемся к нему по другому транспорту из подписки: \(to) вместо \(from)")
    }
}
