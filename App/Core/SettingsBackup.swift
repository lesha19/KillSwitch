import Foundation

/// «Перенос настроек» (#15, ADR 0024): the app's settings and the root ones as a JSON file, read
/// back on another Mac or after a reinstall, and «Сбросить» to the defaults through the same path.
/// Never in the file: the subscription link, own servers and keys (Keychain), server identities
/// (they carry a hash of the server's secret: favourites and recents go by name), per-server
/// transport overrides and «Двойной VPN» (both name servers of one subscription). The own DoH
/// server (ADR 0031) is in it: the person's setting, like the exceptions.
/// A file is checked whole before anything changes; root settings change only through the `ks`
/// commands the Settings screens run (`rootCommands`), behind the same authorization.
enum SettingsBackup {
    static let format = "killswitch-settings"
    static let version = 1
    static let maxBytes = 1 << 20

    enum Value: Equatable, Sendable {
        case bool(Bool), int(Int), text(String), list([String]), rules([WiFiRules.Rule])
    }

    /// Settings in /Library/KillSwitch, as Settings shows them. Nil = not in the file, left alone.
    /// No core: it follows the subscription (#65); a file's "core" from before is ignored.
    struct Root: Equatable, Sendable {
        var switches: [String: Bool]?
        var exceptions: [String]?
        var manualServers: [String]?
        var splitApps: [String]?
        /// The own DNS-over-HTTPS server (ADR 0031); "" = none.
        var doh: String?
        /// The TUN's MTU, 0 = «Авто» (ADR 0032); nil: not named.
        var mtu: Int?
    }

    struct Settings: Equatable, Sendable {
        /// By UserDefaults key; only the keys of `fields`.
        var app: [String: Value]
        var root: Root?
    }

    enum Problem: Error, Equatable {
        case notSettings, newer
        /// The setting's title.
        case damaged(String)

        var message: String {
            switch self {
            case .notSettings: String(localized: "Это не файл настроек KillSwitch.")
            case .newer: String(localized: "Файл сохранён более новой версией KillSwitch. Обнови программу и попробуй снова.")
            case .damaged(let title): String(localized: "В файле неверное значение «\(title)». Ничего не изменено.")
            }
        }
    }

    /// What Settings shows, with ks's own defaults (Helper/ks `setting`, KillSwitchControl.readSettings).
    static let defaultSwitches: [String: Bool] = [
        "lan": true, "tailscale": true, "wifiguard": true, "dns": false, "direct": false, "adblock": false, "diag": false,
        "escalate": true, "blockadult": false, "blocksocial": false, "blockbetting": false,
    ]
    /// Switches files from older versions carry that are gone: skipped on load. «failover», the
    /// automatic server switch (0.10–0.19, ADR 0036).
    private static let retiredSwitches: Set<String> = ["failover"]
    private static let switchOrder = ["lan", "dns", "tailscale", "wifiguard", "direct", "adblock", "blockadult", "blocksocial",
                                      "blockbetting", "diag", "escalate"]

    /// «Сбросить»: every app setting to its default; the root switches to ks's defaults and the
    /// lists emptied. The core follows the subscription (#65).
    static var reset: Settings {
        Settings(app: Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.fallback) }),
                 root: Root(switches: defaultSwitches, exceptions: [], manualServers: [], splitApps: [], doh: "", mtu: 0))
    }

    // MARK: app settings

    struct Field: Sendable {
        enum Storage: Sendable { case plain, lines, json }
        let key: String
        let title: String
        let fallback: Value
        var storage = Storage.plain
        /// For `.int` and `.text`: the values Settings offers.
        var allowed: Set<String>?
    }

    /// The app's settings in the file, in the order changes are listed.
    static var fields: [Field] {
        [
            Field(key: "autoConnect", title: String(localized: "Подключаться автоматически"), fallback: .bool(AutoConnect.enabled(stored: nil))),
            Field(key: "autoConnectSkipTrusted", title: String(localized: "Кроме доверенных сетей Wi-Fi"),
                  fallback: .bool(AutoConnect.skipTrusted(stored: nil))),
            Field(key: "trustedNetworks", title: String(localized: "Доверенные сети Wi-Fi"), fallback: .list([])),
            Field(key: WiFiRules.key, title: String(localized: "Сети Wi‑Fi"), fallback: .rules([]), storage: .json),
            Field(key: "startMinimised", title: String(localized: "Запускать без окна"), fallback: .bool(false)),
            Field(key: "notifyVPNDropped", title: String(localized: "Уведомление: VPN оборвался"), fallback: .bool(true)),
            Field(key: "notifySubscription", title: String(localized: "Уведомление: подписка"), fallback: .bool(true)),
            Field(key: "notifyPauseEnded", title: String(localized: "Уведомление: пауза закончилась"), fallback: .bool(true)),
            Field(key: "notifyServiceOff", title: String(localized: "Уведомление: защита или служба выключены"), fallback: .bool(true)),
            Field(key: "menuBarSpeed", title: String(localized: "Скорость VPN в строке меню"), fallback: .bool(false)),
            Field(key: "pauseShort", title: String(localized: "Короткая пауза защиты, мин"), fallback: .int(5),
                  allowed: Set((1...60).map(String.init))),
            Field(key: "pauseLong", title: String(localized: "Длинная пауза защиты, мин"), fallback: .int(30),
                  allowed: Set(stride(from: 5, through: 240, by: 5).map(String.init))),
            Field(key: "subscriptionIntervalHours", title: String(localized: "Обновлять подписку, ч (0 — как просит подписка)"),
                  fallback: .int(0), allowed: ["0", "1", "3", "6", "12", "24", "48"]),
            Field(key: "showProfileGroups", title: String(localized: "Группы подписки в списке серверов"), fallback: .bool(false)),
            Field(key: "serverSort", title: String(localized: "Порядок серверов"), fallback: .text(ServerPicker.Sort.subscription.rawValue),
                  allowed: Set(ServerPicker.Sort.allCases.map(\.rawValue))),
            Field(key: "favouriteServers", title: String(localized: "Избранные серверы"), fallback: .list([]), storage: .lines),
            Field(key: ServerRecents.key, title: String(localized: "Недавние серверы"), fallback: .list([]), storage: .lines),
            Field(key: UpdateChannel.betaKey, title: String(localized: "Бета-версии"), fallback: .bool(false)),
        ]
    }

    /// Every field as the app has it now. Server identities become the servers' names now
    /// (`serverKeys`, VPNClient); one no longer in the profile is left out. Favourites and recents
    /// (kept by subscription, ADR 0036) travel as the names of the servers of `subscription` (the
    /// one in use) and of «Свои серверы»; by subscription title: #66.
    static func snapshot(_ defaults: UserDefaults, serverKeys: [String: String], subscription: String = ServerID.own,
                         ownKeys: [String: String] = [:]) -> [String: Value] {
        func byKey(_ keys: [String: String]) -> [String: String] {
            var names: [String: String] = [:]
            for (name, key) in keys where names[key] == nil || name < names[key]! { names[key] = name }
            return names
        }
        let names = byKey(serverKeys), ownNames = byKey(ownKeys)
        func name(_ line: Substring) -> String? {
            guard let server = ServerID(stored: String(line)) else { return line.hasPrefix(ServerIdentity.prefix) ? names[String(line)] : String(line) }
            guard server.subscription == subscription || server.isOwn else { return nil }
            return server.name.hasPrefix(ServerIdentity.prefix) ? (server.isOwn ? ownNames : names)[server.name] : server.name
        }
        var result: [String: Value] = [:]
        for field in fields {
            let stored: Value? = switch (field.fallback, field.storage) {
            case (.bool, _): (defaults.object(forKey: field.key) as? Bool).map(Value.bool)
            case (.int, _): (defaults.object(forKey: field.key) as? Int).map(Value.int)
            case (.text, _): defaults.string(forKey: field.key).map(Value.text)
            case (.list, .lines):
                defaults.string(forKey: field.key).map { text in
                    .list(text.split(separator: "\n").compactMap(name))
                }
            case (.list, _): defaults.stringArray(forKey: field.key).map(Value.list)
            case (.rules, _): .rules(WiFiRules.decode(defaults.data(forKey: field.key)))
            }
            result[field.key] = stored.flatMap { checked($0, field) } ?? field.fallback
        }
        return result
    }

    /// Writes where the app reads them (AppStorage, AutoConnector, Updater). Favourites and recents
    /// go to `subscription` (the one in use), the names in `own` and Xray's «… (свой)» to «Свои
    /// серверы» (ADR 0036); a name of both (`names`: the subscription's servers) to both. They replace
    /// those two's lines; the other subscriptions' stay, except when `resetting` («Сбросить»).
    static func apply(_ app: [String: Value], to defaults: UserDefaults, subscription: String = ServerID.own, own: Set<String> = [],
                      names: Set<String> = [], resetting: Bool = false) {
        for field in fields {
            var value = app[field.key]
            if [Subscriptions.favouritesKey, Subscriptions.recentsKey].contains(field.key), case .list(let list) = value {
                var lines: [String] = []
                for name in list {
                    let isOwn = own.contains(name) || name.hasSuffix(XrayManual.mark)
                    let ids = isOwn ? (names.contains(name) ? [subscription, ServerID.own] : [ServerID.own]) : [subscription]
                    for id in ids where !lines.contains(ServerID(subscription: id, name: name).stored) {
                        lines.append(ServerID(subscription: id, name: name).stored)
                    }
                }
                let others = resetting ? [] : ServerRecents.list(defaults.string(forKey: field.key) ?? "").filter { line in
                    ServerID(stored: line).map { $0.subscription != subscription && !$0.isOwn } ?? false
                }
                value = .list(lines + others)
            }
            switch value {
            case .bool(let on): defaults.set(on, forKey: field.key)
            case .int(let number): defaults.set(number, forKey: field.key)
            case .text(let text): defaults.set(text, forKey: field.key)
            case .list(let list): defaults.set(field.storage == .lines ? list.joined(separator: "\n") : list, forKey: field.key)
            case .rules(let rules): defaults.set(WiFiRules.encode(rules), forKey: field.key)
            case nil: break
            }
        }
    }

    /// The value when Settings could have set it; server identities dropped.
    private static func checked(_ value: Value, _ field: Field) -> Value? {
        switch (value, field.fallback) {
        case (.bool, .bool): return value
        case (.int(let number), .int): return field.allowed?.contains(String(number)) == false ? nil : value
        case (.text(let text), .text): return field.allowed?.contains(text) == false ? nil : value
        case (.list(let list), .list):
            let kept = list.filter { !$0.hasPrefix(ServerIdentity.prefix) }
            return kept.count <= 500 && kept.allSatisfy(HelperCommand.isName) ? .list(kept) : nil
        case (.rules(let rules), .rules):
            let good = rules.count <= 500 && rules.allSatisfy { HelperCommand.isName($0.ssid) && ($0.server.map(HelperCommand.isName) ?? true) }
            return good ? value : nil
        default: return nil
        }
    }

    // MARK: the file

    static func export(_ settings: Settings, appVersion: String, date: Date) -> Data {
        var app: [String: Any] = [:]
        for (key, value) in settings.app {
            switch value {
            case .bool(let on): app[key] = on
            case .int(let number): app[key] = number
            case .text(let text): app[key] = text
            case .list(let list): app[key] = list
            case .rules(let rules):
                app[key] = rules.map { rule -> [String: Any] in
                    var object: [String: Any] = ["ssid": rule.ssid, "autoConnect": rule.autoConnect]
                    if let server = rule.server { object["server"] = server }
                    return object
                }
            }
        }
        var object: [String: Any] = [
            "format": format, "version": version, "appVersion": appVersion,
            "exported": ISO8601DateFormatter().string(from: date), "app": app,
        ]
        if let root = settings.root {
            var part: [String: Any] = [:]
            if let switches = root.switches { part["switches"] = switches }
            if let exceptions = root.exceptions { part["exceptions"] = exceptions }
            if let servers = root.manualServers { part["manualServers"] = servers }
            if let apps = root.splitApps { part["splitApps"] = apps }
            if let doh = root.doh { part["doh"] = doh }
            if let mtu = root.mtu { part["mtu"] = mtu == 0 ? HelperCommand.mtuAuto as Any : mtu as Any }
            object["root"] = part
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// The whole file checked; what it does not name is nil (left as it is), unknown keys ignored
    /// (root "hosts" of unreleased 0.20.0 builds among them, #73).
    static func read(_ data: Data) throws -> Settings {
        guard data.count <= maxBytes, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["format"] as? String == format, let fileVersion = number(object["version"]), fileVersion >= 1 else {
            throw Problem.notSettings
        }
        guard fileVersion <= version else { throw Problem.newer }

        var app: [String: Value] = [:]
        if let part = object["app"] {
            guard let part = part as? [String: Any] else { throw Problem.damaged(String(localized: "Настройки программы")) }
            for field in fields {
                guard let raw = part[field.key] else { continue }
                guard let value = parse(raw, like: field.fallback).flatMap({ checked($0, field) }) else { throw Problem.damaged(field.title) }
                app[field.key] = value
            }
        }
        return Settings(app: app, root: try object["root"].map(readRoot))
    }

    private static func readRoot(_ raw: Any) throws -> Root {
        guard let part = raw as? [String: Any] else { throw Problem.damaged(String(localized: "Защита и служба")) }
        var root = Root()
        if let switches = part["switches"] {
            guard let dict = switches as? [String: Any] else { throw Problem.damaged(String(localized: "Что можно без VPN")) }
            var result: [String: Bool] = [:]
            for (key, value) in dict where !retiredSwitches.contains(key) {
                guard HelperCommand.switchKeys.contains(key), let on = flag(value) else { throw Problem.damaged(switchTitle(key)) }
                result[key] = on
            }
            root.switches = result
        }
        func addresses(_ key: String, _ title: String) throws -> [String]? {
            guard let raw = part[key] else { return nil }
            guard let list = raw as? [String], list.count <= 512,
                  list.allSatisfy({ Batch.address($0) == $0 && HelperCommand.isAddress($0) }) else { throw Problem.damaged(title) }
            return list
        }
        root.exceptions = try addresses("exceptions", String(localized: "Адреса без VPN"))
        root.manualServers = try addresses("manualServers", String(localized: "Адреса серверов для других VPN-программ"))
        if let raw = part["splitApps"] {
            guard let list = raw as? [String], HelperCommand.setSplitApps(list).isValid else { throw Problem.damaged(String(localized: "Программы без VPN")) }
            root.splitApps = list
        }
        if let raw = part["doh"] {
            guard let url = raw as? String, url.isEmpty || HelperCommand.isDoH(url) else { throw Problem.damaged(dohTitle) }
            root.doh = url
        }
        if let raw = part["mtu"] {
            if raw as? String == HelperCommand.mtuAuto {
                root.mtu = 0
            } else if !(raw is String), let mtu = number(raw), HelperCommand.setMTU(mtu).isValid {
                root.mtu = mtu
            } else {
                throw Problem.damaged(mtuTitle)
            }
        }
        return root
    }

    private static func parse(_ raw: Any, like fallback: Value) -> Value? {
        switch fallback {
        case .bool: return flag(raw).map(Value.bool)
        case .int: return number(raw).map(Value.int)
        case .text: return (raw as? String).map(Value.text)
        case .list: return (raw as? [Any]).flatMap { $0 as? [String] }.map(Value.list)
        case .rules:
            guard let list = raw as? [Any] else { return nil }
            var rules: [WiFiRules.Rule] = []
            for item in list {
                guard let object = item as? [String: Any], let ssid = object["ssid"] as? String else { return nil }
                let autoConnect = object["autoConnect"].map(flag) ?? true
                let server = object["server"].map { $0 as? String }
                guard let autoConnect, server != .some(nil) else { return nil }
                rules.append(WiFiRules.Rule(ssid: ssid, autoConnect: autoConnect, server: server ?? nil))
            }
            return .rules(rules)
        }
    }

    /// JSON true/false only: 1 is not a switch.
    private static func flag(_ raw: Any) -> Bool? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// A JSON whole number only: true and 1.5 are not.
    private static func number(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let exact = Int(exactly: number.doubleValue) else { return nil }
        return exact
    }

    // MARK: what changes

    struct Change: Equatable, Identifiable {
        let key: String
        let title: String
        let old: String
        let new: String
        /// Behind the administrator's authorization.
        let root: Bool
        /// A root list's entries the change adds and removes, every one: `old` and `new` show only
        /// the first three, and a hidden entry could open the internet past the kill switch.
        var added: [String] = []
        var removed: [String] = []
        /// Added networks so broad that most of the internet would go past the VPN.
        var warnings: [String] = []
        var id: String { key }
    }

    /// An address shorter than /8 (IPv4) or /16 (IPv6) covers a huge part of the internet: no one
    /// lets that past the VPN on purpose, so the sheet says it in plain words.
    /// IPv4 written as IPv6 (::ffff:0:0/96) counts as IPv4; private, local and multicast blocks
    /// (a home network) are not the internet and are not counted.
    static func broadNetworkWarning(_ entry: String) -> String? {
        guard let network = Network(entry), network.prefix < (network.isV6 ? 16 : 8), network.internetSize > 0 else { return nil }
        return network.prefix == 0 ? String(localized: "\(entry) — это весь интернет: всё пойдёт мимо VPN.")
            : String(localized: "\(entry) — это огромная часть интернета: всё, что туда идёт, пойдёт мимо VPN.")
    }

    /// Each broad entry; or, when there is none, one warning if the entries together cover more
    /// of the internet than a /8 (IPv4) or a /16 (IPv6) — 256 entries of /8 are all of it.
    static func broadNetworkWarnings(_ entries: [String]) -> [String] {
        let single = entries.compactMap(broadNetworkWarning)
        guard single.isEmpty else { return single }
        let networks = entries.compactMap(Network.init)
        let v4 = networks.filter { !$0.isV6 }.map(\.internetSize).reduce(0, +)
        let v6 = networks.filter(\.isV6).map(\.internetSize).reduce(0, +)
        guard v4 > pow(2, 24) || v6 > pow(2, 112) else { return [] }
        return [String(localized: "Вместе эти адреса — огромная часть интернета: всё, что туда идёт, пойдёт мимо VPN.")]
    }

    /// An address entry of the root lists as a network (a bare address is /32 or /128).
    private struct Network {
        let bytes: [UInt8]
        let prefix: Int
        var isV6: Bool { bytes.count == 16 }

        init(bytes: [UInt8], prefix: Int) {
            self.bytes = bytes
            self.prefix = prefix
        }

        init?(_ entry: String) {
            let parts = entry.split(separator: "/", maxSplits: 1)
            let address = String(parts[0])
            let v6 = address.contains(":")
            guard let prefix = parts.count == 2 ? Int(parts[1]) : (v6 ? 128 : 32), prefix >= 0, prefix <= (v6 ? 128 : 32) else { return nil }
            guard v6 else {
                var raw = in_addr()
                guard inet_pton(AF_INET, address, &raw) == 1 else { return nil }
                self.init(bytes: withUnsafeBytes(of: raw) { Array($0) }, prefix: prefix)
                return
            }
            var raw = in6_addr()
            guard inet_pton(AF_INET6, address, &raw) == 1 else { return nil }
            let bytes = withUnsafeBytes(of: raw) { Array($0) }
            let mapped = Network(bytes: Array(repeating: 0, count: 10) + [0xff, 0xff, 0, 0, 0, 0], prefix: 96)
            if prefix >= 96, mapped.contains(bytes) {
                self.init(bytes: Array(bytes[12...]), prefix: prefix - 96)
            } else if Network(bytes: bytes, prefix: prefix).contains(mapped.bytes) {
                self.init(bytes: [0, 0, 0, 0], prefix: 0)   // it holds all of IPv4
            } else {
                self.init(bytes: bytes, prefix: prefix)
            }
        }

        /// The first `prefix` bits are the same.
        func contains(_ address: [UInt8]) -> Bool {
            guard address.count == bytes.count else { return false }
            for bit in 0..<prefix where (bytes[bit / 8] ^ address[bit / 8]) & (0x80 >> UInt8(bit % 8)) != 0 { return false }
            return true
        }

        func contains(_ other: Network) -> Bool { other.prefix >= prefix && contains(other.bytes) }

        var size: Double { pow(2, Double(bytes.count * 8 - prefix)) }

        /// Its addresses outside the blocks that are not the internet (they do not overlap).
        var internetSize: Double {
            if Self.notInternet.contains(where: { $0.contains(self) }) { return 0 }
            return size - Self.notInternet.filter { contains($0) }.map(\.size).reduce(0, +)
        }

        private static let notInternet: [Network] = [
            "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16",
            "224.0.0.0/3", "::/128", "::1/128", "fc00::/7", "fe80::/10", "ff00::/8",
        ].compactMap(Network.init)
    }

    /// What applying `new` changes, app settings first; `current` is the whole of what there is.
    static func changes(from current: Settings, to new: Settings) -> [Change] {
        var result: [Change] = []
        for field in fields {
            guard let value = new.app[field.key], value != current.app[field.key] else { continue }
            if case .rules(let rules) = value {
                // only the rules that change, each with what it does: «Cafe → Cafe» told nothing
                let old: [WiFiRules.Rule]
                if case .rules(let now) = current.app[field.key] { old = now } else { old = [] }
                result.append(Change(key: field.key, title: field.title, old: rulesText(old.filter { !rules.contains($0) }),
                                     new: rulesText(rules.filter { !old.contains($0) }), root: false))
                continue
            }
            result.append(Change(key: field.key, title: field.title, old: current.app[field.key].map { describe($0, field) } ?? "—",
                                 new: describe(value, field), root: false))
        }
        guard let root = new.root, let now = current.root else { return result }
        for key in switchOrder {
            guard let on = root.switches?[key], on != (now.switches?[key] ?? defaultSwitches[key]) else { continue }
            result.append(Change(key: key, title: switchTitle(key), old: onOff(!on), new: onOff(on), root: true))
        }
        if let mtu = root.mtu, mtu != (now.mtu ?? 0) {
            result.append(Change(key: "mtu", title: mtuTitle, old: mtuText(now.mtu ?? 0), new: mtuText(mtu), root: true))
        }
        let lists: [(String, String, [String]?, [String]?, Bool)] = [
            ("exceptions", String(localized: "Адреса без VPN"), now.exceptions, root.exceptions, true),
            ("manualServers", String(localized: "Адреса серверов для других VPN-программ"), now.manualServers, root.manualServers, true),
            ("splitApps", String(localized: "Программы без VPN"), now.splitApps, root.splitApps, false),
        ]
        if let doh = root.doh, doh != (now.doh ?? "") {
            result.append(Change(key: "doh", title: dohTitle, old: dohText(now.doh ?? ""), new: dohText(doh), root: true))
        }
        for (key, title, old, new, addresses) in lists {
            // the lists are sets to ks: another order is no change
            guard let new, Set(new) != Set(old ?? []) else { continue }
            let old = old ?? []
            let added = new.filter { !old.contains($0) }
            result.append(Change(key: key, title: title, old: listText(old), new: listText(new), root: true,
                                 added: added, removed: old.filter { !new.contains($0) },
                                 warnings: addresses ? broadNetworkWarnings(added) : []))
        }
        return result
    }

    /// The `ks` commands that turn `current` into `new`, as Settings builds them (Batch).
    static func rootCommands(helper: String, current: Root, new: Root) -> [[String]] {
        var commands: [[String]] = []
        if let switches = new.switches {
            // a switch the current set does not name is at its default (one added after the file was made)
            commands += Batch.settings(helper: helper, old: defaultSwitches.merging(current.switches ?? [:]) { $1 }, new: switches)
        }
        if let list = new.exceptions {
            commands += Batch.list(helper: helper, add: "allow", remove: "unallow", old: current.exceptions ?? [], new: list)
        }
        if let list = new.manualServers {
            commands += Batch.list(helper: helper, add: "server-add", remove: "server-remove", old: current.manualServers ?? [], new: list)
        }
        if let apps = new.splitApps, Set(apps) != Set(current.splitApps ?? []) {
            commands.append([helper, "set", "splitapps", SplitApps.argument(apps)])
        }
        if let doh = new.doh, doh != (current.doh ?? "") {
            commands.append([helper, "set", "doh", doh])
        }
        if let mtu = new.mtu, mtu != (current.mtu ?? 0) {
            commands.append([helper] + HelperCommand.setMTU(mtu == 0 ? nil : mtu).arguments)
        }
        return commands
    }

    private static func describe(_ value: Value, _ field: Field) -> String {
        switch value {
        case .bool(let on): onOff(on)
        case .int(let number): String(number)
        case .text(let text): ServerPicker.Sort(rawValue: text)?.title ?? text
        case .list(let list): listText(list)
        case .rules(let rules): listText(rules.map(\.ssid))
        }
    }

    private static var dohTitle: String { String(localized: "Свой сервер DNS-over-HTTPS") }
    private static func dohText(_ url: String) -> String { url.isEmpty ? String(localized: "нет") : url }
    static let mtuTitle = String(localized: "Размер пакетов VPN (MTU)")
    private static func mtuText(_ mtu: Int) -> String { mtu == 0 ? String(localized: "Авто") : String(mtu) }

    private static func onOff(_ on: Bool) -> String { on ? String(localized: "вкл") : String(localized: "выкл") }

    /// «Cafe: подключаться, сервер 🇳🇱 Нидерланды; Home: не подключаться», at most three.
    private static func rulesText(_ rules: [WiFiRules.Rule]) -> String {
        guard !rules.isEmpty else { return String(localized: "нет") }
        let shown = rules.prefix(3).map { rule in
            let connect = rule.autoConnect ? String(localized: "подключаться") : String(localized: "не подключаться")
            let server = rule.server.map { String(localized: "сервер \(ServerName.display($0))") }
            return "\(rule.ssid): " + ([connect] + (server.map { [$0] } ?? [])).joined(separator: ", ")
        }.joined(separator: "; ")
        return rules.count > 3 ? shown + " " + String(localized: "и ещё \(rules.count - 3)") : shown
    }

    private static func listText(_ list: [String]) -> String {
        guard !list.isEmpty else { return String(localized: "нет") }
        let shown = list.prefix(3).joined(separator: ", ")
        return list.count > 3 ? shown + " " + String(localized: "и ещё \(list.count - 3)") : shown
    }

    private static func switchTitle(_ key: String) -> String {
        switch key {
        case "lan": String(localized: "Доступ к домашней сети")
        case "dns": String(localized: "Адреса сайтов через роутер")
        case "tailscale": "Tailscale, NetBird"
        case "wifiguard": String(localized: "Отключать сеть при выключении Mac")
        case "direct": String(localized: "Пускать dropweb мимо VPN (слабее защиты)")
        case "adblock": String(localized: "Блокировать рекламу и трекеры")
        case "blockadult": String(localized: "Блокировать сайты для взрослых")
        case "blocksocial": String(localized: "Блокировать соцсети")
        case "blockbetting": String(localized: "Блокировать букмекеров")
        case "diag": String(localized: "Подробная диагностика (все соединения)")
        case "escalate": String(localized: "Пробовать другой отпечаток и транспорт, если сервер не отвечает")
        default: key
        }
    }
}
