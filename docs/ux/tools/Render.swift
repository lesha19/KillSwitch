// UX audit renderer: draws the app's real SwiftUI views with fake state into PNGs, light and dark.
// Built by docs/ux/tools/render.sh from patched copies of App/ (see prepare.py); never part of the app.
import AppKit
import SwiftUI

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "screens")
let iconDir = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : nil

// MARK: fake data

let servers = ["🇩🇪 Германия", "🇳🇱 Нидерланды", "🇱🇹 Литва", "🇫🇮 Финляндия", "🇺🇸 США", "🇷🇺 Россия (обход)"]
let history = ["🇩🇪 Германия": 48, "🇳🇱 Нидерланды": 61, "🇱🇹 Литва": 37, "🇫🇮 Финляндия": 182, "🇺🇸 США": 412]

func proxies(selected: String = "⚡ Авто", auto: String = "🇱🇹 Литва", manual: [String] = []) -> CoreProxies {
    var dict: [String: Any] = [
        "🚀 Выбор сервера": ["type": "Selector", "now": selected, "all": ["⚡ Авто"] + servers + (manual.isEmpty ? [] : ["Свои серверы"])],
        "⚡ Авто": ["type": "URLTest", "now": auto, "all": Array(servers.prefix(5)), "history": [["delay": history[auto] ?? 50]]],
    ]
    if !manual.isEmpty { dict["Свои серверы"] = ["type": "Selector", "now": manual[0], "all": manual] }
    for name in servers + manual {
        var info: [String: Any] = ["type": "Vless"]
        if let delay = history[name] { info["history"] = [["delay": delay]] }
        dict[name] = info
    }
    let data = try! JSONSerialization.data(withJSONObject: ["proxies": dict])
    return try! CoreProxies(data: data, order: ["🚀 Выбор сервера", "⚡ Авто", "Свои серверы"])
}

@MainActor struct World {
    let control = KillSwitchControl()
    let client: VPNClient
    let auto: AutoConnector
    let tester = LeakTester()

    @MainActor init() {
        client = VPNClient(control: control)
        auto = AutoConnector(control: control, client: client)
        control.state = .on
        control.coreInstalled = true
        control.coreConfigured = true
        control.servers = ["1.2.3.10", "1.2.3.14", "1.2.3.17"]
    }

    /// Subscription with traffic and expiry.
    @MainActor func subscribe(used: Double = 38.4, total: Double? = 100, days: Double = 23) {
        client.hasURL = true
        client.maskedURL = "https://sub.example.net/•••••k9Qz"
        let gb = 1_073_741_824.0
        var usage = SubscriptionUsage(header: "upload=1; download=1")!
        usage.upload = Int64(used * gb * 0.1)
        usage.download = Int64(used * gb * 0.9)
        usage.total = total.map { Int64($0 * gb) }
        usage.expire = Date().addingTimeInterval(days * 86400)
        client.status = VPNClient.Status(title: "StorkVPN · Премиум", usage: usage, lastUpdate: Date().addingTimeInterval(-47 * 60))
    }

    @MainActor func connect(selected: String = "⚡ Авто") {
        control.coreRunning = true
        control.vpnUp = true
        control.ownTunnelUp = true
        control.proxies = proxies(selected: selected)
    }
}

/// The wizard's step and install state for the next snapshot (prepare.py wires OnboardingView to it).
@MainActor var renderOnboarding: (step: Onboarding.Step, installed: Bool) = (.welcome, false)
/// What «Проверить адрес» starts with (prepare.py wires TrafficView to it).
@MainActor var renderTrafficQuery = ""

/// A typical Russian subscription as the helper reports it (Helper/ks core_report), with ad blocking on.
func routingReport() -> RoutingReport {
    let json = """
    {"version":1,
     "rules":[{"rule":"GEOSITE,category-ads-all,REJECT","from":"killswitch"},
              {"rule":"AND,((NETWORK,UDP),(DST-PORT,443)),REJECT","from":"subscription","index":0},
              {"rule":"DOMAIN-SUFFIX,storkvpn.online,DIRECT","from":"subscription","index":1},
              {"rule":"RULE-SET,ru-inline,DIRECT","from":"subscription","index":2},
              {"rule":"RULE-SET,ru-blocked,🚀 Выбор сервера","from":"subscription","index":3},
              {"rule":"GEOSITE,category-ru,DIRECT","from":"subscription","index":4},
              {"rule":"GEOIP,RU,DIRECT","from":"subscription","index":5},
              {"rule":"PROCESS-NAME,Telegram,🚀 Выбор сервера","from":"subscription","index":7},
              {"rule":"MATCH,🚀 Выбор сервера","from":"subscription","index":8}],
     "dropped":[{"section":"rules","index":6,"item":"IP-ASN,13238,DIRECT","reason":"geodata:asn"},
                {"section":"sniffer","item":"sniff.SSH","reason":"not-allowed"}],
     "providers":[{"name":"ru-inline","type":"inline","behavior":"domain","count":6,
                   "payload":["+.gosuslugi.ru","+.sberbank.ru","+.tbank.ru","+.yandex.ru","+.vk.com","+.ozon.ru"]},
                  {"name":"ru-blocked","type":"http","behavior":"domain","format":"mrs","host":"raw.githubusercontent.com","interval":86400,"proxy":"KS-DNS"}],
     "groups":[{"name":"🚀 Выбор сервера","type":"select","proxies":["⚡ Авто","🇱🇹 Литва","🇩🇪 Германия","DIRECT"],"from":"subscription"},
               {"name":"KS-DNS","type":"fallback","proxies":["🇱🇹 Литва","🇩🇪 Германия"],"from":"killswitch","hidden":true}],
     "proxies":[{"name":"🇱🇹 Литва","type":"vless"},{"name":"🇩🇪 Германия","type":"vless"}],
     "added":[{"kind":"dns-group","name":"KS-DNS","items":["🇱🇹 Литва","🇩🇪 Германия"]},
              {"kind":"dns-servers","items":["https://1.1.1.1/dns-query#KS-DNS","https://8.8.8.8/dns-query#KS-DNS"]},
              {"kind":"failover","name":"🇱🇹 Литва ↻","items":["🇱🇹 Литва","🇱🇹 Литва 2"]},
              {"kind":"pinning","items":[{"host":"lt.example.net","address":"1.2.3.10"}]},
              {"kind":"provider-proxy","items":["ru-blocked"]},
              {"kind":"sniffer","items":[]},
              {"kind":"adblock","items":["GEOSITE,category-ads-all,REJECT"]}],
     "sniffer":{"from":"killswitch","value":{"enable":true,"override-destination":false}},
     "dns":{"servers":["https://1.1.1.1/dns-query#KS-DNS","https://8.8.8.8/dns-query#KS-DNS"],
            "taken":{"direct-nameserver":["77.88.8.8"]}},
     "egress":["rules","dns"]}
    """
    return try! RoutingReport(data: Data(json.utf8))
}

/// Open connections of a usual evening: banks direct, the rest through the VPN, an ad blocked.
func connections() -> CoreConnections {
    func c(_ id: String, _ host: String, _ ip: String, _ process: String, _ path: String, _ rule: String, _ payload: String,
           _ chains: [String], _ down: Int64, _ up: Int64, _ ago: TimeInterval) -> CoreConnections.Connection {
        CoreConnections.Connection(id: id, host: host, ip: ip, port: "443", network: "tcp", process: process, processPath: path,
                                   rule: rule, rulePayload: payload, chains: chains, upload: up, download: down,
                                   start: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-ago)))
    }
    let vpn = ["🇱🇹 Литва", "⚡ Авто", "🚀 Выбор сервера"]
    let safari = "/Applications/Safari.app/Contents/MacOS/Safari"
    return CoreConnections(connections: [
        c("1", "www.youtube.com", "142.250.74.14", "Safari", safari, "Match", "", vpn, 48_300_000, 410_000, 312),
        c("2", "online.sberbank.ru", "194.54.14.168", "Safari", safari, "RuleSet", "ru-inline", ["DIRECT"], 1_240_000, 88_000, 45),
        c("3", "", "149.154.167.51", "Telegram", "/Applications/Telegram.app/Contents/MacOS/Telegram", "ProcessName", "Telegram", vpn, 3_100_000, 640_000, 4_210),
        c("4", "music.yandex.ru", "213.180.204.62", "Music", "/System/Applications/Music.app/Contents/MacOS/Music", "RuleSet", "ru-inline", ["DIRECT"], 22_500_000, 120_000, 1_830),
        c("5", "mc.yandex.ru", "", "Safari", safari, "GeoSite", "category-ads-all", ["REJECT"], 0, 0, 3),
        c("6", "api.example.org", "140.82.121.5", "curl", "/usr/bin/curl", "Match", "", vpn, 52_000, 9_000, 12),
        c("7", "www.gosuslugi.ru", "213.59.254.7", "Firefox", "/Applications/Firefox.app/Contents/MacOS/firefox", "RuleSet", "ru-inline", ["DIRECT"], 860_000, 41_000, 96),
    ], providers: ["ru-blocked": .init(count: 74_812, updatedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3 * 3600)))])
}

// MARK: rendering

@MainActor
func snapshot<V: View>(_ name: String, width: CGFloat, height: CGFloat? = nil, title: String? = nil,
                       background: Bool = true, @ViewBuilder _ view: () -> V) {
    // UX_ONLY=05,50: only screens whose names start with one of these
    if let only = ProcessInfo.processInfo.environment["UX_ONLY"],
       !only.split(separator: ",").contains(where: { name.hasPrefix($0) }) { return }
    for dark in [false, true] {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let content = view()
            .frame(width: width)
            .frame(height: height)
            .background(background ? Color(nsColor: .windowBackgroundColor) : .clear)
            .environment(\.colorScheme, dark ? .dark : .light)
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height ?? 600),
                              styleMask: title == nil ? [.borderless] : [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = appearance
        window.title = title ?? ""
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let size = NSSize(width: width, height: height ?? hosting.fittingSize.height)
        window.setContentSize(size)
        window.orderFrontRegardless()   // off-screen; SwiftUI draws only into a visible window
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        hosting.layoutSubtreeIfNeeded()
        let target: NSView = title == nil ? hosting : (hosting.superview ?? hosting)
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { continue }
        appearance.performAsCurrentDrawingAppearance { target.cacheDisplay(in: target.bounds, to: rep) }
        let file = outDir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
        window.orderOut(nil)
        print(file.lastPathComponent)
    }
}

/// The menu bar popover (MenuBarExtra .window): the main screen at 340.
@MainActor
func popover(_ name: String, _ world: World) {
    snapshot(name, width: 340) {
        HomeView(style: .popover).environment(world.control).environment(world.client).environment(Updater())
    }
}

@MainActor
func main() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    // the app's template images (Assets.xcassets) under their names, for Image("MenuBar…")
    for file in (try? FileManager.default.contentsOfDirectory(at: iconDir ?? outDir, includingPropertiesForKeys: nil)) ?? []
    where file.pathExtension == "svg" {
        guard let image = NSImage(contentsOf: file) else { continue }
        image.isTemplate = true
        image.setName(file.deletingPathExtension().lastPathComponent)
    }
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    /// The one window (ADR 0008) at a section: sidebar on the left, the section on the right.
    /// `height` is the window's content height; the default is its size on first launch.
    func shot(_ name: String, _ section: AppSection, height: CGFloat = 640, _ world: World) {
        Router.shared.section = section
        snapshot(name, width: 860, height: height, title: "KillSwitch") {
            mainWindow(world)
        }
    }

    func window(_ name: String, height: CGFloat = 640, _ world: World) {
        shot(name, .home, height: min(max(height, 640), 760), world)
    }

    func picker(_ name: String, _ world: World) {
        shot(name, .servers, world)
    }

    // MARK: main window

    do { // 01 first run: nothing installed
        let w = World()
        w.control.state = .notInstalled
        w.control.coreInstalled = false
        w.control.coreConfigured = false
        window("01-window-not-installed", height: 560, w)
    }
    do { // 02 installed, no subscription yet
        let w = World()
        w.control.coreConfigured = false
        window("02-window-onboarding-no-subscription", w)
    }
    do { // 03 configured, disconnected, protection on: no internet
        let w = World()
        w.subscribe()
        w.control.proxies = nil
        window("03-window-disconnected-protection-on", height: 760, w)
    }
    do { // 04 connecting
        let w = World()
        w.subscribe()
        w.connect()
        w.control.ownTunnelUp = false
        w.control.vpnUp = false
        window("04-window-connecting", height: 760, w)
    }
    do { // 05 connected, subscription with traffic and expiry
        let w = World()
        w.subscribe()
        w.connect()
        window("05-window-connected", height: 1000, w)
        window("05b-window-connected-first-screen", height: 680, w)
    }
    do { // 06 latency test: some servers time out, sorted by latency
        let w = World()
        w.subscribe()
        w.connect(selected: "🇩🇪 Германия")
        w.control.measured = ["🇩🇪 Германия": 52, "🇳🇱 Нидерланды": 70, "🇱🇹 Литва": 41, "🇫🇮 Финляндия": -1, "🇺🇸 США": -1, "🇷🇺 Россия (обход)": 23]
        w.control.measured["🇫🇮 Финляндия"] = CoreDelay.timeout
        w.control.measured["🇺🇸 США"] = CoreDelay.timeout
        w.control.coreError = UserError.from(raw: "no server of ⚡ Авто answered", context: .latency)
        UserDefaults.standard.set(true, forKey: "sortByLatency")
        UserDefaults.standard.set("🇳🇱 Нидерланды", forKey: "favouriteServers")
        picker("06-window-servers-latency-timeouts", w)
        UserDefaults.standard.removeObject(forKey: "sortByLatency")
        UserDefaults.standard.removeObject(forKey: "favouriteServers")
    }
    do { // 06b server choice, profile order, entry segment shown with double VPN
        let w = World()
        w.subscribe()
        w.connect(selected: "⚡ Авто")
        picker("06b-window-servers", w)
        w.control.multihopEntry = "🇱🇹 Литва"
        picker("06c-window-servers-double-vpn", w)
    }
    do { // 07 double VPN
        let w = World()
        w.subscribe()
        w.connect(selected: "🇳🇱 Нидерланды")
        w.control.multihopEntry = "🇱🇹 Литва"
        window("07-window-double-vpn", height: 680, w)
    }
    do { // 08 the VPN on, protection off, the core restarting (ADR 0035): the internet closed
        let w = World()
        w.subscribe()
        w.connect()
        w.control.coreRunning = false
        w.control.ownTunnelUp = false
        w.control.vpnUp = false
        w.control.vpnOn = true
        w.control.state = .off
        window("08-window-reconnecting", height: 1000, w)
    }
    do { // 09 paused, disconnected
        let w = World()
        w.subscribe()
        w.control.state = .paused(until: Date().addingTimeInterval(25 * 60))
        window("09-window-paused", height: 760, w)
    }
    do { // 10 another VPN next to ours + daemon disabled
        let w = World()
        w.subscribe()
        w.connect()
        w.control.ownTunnelUp = false
        w.control.foreignVPN = "utun6"
        w.control.daemonProblem = true
        window("10-window-foreign-vpn-daemon-off", height: 860, w)
    }
    do { // 11 another app's VPN (Happ), ours not running, protection on (ADR 0009)
        let w = World()
        w.subscribe()
        w.control.vpnUp = true
        w.control.otherVPNName = "Happ"
        w.control.otherVPNServices = [OtherVPN.Service(id: "AAAAAAAA-0000-4000-8000-000000000001", name: "Happ", provider: "su.ffg.happ", connected: true)]
        window("11-window-other-app-vpn", height: 760, w)
    }
    do { // 12 needs confirmation + needs password + subscription ending
        let w = World()
        w.subscribe(used: 96, total: 100, days: 2)
        w.connect()
        w.client.needsConfirmation = true
        w.client.needsPassword = true
        window("12-window-confirm-new-servers-expiring", height: 1060, w)
    }
    do { // 13 errors: device limit, helper error, server list unavailable
        let w = World()
        w.subscribe()
        w.control.coreRunning = true
        w.control.vpnUp = true
        w.control.ownTunnelUp = true
        w.control.proxiesError = UserError.from(raw: "dial unix /Library/KillSwitch/core/ctl/mihomo.sock: connect: no such file or directory", context: .serverList)
        w.client.lastError = UserError.from(raw: "x-hwid-max-devices-reached", context: .subscription)
        w.control.error = UserError.from(raw: "sudo: a password is required", context: .helper)
        window("13-window-errors", height: 860, w)
    }
    do { // 14 helper installed, core missing (older install)
        let w = World()
        w.control.coreInstalled = false
        w.control.coreConfigured = false
        window("14-window-core-missing", height: 620, w)
    }
    do { // 15 server list loading
        let w = World()
        w.subscribe()
        w.control.coreRunning = true
        window("15-window-servers-loading", height: 760, w)
    }
    do { // 16 subscription expired, connected with manual servers only
        let w = World()
        w.subscribe(used: 12, total: nil, days: -3)
        w.connect()
        w.client.lastError = UserError.from(raw: "HTTP 404", context: .subscription)
        window("16-window-subscription-expired", height: 1000, w)
    }
    do { // 17 failover: switched to another server of the country (status line)
        let w = World()
        w.subscribe()
        w.connect(selected: "🇱🇹 Литва")
        w.control.lastSwitch = Failover.Switch(from: "🇱🇹 Литва 1", to: "🇱🇹 Литва 2", at: Date().addingTimeInterval(-12 * 60))
        window("17-window-failover-switched", height: 760, w)
    }
    do { // 18 the whole chosen country is down
        let w = World()
        w.subscribe()
        w.connect(selected: "🇱🇹 Литва")
        w.control.serversDown = "Литва"
        window("18-window-country-down", height: 860, w)
    }
    do { // 19 nothing answers: mobile «white lists»
        let w = World()
        w.subscribe()
        w.connect()
        w.control.networkCause = .whitelist
        window("19-window-cause-whitelist", height: 900, w)
    }
    do { // 19b nothing answers: our servers are blocked
        let w = World()
        w.subscribe()
        w.connect()
        w.control.networkCause = .serversBlocked
        window("19b-window-cause-servers-blocked", height: 900, w)
    }

    // MARK: first-run wizard

    /// The wizard is a sheet of the window: drawn alone (a sheet has no title bar), and once over
    /// the window it belongs to (59).
    func wizard(_ name: String, _ step: Onboarding.Step, installed: Bool = false, _ w: World) {
        renderOnboarding = (step, installed)
        snapshot(name, width: 520, height: 440) {
            OnboardingView().environment(w.control).environment(w.client).environment(w.tester).environment(w.auto)
        }
    }

    do {
        let w = World()
        w.control.state = .notInstalled
        w.control.coreInstalled = false
        w.control.coreConfigured = false
        renderOnboarding = (.welcome, false)
        Router.shared.section = .home
        snapshot("59-window-wizard-sheet", width: 860, height: 640, title: "KillSwitch") {
            ZStack(alignment: .top) {
                mainWindow(w)
                Color.black.opacity(0.18)
                OnboardingView().environment(w.control).environment(w.client).environment(w.tester).environment(w.auto)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(radius: 18, y: 6)
            }
        }
    }

    do {
        let w = World()
        w.control.state = .notInstalled
        w.control.coreInstalled = false
        w.control.coreConfigured = false
        wizard("60-wizard-welcome", .welcome, w)
        wizard("61-wizard-subscription", .subscription, w)
        w.client.lastError = UserError.from(raw: "HTTP 404", context: .subscription)
        wizard("61b-wizard-subscription-error", .subscription, w)
        w.client.lastError = nil
        w.subscribe()
        w.client.profileProxies = proxies()
        wizard("61c-wizard-subscription-checked", .subscription, w)
        wizard("62-wizard-install", .install, w)
        w.control.error = UserError.from(raw: "install.sh: launchctl bootstrap failed: 5: Input/output error", context: .install)
        wizard("62b-wizard-install-error", .install, w)
        w.control.error = nil
        w.control.filter.status = .notInstalled
        wizard("63-wizard-filter", .filter, w)
        w.control.filter.status = .waitingForApproval
        wizard("63b-wizard-filter-waiting", .filter, w)
        w.control.state = .on
        w.control.coreInstalled = true
        w.control.coreConfigured = true
        w.connect()
        w.control.filter.status = .on
        wizard("64-wizard-done", .done, w)
    }

    // MARK: menu bar popover

    do {
        let w = World(); w.control.state = .notInstalled; w.control.coreInstalled = false
        popover("20-popover-not-installed", w)
    }
    do {
        let w = World(); w.subscribe()
        popover("21-popover-disconnected-protection-on", w)
    }
    do {
        let w = World(); w.subscribe(); w.connect()
        popover("22-popover-connected", w)
    }
    do {
        let w = World(); w.subscribe(); w.connect(selected: "🇳🇱 Нидерланды"); w.control.multihopEntry = "🇱🇹 Литва"
        w.client.needsConfirmation = true
        popover("23-popover-double-vpn-confirmation", w)
    }
    do {
        let w = World(); w.subscribe(); w.control.state = .paused(until: Date().addingTimeInterval(25 * 60))
        popover("24-popover-paused", w)
    }
    do {
        let w = World(); w.subscribe(); w.connect(); w.control.ownTunnelUp = false; w.control.foreignVPN = "utun6"
        popover("25-popover-foreign-vpn", w)
    }
    do { // the 0.11 field report: Happ up, protection on, ours not connected (ADR 0009)
        let w = World(); w.subscribe(); w.control.vpnUp = true
        w.control.otherVPNName = "Happ"
        w.control.otherVPNServices = [OtherVPN.Service(id: "AAAAAAAA-0000-4000-8000-000000000001", name: "Happ", provider: "su.ffg.happ", connected: true)]
        popover("26-popover-other-vpn-happ", w)
        w.control.otherVPNStopFailed = true
        w.control.otherVPNApp = URL(fileURLWithPath: "/Applications/Happ.app")
        popover("27-popover-other-vpn-stop-failed", w)
    }
    do { // an unknown VPN without a configuration to stop, protection off
        let w = World(); w.subscribe(); w.control.vpnUp = true; w.control.state = .off
        popover("28-popover-other-vpn-unknown", w)
    }

    // MARK: «Трафик» (ADR 0013)

    do {
        let w = World(); w.subscribe(); w.connect(selected: "⚡ Авто")
        w.control.routing = routingReport()
        w.control.connections = connections()
        UserDefaults.standard.set(["tun", "listeners"], forKey: RoutingReport.leftOutKey)
        UserDefaults.standard.set("rules", forKey: "trafficTab")
        shot("37-traffic-rules", .traffic, height: 760, w)
        UserDefaults.standard.set("connections", forKey: "trafficTab")
        shot("38-traffic-connections", .traffic, w)
        UserDefaults.standard.set("check", forKey: "trafficTab")
        renderTrafficQuery = "music.yandex.ru"
        shot("39-traffic-check", .traffic, w)
        renderTrafficQuery = "example.com"
        shot("39b-traffic-check-approximate", .traffic, w)
        renderTrafficQuery = ""
        UserDefaults.standard.removeObject(forKey: RoutingReport.leftOutKey)
    }
    do {
        let w = World(); w.subscribe()
        UserDefaults.standard.set("connections", forKey: "trafficTab")
        shot("38b-traffic-connections-vpn-off", .traffic, w)
        UserDefaults.standard.set("rules", forKey: "trafficTab")
        shot("37b-traffic-no-report", .traffic, w)
    }

    // MARK: leak test window

    func leak(_ name: String, _ w: World, height: CGFloat = 640) {
        shot(name, .leakTest, height: max(height, 640), w)
    }
    do {
        let w = World()
        leak("30-leaktest-initial", w, height: 520)
        w.tester.running = true
        w.tester.step = "Узнаю, кто отвечает на DNS…"
        leak("31-leaktest-running", w, height: 520)
    }
    do {
        let w = World()
        w.tester.home = LeakCheck.Direct(ipv4: "5.6.7.112", ipv6: nil, org: "Beltelecom")
        w.tester.homeDate = Date().addingTimeInterval(-3 * 86400)
        w.tester.result = LeakTester.Result(
            verdict: LeakCheck.Verdict(findings: []),
            ipv4: [("api.ipify.org", "1.2.3.10"), ("am.i.mullvad.net", "1.2.3.10")],
            exit: LeakCheck.Address(ip: "1.2.3.10", country: "Литва", org: "UAB Cherry Servers"),
            ipv6: nil,
            resolvers: [LeakCheck.Resolver(ip: "162.158.180.12", country: "Lithuania", org: "Cloudflare"),
                        LeakCheck.Resolver(ip: "172.71.144.9", country: "Lithuania", org: "Cloudflare")],
            at: Date())
        leak("32-leaktest-ok", w, height: 820)
    }
    do {
        let w = World()
        w.tester.home = LeakCheck.Direct(ipv4: "5.6.7.112", ipv6: "2001:db8:2168:2::5", org: "Beltelecom")
        w.tester.homeDate = Date().addingTimeInterval(-3 * 86400)
        w.tester.result = LeakTester.Result(
            verdict: LeakCheck.Verdict(findings: [.ipv6Leak("2001:db8:2168:2::5"), .dnsLeak(["5.6.7.125"])]),
            ipv4: [("api.ipify.org", "1.2.3.10"), ("am.i.mullvad.net", "1.2.3.10")],
            exit: LeakCheck.Address(ip: "1.2.3.10", country: "Литва", org: "UAB Cherry Servers"),
            ipv6: LeakCheck.Address(ip: "2001:db8:2168:2::5", country: "Беларусь", org: "Beltelecom"),
            resolvers: [LeakCheck.Resolver(ip: "5.6.7.125", country: "Belarus", org: "Beltelecom"),
                        LeakCheck.Resolver(ip: "162.158.180.12", country: "Lithuania", org: "Cloudflare")],
            at: Date())
        leak("33-leaktest-leak", w, height: 900)
    }
    do {
        let w = World()
        w.tester.result = LeakTester.Result(
            verdict: LeakCheck.Verdict(findings: [.vpnOff], home: LeakCheck.Direct(ipv4: "5.6.7.112", ipv6: nil, org: "Beltelecom")),
            ipv4: [("api.ipify.org", "5.6.7.112"), ("am.i.mullvad.net", "5.6.7.112")],
            exit: LeakCheck.Address(ip: "5.6.7.112", country: "Беларусь", org: "Beltelecom"),
            ipv6: nil, resolvers: [LeakCheck.Resolver(ip: "5.6.7.125", country: "Belarus", org: "Beltelecom")], at: Date())
        w.tester.home = LeakCheck.Direct(ipv4: "5.6.7.112", ipv6: nil, org: "Beltelecom")
        w.tester.homeDate = Date()
        leak("34-leaktest-vpn-off", w, height: 760)
    }
    do {
        let w = World()
        w.tester.home = LeakCheck.Direct(ipv4: "5.6.7.112", ipv6: nil, org: "Beltelecom")
        w.tester.homeDate = Date().addingTimeInterval(-3 * 86400)
        w.tester.result = LeakTester.Result(
            verdict: LeakCheck.Verdict(findings: [.otherVPN("Happ")]),
            ipv4: [("api.ipify.org", "1.2.3.14"), ("am.i.mullvad.net", "1.2.3.14")],
            exit: LeakCheck.Address(ip: "1.2.3.14", country: "Нидерланды", org: "Aeza International"),
            ipv6: nil, resolvers: [LeakCheck.Resolver(ip: "8.8.4.4", country: "Netherlands", org: "Google")], at: Date())
        leak("36-leaktest-other-vpn", w, height: 760)
    }
    do { // 35 the direct-exit probe found a hole while protection is on
        let w = World()
        w.tester.home = LeakCheck.Direct(ipv4: "5.6.7.112", ipv6: nil, org: "Beltelecom")
        w.tester.result = LeakTester.Result(
            verdict: LeakCheck.Verdict(findings: [.directExit(["en0"])]),
            ipv4: [("api.ipify.org", "1.2.3.10"), ("am.i.mullvad.net", "1.2.3.10")],
            exit: LeakCheck.Address(ip: "1.2.3.10", country: "Литва", org: "UAB Cherry Servers"),
            ipv6: nil, resolvers: [LeakCheck.Resolver(ip: "162.158.180.12", country: "Lithuania", org: "Cloudflare")],
            at: Date())
        leak("35-leaktest-direct-exit", w, height: 820)
    }

    // MARK: «Настройки» panes, «Журнал защиты», «О программе»: sections of the same window

    func settings(_ name: String, height: CGFloat = 640, _ w: World, _ section: AppSection) {
        shot(name, section, height: height, w)
    }
    /// A batch sheet drawn alone (a sheet has no title bar).
    func sheet<V: View>(_ name: String, _ w: World, @ViewBuilder _ content: () -> V) {
        snapshot(name, width: 460) {
            content().environment(w.control).environment(w.client).environment(w.auto)
        }
    }
    do {
        let w = World()
        w.auto.enabled = true
        w.auto.skipTrusted = true
        w.auto.location = .denied
        w.auto.trusted = ["Zhuravel_Home_5G"]
        w.auto.ssid = "Cafe Free WiFi"
        w.auto.lastAction = "Подключился сам 09:41"
        settings("40-settings-general", w, .settings(.general))
    }
    do {
        let w = World(); w.control.coreConfigured = false
        settings("41-settings-vpn-empty", w, .settings(.vpn))
    }
    do {
        let w = World(); w.subscribe(); w.connect(selected: "🇳🇱 Нидерланды")
        w.client.manual = [VPNClient.ManualServer(link: "vless://x", name: "🇵🇱 Варшава (свой)"),
                           VPNClient.ManualServer(link: "wireguard://x", name: "Дом WireGuard")]
        w.control.multihopEntry = "🇱🇹 Литва"
        w.control.splitApps = ["Telegram", "zoom.us"]
        settings("42-settings-vpn-full", w, .settings(.vpn))
    }
    do {
        let w = World()
        w.control.filter.status = .waitingForApproval
        settings("43-settings-protection", w, .settings(.protection))
        w.control.filter.status = .failed("Расширение не подписано для этого Mac")
        w.control.state = .paused(until: Date().addingTimeInterval(25 * 60))
        settings("43b-settings-protection-paused-filter-error", w, .settings(.protection))
    }
    do {
        let w = World()
        w.control.exceptions = ["1.2.3.46", "10.8.0.0/24"]
        w.control.manualServers = ["1.2.3.10"]
        w.client.transportServers = [
            Transport.Server(name: "🇱🇹 Литва", canFingerprint: true, canMux: true, fingerprint: "chrome", mux: nil),
            Transport.Server(name: "🇩🇪 Германия", canFingerprint: false, canMux: true, fingerprint: nil, mux: nil),
        ]
        w.client.transportOverrides = ["🇱🇹 Литва": Transport.Override(fingerprint: "firefox", mux: nil)]
        settings("44-settings-advanced", height: 760, w, .settings(.advanced))
    }
    do {
        let w = World()
        w.control.events = ["2026-10-09 22:14:03 rules were changed or flushed: reloading",
                            "2026-10-10 08:01:11 pf was disabled: reloading",
                            "2026-10-10 09:12:45 tunnels changed (utun4 utun6): reloading",
                            "2026-10-10 09:12:46 core: 🚀 Выбор сервера -> 🇱🇹 Литва"]
        settings("45-window-log", w, .log)
        settings("45c-window-about", w, .about)
    }
    do {
        let w = World()
        w.control.manualServers = ["1.2.3.10"]
        sheet("46-settings-sheet-addresses", w) {
            ListSheet(title: "Адреса серверов для других VPN-программ",
                      note: "К этим адресам сможет подключиться любая программа. Серверы подписки сюда добавлять не нужно.",
                      placeholder: "Адрес сервера", original: w.control.manualServers,
                      apply: { _ in })
        }
        sheet("47-settings-sheet-access", w) { AccessSheet() }
    }

    // MARK: menu bar icons: one per summary status

    snapshot("50-menubar-icons", width: 420, background: true) {
        MenuBarIcons(iconDir: iconDir)
    }

    UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "UXRender")
}

/// The app's main window with every object it reads from the environment.
@MainActor func mainWindow(_ w: World) -> some View {
    MainWindow().environment(w.control).environment(w.client).environment(w.tester).environment(w.auto).environment(Updater())
}

/// Every summary status (spec §2) with its template icon from Assets.xcassets, as on a light and
/// a dark menu bar.
struct MenuBarIcons: View {
    let iconDir: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Значок").frame(width: 50)
                Text("Сводка (метка VoiceOver)").frame(maxWidth: .infinity, alignment: .leading)
            }.font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(Array(Status.examples(now: Date()).enumerated()), id: \.offset) { _, status in
                HStack {
                    icon(status.icon).frame(width: 50, height: 24).background(.bar)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(status.accessibilityLabel)
                        Text(status.icon).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16)
    }

    @ViewBuilder private func icon(_ name: String) -> some View {
        if let dir = iconDir, let image = NSImage(contentsOf: dir.appendingPathComponent("\(name).svg")) {
            Image(nsImage: { image.isTemplate = true; image.size = NSSize(width: 18, height: 18); return image }())
                .renderingMode(.template)
        } else {
            Text("нет").font(.caption).foregroundStyle(.red)
        }
    }
}

MainActor.assumeIsolated { main() }
