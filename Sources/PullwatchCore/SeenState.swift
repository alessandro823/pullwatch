import Foundation

/// Persistente dedup-state. `seen` bevat dedupKeys van PR's die gemeld of stil geseed zijn,
/// met de laatste keer dat ze open gezien zijn. `lastSettings` bevat per account de
/// filtersettings van de laatste succesvolle poll.
public struct SeenState: Codable, Equatable, Sendable {
    public var seen: [String: Date] = [:]
    public var lastSettings: [String: FilterSettings] = [:]

    public init() {}

    public func contains(_ key: String) -> Bool {
        seen[key] != nil
    }

    public mutating func mark(_ key: String, at date: Date) {
        seen[key] = date
    }

    public mutating func prune(now: Date, maxAge: TimeInterval = 30 * 24 * 3600) {
        seen = seen.filter { now.timeIntervalSince($0.value) <= maxAge }
    }

    /// Prunet alleen entries waarvan de key met één van `keyPrefixes` begint.
    public mutating func prune(now: Date, maxAge: TimeInterval = 30 * 24 * 3600, onlyKeyPrefixes keyPrefixes: [String]) {
        seen = seen.filter { key, date in
            guard keyPrefixes.contains(where: { key.hasPrefix($0) }) else { return true }
            return now.timeIntervalSince(date) <= maxAge
        }
    }

    /// Verwijdert entries waarvan de key niet met één van `keyPrefixes` begint.
    public mutating func retain(onlyKeyPrefixes keyPrefixes: [String]) {
        seen = seen.filter { key, _ in keyPrefixes.contains(where: { key.hasPrefix($0) }) }
    }
}
