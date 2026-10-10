import Foundation

/// A small cache whose entries live `lifetime` seconds, at most `capacity` of them (when full,
/// expired entries go first, then everything). Not thread-safe: the filter wraps it in a lock.
/// Used by Filter/FilterDataProvider for per-flow checks (tunnels up, code signatures).
struct ExpiringCache<Key: Hashable, Value> {
    let lifetime: TimeInterval
    let capacity: Int
    private var entries: [Key: (value: Value, at: Date)] = [:]

    init(lifetime: TimeInterval, capacity: Int) {
        self.lifetime = lifetime
        self.capacity = capacity
    }

    var count: Int { entries.count }

    /// `.some(value)` while fresh (the value itself may be nil), nil when unknown or expired.
    func value(for key: Key, now: Date) -> Value? {
        guard let entry = entries[key], now.timeIntervalSince(entry.at) < lifetime else { return nil }
        return entry.value
    }

    mutating func set(_ value: Value, for key: Key, now: Date) {
        if entries.count >= capacity, entries[key] == nil {
            entries = entries.filter { now.timeIntervalSince($0.value.at) < lifetime }
            if entries.count >= capacity { entries.removeAll() }
        }
        entries[key] = (value, now)
    }
}

extension ExpiringCache: Sendable where Key: Sendable, Value: Sendable {}
