import Foundation

/// One switch per double-click in the server list. The first click chooses and adds the server to
/// «Недавние», which moves the rows below by one: the second click would land on the neighbour.
/// A choice within the system double-click interval of the last accepted one is ignored.
struct ServerChoice {
    let interval: TimeInterval
    private var last: Date?

    init(interval: TimeInterval) { self.interval = interval }

    mutating func accept(at now: Date = Date()) -> Bool {
        if let last, now.timeIntervalSince(last) <= interval { return false }
        last = now
        return true
    }
}
