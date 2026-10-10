import Foundation
import Observation

/// Runs «Проверка утечек» (see LeakCheck for the sources and the verdict). Requests go through
/// the system like any app's, over an ephemeral session: no cookies, no cache, no custom headers,
/// nothing of ours in them besides the random bash.ws id.
@MainActor
@Observable
final class LeakTester {
    struct Result {
        var verdict: LeakCheck.Verdict
        var ipv4: [(source: String, ip: String?)]
        var exit: LeakCheck.Address?
        var ipv6: LeakCheck.Address?
        var resolvers: [LeakCheck.Resolver]
        var at: Date
    }

    private(set) var running = false
    private(set) var step = ""
    private(set) var result: Result?
    private(set) var home: LeakCheck.Direct?
    private(set) var homeDate: Date?

    private static let homeKey = "leakHome"
    private static let homeDateKey = "leakHomeDate"
    nonisolated private static let probes = 6

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.homeKey) {
            home = try? JSONDecoder().decode(LeakCheck.Direct.self, from: data)
        }
        homeDate = UserDefaults.standard.object(forKey: Self.homeDateKey) as? Date
    }

    func forgetHome() {
        home = nil
        homeDate = nil
        UserDefaults.standard.removeObject(forKey: Self.homeKey)
        UserDefaults.standard.removeObject(forKey: Self.homeDateKey)
    }

    /// `vpnConnected`: read when the check starts (any VPN tunnel up, ours or another client's).
    /// `probe`: the direct-exit check (KillSwitchControl.probeDirectExits), passed only while
    /// protection is on — then nothing may get out around the VPN.
    func run(vpnConnected: Bool, probe: (() async -> [String])? = nil) async {
        guard !running else { return }
        running = true
        defer { running = false; step = "" }
        var directExits: [String] = []
        if let probe {
            step = "Проверяю выход мимо VPN…"
            directExits = await probe()
        }
        let session = URLSession(configuration: Self.configuration)
        defer { session.finishTasksAndInvalidate() }

        step = "Узнаю адрес IPv4 и IPv6…"
        async let ipify = Self.text(session, "https://api.ipify.org")
        async let mullvad4 = Self.data(session, "https://ipv4.am.i.mullvad.net/json")
        async let mullvad6 = Self.data(session, "https://ipv6.am.i.mullvad.net/json")
        let ipv4a = await ipify.flatMap(LeakCheck.plainIP)
        let exit4 = await mullvad4.flatMap(LeakCheck.mullvad)
        let ipv6 = await mullvad6.flatMap(LeakCheck.mullvad).flatMap { $0.ip.contains(":") ? $0 : nil }

        step = "Проверяю DNS…"
        let report = await Self.dnsReport(session)
        let exit = exit4 ?? report?.exit

        let input = LeakCheck.Input(vpnConnected: vpnConnected, ipv4: [ipv4a, exit4?.ip], exit: exit, ipv6: ipv6,
                                    resolvers: report?.resolvers ?? [], direct: home, directExits: directExits)
        let verdict = LeakCheck.verdict(input)
        if let learnt = verdict.home { saveHome(learnt) }
        result = Result(verdict: verdict, ipv4: [("ipify.org", ipv4a), ("mullvad.net", exit4?.ip)], exit: exit,
                        ipv6: ipv6, resolvers: report?.resolvers ?? [], at: Date())
    }

    private func saveHome(_ direct: LeakCheck.Direct) {
        home = direct
        homeDate = Date()
        UserDefaults.standard.set(try? JSONEncoder().encode(direct), forKey: Self.homeKey)
        UserDefaults.standard.set(homeDate, forKey: Self.homeDateKey)
    }

    // MARK: network

    private static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return configuration
    }

    /// bash.ws: get an id, make the system resolve `<n>.<id>.bash.ws`, then ask who resolved them.
    nonisolated private static func dnsReport(_ session: URLSession) async -> LeakCheck.DNSReport? {
        guard let id = await text(session, "https://\(LeakCheck.dnsHost)/id").flatMap(LeakCheck.dnsID) else { return nil }
        let names = LeakCheck.probeNames(id: id, count: probes)
        await withTaskGroup(of: Void.self) { group in
            for name in names {
                // the system resolver, as any app would ask it; then a connection, so a VPN core with
                // fake-IP DNS resolves the name for real (on its server)
                group.addTask { _ = await resolve(name) }
                group.addTask { _ = await data(session, "https://\(name)/", timeout: 4) }
            }
        }
        try? await Task.sleep(for: .seconds(2))
        guard let body = await data(session, "https://\(LeakCheck.dnsHost)/dnsleak/test/\(id)?json") else { return nil }
        return try? LeakCheck.bashWs(body)
    }

    nonisolated private static func data(_ session: URLSession, _ url: String, timeout: TimeInterval = 8) async -> Data? {
        guard let url = URL(string: url) else { return nil }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return data
    }

    nonisolated private static func text(_ session: URLSession, _ url: String) async -> String? {
        await data(session, url).map { String(decoding: $0.prefix(256), as: UTF8.self) }
    }

    /// getaddrinfo off the main thread; the answer itself does not matter.
    nonisolated private static func resolve(_ host: String) async -> Bool {
        await Task.detached {
            var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                                 ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var list: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, nil, &hints, &list)
            if let list { freeaddrinfo(list) }
            return status == 0
        }.value
    }
}
