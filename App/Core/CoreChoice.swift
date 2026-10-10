import Foundation

/// Which way of connecting the helper runs (ADR 0020): `core=` in `/Library/KillSwitch/settings`
/// (Helper/ks core_kind). On screen: «Основной» (Xray, as in Happ) and «Запасной» (mihomo).
enum CoreChoice: String, Equatable, Sendable, CaseIterable {
    case xray, mihomo

    static let settingsPath = "/Library/KillSwitch/settings"

    /// The last `core=` line, as ks reads it; without one mihomo, what every install before had.
    static func read(settings text: String?) -> CoreChoice {
        let value = (text ?? "").split(whereSeparator: \.isNewline).last { $0.hasPrefix("core=") }?.dropFirst(5)
        return value == "xray" ? .xray : .mihomo
    }

    static func current() -> CoreChoice {
        read(settings: try? String(contentsOfFile: settingsPath, encoding: .utf8))
    }

    var binary: String { "/Library/KillSwitch/core/\(rawValue)" }
    var config: String { self == .xray ? "/Library/KillSwitch/core/xray.json" : "/Library/KillSwitch/core/config.yaml" }
    /// Only mihomo lists live connections («Трафик» › «Соединения»); Xray has no API for it here.
    var hasConnections: Bool { self == .mihomo }
}
