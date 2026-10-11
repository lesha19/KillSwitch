import Foundation

/// «Размер пакетов VPN» (ADR 0032, #18): the TUN's MTU for both ways of connecting, nil = «Авто» (each
/// core's own: Xray 1500, mihomo its default). ks keeps it as `mtu=` in its settings.
enum TunnelMTU {
    /// «Авто» first, then common values: WireGuard's 1420, Mullvad's 1380, IPv6's minimum 1280.
    private static let presets: [Int] = [1500, 1460, 1420, 1400, 1380, 1340, 1280]

    /// The `mtu=` line as ks takes it (four digits, 1280…1500); anything else is «Авто» here.
    static func value(setting: String?) -> Int? {
        guard let setting, setting.wholeMatch(of: /[1-9][0-9]{3}/) != nil, let mtu = Int(setting),
              HelperCommand.setMTU(mtu).isValid else { return nil }
        return mtu
    }

    /// What the picker offers; a value set elsewhere (the command line, a settings file) stays in it.
    static func choices(current: Int?) -> [Int?] {
        var values = presets
        if let current, !values.contains(current) { values.append(current); values.sort(by: >) }
        return [nil] + values.map { Optional($0) }
    }

    static func title(_ mtu: Int?) -> String { mtu.map(String.init) ?? String(localized: "Авто") }
}
