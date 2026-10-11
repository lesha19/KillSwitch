import CoreLocation
import CoreWLAN
import Foundation
import Network
import Observation

/// «Подключаться автоматически» (decision in AutoConnect, on by default): once after the app starts
/// and whenever the Mac moves to another network. Never asks for a password (see
/// coreOnAutomatically) and never disconnects: a trusted Wi-Fi only means "do not connect by
/// itself", so there the VPN may stay off or protection paused. A manual «Отключить» holds until
/// the network changes.
@MainActor
@Observable
final class AutoConnector: NSObject, CLLocationManagerDelegate {
    var enabled = AutoConnect.enabled(stored: UserDefaults.standard.object(forKey: "autoConnect") as? Bool) {
        didSet { UserDefaults.standard.set(enabled, forKey: "autoConnect") }
    }
    var skipTrusted = AutoConnect.skipTrusted(stored: UserDefaults.standard.object(forKey: "autoConnectSkipTrusted") as? Bool) {
        didSet {
            UserDefaults.standard.set(skipTrusted, forKey: "autoConnectSkipTrusted")
            if skipTrusted { requestLocation() }
        }
    }
    private(set) var trusted = UserDefaults.standard.stringArray(forKey: "trustedNetworks") ?? []
    /// The current Wi-Fi's name; nil on a cable, offline, or without Location permission.
    private(set) var ssid: String?
    private(set) var onWiFi = false
    private(set) var location: CLAuthorizationStatus = .notDetermined
    /// What the last automatic attempt did, for Settings.
    private(set) var lastAction: String?
    /// «Сети Wi‑Fi» (WiFiRules), kept in UserDefaults on this Mac only.
    private(set) var rules = WiFiRules.decode(UserDefaults.standard.data(forKey: WiFiRules.key))
    /// A network's preferred server could not be picked, for «Сети Wi‑Fi».
    private(set) var ruleNote: String?

    private let control: KillSwitchControl
    private let client: VPNClient
    private let monitor = NWPathMonitor()
    private let locationManager = CLLocationManager()
    private var network = AutoConnect.Network(online: false, wifi: false, ssid: nil, interfaces: [])
    private var lastIdentity: String?
    private var started = false
    private var pending: Task<Void, Never>?
    /// «Добавить текущую сеть» was clicked before macOS answered the Location prompt.
    private var addWhenAllowed = false

    init(control: KillSwitchControl, client: VPNClient) {
        self.control = control
        self.client = client
        super.init()
        locationManager.delegate = self
        location = locationManager.authorizationStatus
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let wifi = path.usesInterfaceType(.wifi)
            // physical interfaces only: a VPN tunnel coming up is not a new network
            let names = path.availableInterfaces
                .filter { [.wifi, .wiredEthernet, .cellular].contains($0.type) }
                .map(\.name)
            Task { @MainActor in self?.pathChanged(online: online, wifi: wifi, interfaces: names) }
        }
        monitor.start(queue: DispatchQueue(label: "killswitch.autoconnect"))
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))   // let the first state refresh finish
            started = true
            lastIdentity = network.identity
            evaluate()
        }
    }

    var locationAllowed: Bool { location == .authorizedAlways || location == .authorized }

    /// Trusted networks are on but macOS hides the Wi-Fi name (no Location access).
    var trustedNeedsLocation: Bool { AutoConnect.trustedNeedsLocation(skipTrusted: enabled && skipTrusted, locationAllowed: locationAllowed) }

    func addTrusted(_ name: String) { setTrusted(trusted + [name]) }
    func removeTrusted(_ name: String) { setTrusted(trusted.filter { $0 != name }) }

    /// Only from a click (turning on «доверенные сети»): macOS shows its own Location prompt.
    func requestLocation() {
        guard location == .notDetermined else { return }
        locationManager.requestWhenInUseAuthorization()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            location = status
            readSSID()
            if addWhenAllowed, status != .notDetermined {
                addWhenAllowed = false
                if let ssid { setRules(WiFiRules.adding(ssid, to: rules)) }
            }
        }
    }

    /// «Добавить текущую сеть». Without a Location answer yet, macOS asks first (Settings has
    /// explained why), and the network is added once the name can be read.
    func addCurrentNetwork() {
        if location == .notDetermined {
            addWhenAllowed = true
            requestLocation()
            return
        }
        if let ssid { setRules(WiFiRules.adding(ssid, to: rules)) }
    }

    func update(_ rule: WiFiRules.Rule) {
        setRules(rules.map { $0.ssid == rule.ssid ? rule : $0 })
    }

    func removeRule(_ ssid: String) { setRules(rules.filter { $0.ssid != ssid }) }

    private func setRules(_ new: [WiFiRules.Rule]) {
        rules = new
        UserDefaults.standard.set(WiFiRules.encode(new), forKey: WiFiRules.key)
    }

    // MARK: -

    private func setTrusted(_ names: [String]) {
        trusted = AutoConnect.normalized(names)
        UserDefaults.standard.set(trusted, forKey: "trustedNetworks")
    }

    private func pathChanged(online: Bool, wifi: Bool, interfaces: [String]) {
        onWiFi = wifi
        network = AutoConnect.Network(online: online, wifi: wifi, ssid: nil, interfaces: interfaces)
        readSSID()
        guard started, let identity = network.identity, identity != lastIdentity else {
            if !online { lastIdentity = nil }
            return
        }
        lastIdentity = identity
        // DHCP and the Wi-Fi name settle a moment after the path changes
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            readSSID()
            evaluate()
        }
    }

    private func readSSID() {
        ssid = network.wifi ? CWWiFiClient.shared().interface()?.ssid() : nil
        network.ssid = ssid
    }

    private func evaluate() {
        guard started else { return }
        let connection = control.connection
        let core = AutoConnect.Core(
            ready: control.coreInstalled && control.coreConfigured && control.state != .notInstalled,
            connected: connection == .connected || connection == .connecting,
            otherVPN: connection == .otherApp
        )
        let server = preferredServer()
        let settings = AutoConnect.Settings(enabled: enabled, skipTrusted: skipTrusted, trusted: trusted, rules: rules)
        let decision = AutoConnect.decide(settings, network: network, core: core)
        if let server, decision != .connect {
            Task { await control.chooseAutomatically(server) }
        }
        switch decision {
        case .connect:
            Task {
                // picked first, so the connection goes straight to it
                if let server { await control.chooseAutomatically(server) }
                let ok = await control.coreOnAutomatically()
                lastAction = ok ? String(localized: "Подключился сам \(Self.now)") : String(localized: "Не получилось подключиться сам \(Self.now)")
            }
        case .skip(.trusted(let name)):
            lastAction = String(localized: "Не подключался: «\(name)» — доверенная сеть (\(Self.now))")
        case .skip(.otherVPN):
            // never stopped silently: the main screen offers «Отключить … и подключить KillSwitch» (ADR 0009)
            lastAction = String(localized: "Не подключался: работает \(control.otherVPNName ?? String(localized: "другой VPN")) (\(Self.now))")
            Notifier.shared.post(.otherVPN(name: control.otherVPNName))
        case .skip:
            break
        }
    }

    /// This Wi-Fi's «Предпочитаемый сервер», when it is not the current one already.
    private func preferredServer() -> ServerPicker.Entry? {
        let rule = network.wifi ? WiFiRules.rule(for: network.ssid, in: rules) : nil
        let entries = (control.proxies ?? client.profileProxies).map(ServerPicker.entries) ?? []
        switch WiFiRules.server(for: rule, entries: entries, current: control.pickedServer) {
        case .keep:
            return nil
        case .select(let entry):
            ruleNote = nil
            return entry
        case .missing(let name):
            ruleNote = String(localized: "Сервера «\(name)» больше нет в подписке, выбран прежний (\(Self.now))")
            return nil
        }
    }

    private static var now: String { Date().formatted(date: .omitted, time: .shortened) }
}
