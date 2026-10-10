import Foundation

/// «Скорость в строке меню»: ↓/↑ through our core, from two readings of `ks core traffic`
/// (the totals of mihomo's /connections) a second apart.
struct TrafficSpeed {
    /// Bytes through the core since it started.
    struct Totals: Equatable {
        var up: UInt64
        var down: UInt64
    }

    /// Bytes per second.
    struct Speed: Equatable {
        var up: Double
        var down: Double
    }

    private var last: (totals: Totals, at: Date)?

    /// nil until there are two readings, and right after the core restarted (totals went down).
    mutating func add(_ totals: Totals, at date: Date) -> Speed? {
        defer { last = (totals, date) }
        guard let last, totals.up >= last.totals.up, totals.down >= last.totals.down else { return nil }
        let seconds = date.timeIntervalSince(last.at)
        guard seconds > 0 else { return nil }
        return Speed(up: Double(totals.up - last.totals.up) / seconds, down: Double(totals.down - last.totals.down) / seconds)
    }

    /// «64 КБ/с», «1,2 МБ/с», «13 МБ/с».
    static func format(_ bytesPerSecond: Double) -> String {
        let kb = bytesPerSecond / 1024
        if kb < 1000 { return "\(Int(kb.rounded(.down))) КБ/с" }
        let mb = kb / 1024
        if mb < 10 { return String(format: "%.1f", (mb * 10).rounded(.down) / 10).replacingOccurrences(of: ".", with: ",") + " МБ/с" }
        return "\(Int(mb.rounded())) МБ/с"
    }

    static func label(_ speed: Speed) -> String {
        "↓ \(format(speed.down)) ↑ \(format(speed.up))"
    }
}

extension TrafficSpeed.Totals {
    /// `up=<bytes> down=<bytes>`.
    init?(_ text: String) {
        guard let match = text.trimmingCharacters(in: .whitespacesAndNewlines).wholeMatch(of: /up=([0-9]+) down=([0-9]+)/),
              let up = UInt64(match.1), let down = UInt64(match.2) else { return nil }
        self.init(up: up, down: down)
    }
}
