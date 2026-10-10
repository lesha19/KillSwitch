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
        if message.hasPrefix("core: "), let arrow = message.range(of: " -> ") {
            return String(localized: "Выбран сервер «\(ServerName.display(String(message[arrow.upperBound...])))»")
        }
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
            ("rules up: network on", String(localized: "Защита включилась после загрузки — сеть включена")),
            ("shutdown: network off", String(localized: "Mac выключается — сеть отключена")),
            ("watchdog switched off", String(localized: "Службу выключили в Объектах входа — сеть не отключалась")),
            ("network turned back on", String(localized: "Сеть включена вручную")),
            ("core on", String(localized: "VPN подключён")),
            ("core off", String(localized: "VPN отключён")),
            ("core config imported", String(localized: "Серверы подписки загружены")),
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
}
