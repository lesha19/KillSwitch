import Foundation

/// «Журнал защиты» (Settings → Помощь): the helper's events.log (`YYYY-MM-DD HH:MM:SS message`,
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
            if why == "pf was disabled" { return "Защиту кто-то выключил — включена снова" }
            if why == "rules were changed or flushed" || why == "anchor missing from main ruleset" {
                return "Защиту кто-то изменил — восстановлена"
            }
            if why.hasPrefix("tunnels changed") { return "VPN подключился или отключился — защита обновлена" }
            if why == "initial load" { return "Защита включилась" }
            return "Защита обновлена"
        }
        if message.hasPrefix("core: "), let arrow = message.range(of: " -> ") {
            return "Выбран сервер «\(ServerName.display(String(message[arrow.upperBound...])))»"
        }
        if message.hasPrefix("double VPN: ") {
            let value = message.dropFirst("double VPN: ".count)
            return value == "off" ? "Двойной VPN выключен" : "Двойной VPN: вход через «\(ServerName.display(String(value)))»"
        }
        if message.hasPrefix("apps outside the VPN: ") {
            let value = message.dropFirst("apps outside the VPN: ".count)
            return "Программы без VPN: " + (value == "none" ? "нет" : value)
        }
        let known: [(String, String)] = [
            ("pause ended", "Пауза защиты закончилась"),
            ("reload failed", "Не получилось обновить защиту"),
            ("rules found loaded while off", "Защита осталась включённой после выключения — снята"),
            ("main ruleset reloaded from", "Другая программа заменила правила macOS — они загружены заново"),
            ("/etc/pf.conf has no com.apple anchor", "Защита не действует: в /etc/pf.conf нет правил macOS"),
            ("rules up: network on", "Защита включилась после загрузки — сеть включена"),
            ("shutdown: network off", "Mac выключается — сеть отключена"),
            ("watchdog switched off", "Службу выключили в Объектах входа — сеть не отключалась"),
            ("network turned back on", "Сеть включена вручную"),
            ("core on", "VPN подключён"),
            ("core off", "VPN отключён"),
            ("core config imported", "Серверы подписки загружены"),
            ("another VPN tunnel", "Рядом работает другой VPN"),
            ("other VPN tunnel gone", "Другой VPN отключился"),
            ("server addresses changed", "Адреса серверов обновлены"),
            ("server address change failed", "Не получилось обновить адреса серверов"),
            ("server names not resolved through", "Адреса серверов не нашлись через VPN — запрошены напрямую"),
            ("server names not resolved", "Не нашлись адреса серверов"),
            ("server name", "Адреса серверов узнаны в обход VPN — VPN ещё не подключён"),
            ("core DNS set", "VPN настроил DNS"),
            ("core not", "Настройки DNS восстановлены"),
            ("DNS set by an older version", "Настройки DNS восстановлены"),
        ]
        return known.first { message.hasPrefix($0.0) }?.1 ?? message
    }
}
