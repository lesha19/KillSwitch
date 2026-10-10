import Foundation

/// «Проверка утечек»: parsing of the public echo services and the verdict. The network part lives
/// in LeakTester; everything here is pure.
///
/// Sources: api.ipify.org (plain text) and ipv4.am.i.mullvad.net/json for the public IPv4 — two
/// independent services; ipv6.am.i.mullvad.net/json for IPv6; bash.ws for DNS (GET /id, resolve
/// `<n>.<id>.bash.ws`, then GET /dnsleak/test/<id>?json lists the resolvers that asked).
///
/// "Home" (the provider's own address and organisation) is learnt from a check run while the VPN
/// is off; without it a resolver of the provider cannot be told from the VPN's.
enum LeakCheck {
    struct Address: Equatable {
        var ip: String
        var country: String?
        var org: String?
    }

    struct Resolver: Equatable, Identifiable {
        var ip: String
        var country: String?
        var org: String?
        var id: String { ip }
    }

    /// What the Mac looks like without the VPN; stored by the app, never sent anywhere.
    struct Direct: Codable, Equatable {
        var ipv4: String?
        var ipv6: String?
        var org: String?
    }

    struct DNSReport: Equatable {
        /// The address that fetched the result, as bash.ws saw it.
        var exit: Address?
        var resolvers: [Resolver]
    }

    enum Failure: Error { case format }

    static let dnsHost = "bash.ws"

    // MARK: parsing

    /// An IPv4 or IPv6 address and nothing else (captive portals answer with HTML).
    static func plainIP(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, trimmed, &v4) == 1 || inet_pton(AF_INET6, trimmed, &v6) == 1 { return trimmed }
        return nil
    }

    /// am.i.mullvad.net/json
    static func mullvad(_ data: Data) -> Address? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ip = (object["ip"] as? String).flatMap(plainIP) else { return nil }
        return Address(ip: ip, country: nonEmpty(object["country"]), org: nonEmpty(object["organization"]))
    }

    /// bash.ws/id: letters and digits only, since it becomes part of a domain name.
    static func dnsID(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.wholeMatch(of: /[A-Za-z0-9]{8,64}/) != nil ? trimmed : nil
    }

    static func probeNames(id: String, count: Int) -> [String] {
        (1...max(count, 1)).map { "\($0).\(id).\(dnsHost)" }
    }

    /// bash.ws/dnsleak/test/<id>?json: entries of type "ip" (who fetched), "dns" (resolvers) and
    /// "conclusion" (ignored: it calls any resolver abroad a leak).
    static func bashWs(_ data: Data) throws -> DNSReport {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw Failure.format }
        var report = DNSReport(exit: nil, resolvers: [])
        for entry in entries {
            guard let ip = (entry["ip"] as? String).flatMap(plainIP) else { continue }
            let country = nonEmpty(entry["country_name"]), org = nonEmpty(entry["org"])
            switch entry["type"] as? String {
            case "ip": if report.exit == nil { report.exit = Address(ip: ip, country: country, org: org) }
            case "dns": if !report.resolvers.contains(where: { $0.ip == ip }) { report.resolvers.append(Resolver(ip: ip, country: country, org: org)) }
            default: continue
            }
        }
        return report
    }

    // MARK: verdict

    struct Input {
        var vpnConnected: Bool
        /// One per IPv4 endpoint, nil where it did not answer.
        var ipv4: [String?]
        /// Who we are on IPv4, with the organisation (Mullvad's or bash.ws's answer).
        var exit: Address?
        var ipv6: Address?
        var resolvers: [Resolver]
        var direct: Direct?
        /// Physical interfaces through which an ordinary program reached the internet directly
        /// while protection was on (LeakTester probes them only then).
        var directExits: [String] = []
    }

    enum Finding: Equatable {
        case directExit([String])
        case realIPv4
        case ipv4Mismatch([String])
        case ipv6Leak(String)
        case ipv6Unexpected(String)
        case dnsLeak([String])
        case dnsUnknown
        case offline
        case vpnOff

        var isLeak: Bool {
            switch self {
            case .directExit, .realIPv4, .ipv4Mismatch, .ipv6Leak, .dnsLeak: true
            case .ipv6Unexpected, .dnsUnknown, .offline, .vpnOff: false
            }
        }

        var text: String {
            switch self {
            case .directExit(let names): "Программы могут выйти в интернет мимо VPN (\(names.joined(separator: ", "))): защита пропускает их напрямую."
            case .realIPv4: "Сайты видят твой настоящий адрес, а не адрес VPN."
            case .ipv4Mismatch(let ips): "Два сервиса видят разные адреса (\(ips.joined(separator: ", "))): часть трафика идёт другим путём."
            case .ipv6Leak(let ip): "IPv6 идёт мимо VPN: сайты видят адрес твоей сети \(ip)."
            case .ipv6Unexpected(let ip): "Доступен IPv6 (\(ip)), хотя VPN его не пропускает. Проверь, не работает ли другой VPN или прокси."
            case .dnsLeak(let ips): "Адреса сайтов узнаются у твоего провайдера (\(ips.joined(separator: ", "))): он видит, куда ты ходишь."
            case .dnsUnknown: "Проверка DNS не дала ответа. Повтори позже."
            case .offline: "Интернета нет. Если VPN выключен, а защита включена, так и должно быть: мимо VPN ничего не уходит."
            case .vpnOff: "VPN не подключён: это твой обычный адрес. Он запомнен, чтобы потом сравнить с ним проверку через VPN."
            }
        }
    }

    struct Verdict: Equatable {
        var findings: [Finding]
        /// Learnt when the check ran without the VPN.
        var home: Direct?
        /// Connected, but there is no home reference to compare resolvers with.
        var needsHomeReference = false

        var clean: Bool { !findings.contains(where: \.isLeak) }

        var title: String {
            if !clean { return "Есть утечки" }
            if findings.contains(.vpnOff) { return "VPN не подключён" }
            if findings.contains(.offline) { return "Нет интернета" }
            return "Утечек нет"
        }
    }

    static func verdict(_ input: Input) -> Verdict {
        var seen: [String] = []
        for case let ip? in input.ipv4 where !seen.contains(ip) { seen.append(ip) }
        let exits: [Finding] = input.directExits.isEmpty ? [] : [.directExit(input.directExits)]
        if seen.isEmpty, input.exit == nil, input.ipv6 == nil, input.resolvers.isEmpty {
            return Verdict(findings: exits + [.offline])
        }
        guard input.vpnConnected else {
            let home = Direct(ipv4: seen.first ?? input.exit?.ip, ipv6: input.ipv6?.ip,
                              org: input.exit?.org ?? input.ipv6?.org)
            return Verdict(findings: exits + [.vpnOff], home: home)
        }
        let direct = input.direct
        var findings = exits
        if let home = direct?.ipv4, seen.contains(home) || input.exit?.ip == home { findings.append(.realIPv4) }
        if seen.count > 1 { findings.append(.ipv4Mismatch(seen)) }

        if let v6 = input.ipv6 {
            if sameNetwork(v6.ip, direct?.ipv6) || sameOrg(v6.org, direct?.org) {
                findings.append(.ipv6Leak(v6.ip))
            } else if !sameOrg(v6.org, input.exit?.org) {
                findings.append(.ipv6Unexpected(v6.ip))
            }
        }

        if input.resolvers.isEmpty {
            findings.append(.dnsUnknown)
        } else if let direct {
            let leaked = input.resolvers.filter {
                $0.ip == direct.ipv4 || $0.ip == direct.ipv6 || sameNetwork($0.ip, direct.ipv6) || sameOrg($0.org, direct.org)
            }
            if !leaked.isEmpty { findings.append(.dnsLeak(leaked.map(\.ip))) }
        }
        return Verdict(findings: findings, needsHomeReference: direct == nil)
    }

    // MARK: -

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    private static func sameOrg(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b, !a.isEmpty else { return false }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// Same IPv6 /64: the home network hands out addresses from one prefix.
    private static func sameNetwork(_ a: String, _ b: String?) -> Bool {
        guard let b else { return false }
        var x = in6_addr(), y = in6_addr()
        guard inet_pton(AF_INET6, a, &x) == 1, inet_pton(AF_INET6, b, &y) == 1 else { return false }
        return withUnsafeBytes(of: x) { Array($0.prefix(8)) } == withUnsafeBytes(of: y) { Array($0.prefix(8)) }
    }
}
