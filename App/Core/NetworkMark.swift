import Foundation

/// The boot window guard's mark (Helper/ks, ADR 0037): the network services ks turned off at
/// shutdown. The watchdog turns them back on, checks it, and only then removes the mark. Its age
/// counts from when it was first seen in this boot: ks keeps that in `seenPath` as "<boot id> <epoch>" (boot id: kern.bootsessionuuid)
/// (the mark's own time is the shutdown's), so a watchdog restarting does not start it again.
enum NetworkMark {
    static let path = "/Library/KillSwitch/wifi-off-by-ks"
    static let seenPath = "/Library/KillSwitch/net-guard-seen"
    /// How long the running watchdog has before «Сеть выключена» shows (ks netrestore: the same 20 s).
    static let grace: TimeInterval = 20

    /// «Сеть выключена»: a mark nothing will clear (no watchdog), or one the watchdog has not
    /// cleared in 20 s.
    static func leftOff(age: TimeInterval?, daemonRuns: Bool) -> Bool {
        guard let age else { return false }
        return !daemonRuns || age > grace
    }

    /// When to look again: just after a mark the running watchdog still has time for would show;
    /// nil when nothing will change by waiting.
    static func recheck(age: TimeInterval?, daemonRuns: Bool) -> TimeInterval? {
        guard let age, daemonRuns, !leftOff(age: age, daemonRuns: daemonRuns) else { return nil }
        return max(0, grace - age) + 1
    }

    /// Seconds since the mark was first seen in this boot. Without that (no usable first-seen file
    /// of this boot: the watchdog is stuck before net_guard, or has not had its first pass) it counts
    /// from the later of the mark's own time and the boot, so the banner cannot stay away; 0 when
    /// even that is unknown; nil without a mark.
    static func age(markExists: Bool, seen: String?, bootId: String?, markModified: Date?, bootDate: Date?,
                    now: Date) -> TimeInterval? {
        guard markExists else { return nil }
        let fields = (seen ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        if fields.count >= 2, let bootId, fields[0] == bootId, let first = TimeInterval(fields[1]) {
            return now.timeIntervalSince1970 - first
        }
        guard let since = [markModified, bootDate].compactMap({ $0 }).max() else { return 0 }
        return max(0, now.timeIntervalSince(since))
    }

    static func age(now: Date = Date()) -> TimeInterval? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return age(markExists: attrs != nil, seen: try? String(contentsOfFile: seenPath, encoding: .utf8),
                   bootId: bootId(), markModified: attrs?[.modificationDate] as? Date, bootDate: bootDate(), now: now)
    }

    /// kern.bootsessionuuid: what ks calls the boot id (kern.boottime moves when the clock is stepped).
    static func bootId() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    /// kern.boottime: only the floor of the fallback age.
    static func bootDate() -> Date? {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec))
    }
}
