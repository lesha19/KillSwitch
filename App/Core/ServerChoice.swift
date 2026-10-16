import Foundation

/// One switch per double-click in the server list. The first click chooses and adds the server to
/// «Недавние», which moves the rows below by one: the second click would land on the neighbour.
/// A choice within `interval` after the last accepted one is ignored. Times are system uptime
/// (monotonic), so a wall clock set back never swallows the clicks; an earlier time is accepted.
struct ServerChoice {
    let interval: TimeInterval
    private var last: TimeInterval?

    init(interval: TimeInterval) { self.interval = interval }

    mutating func accept(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        if let last, now >= last, now - last <= interval { return false }
        last = now
        return true
    }
}
