import Foundation

/// Persistente dedup-state. `seen` bevat dedupKeys van PR's die gemeld of stil geseed zijn,
/// met de laatste keer dat ze open gezien zijn. `lastSettings` bevat per account de
/// filtersettings van de laatste succesvolle poll. `tagSeeded` bevat per tag-repo
/// (`"{accountId}:{repo.lowercased()}"`) dat de eerste, stille tag-poll al gedaan is, met de
/// laatste keer dat de tags van die repo succesvol opgehaald zijn. Het wordt samen met `seen`
/// geprunet, zodat een repo na een lange tag-storing opnieuw stil seedt. `syncMarks` bevat per
/// account (`accountId.uuidString`) de laatste geslaagde geschiedenis-sync.
public struct SeenState: Codable, Equatable, Sendable {
    public var seen: [String: Date] = [:]
    public var lastSettings: [String: FilterSettings] = [:]
    public var tagSeeded: [String: Date] = [:]
    public var syncMarks: [String: SyncMark] = [:]

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seen = try container.decode([String: Date].self, forKey: .seen)
        lastSettings = try container.decode([String: FilterSettings].self, forKey: .lastSettings)
        // Ontbreekt in seen.json van vóór tags.
        tagSeeded = try container.decodeIfPresent([String: Date].self, forKey: .tagSeeded) ?? [:]
        // Ontbreekt in seen.json van vóór de geschiedenis-sync.
        syncMarks = try container.decodeIfPresent([String: SyncMark].self, forKey: .syncMarks) ?? [:]
    }

    public func contains(_ key: String) -> Bool {
        seen[key] != nil
    }

    public mutating func mark(_ key: String, at date: Date) {
        seen[key] = date
    }

    /// Prunet `seen`- en `tagSeeded`-entries ouder dan `maxAge`.
    public mutating func prune(now: Date, maxAge: TimeInterval = 30 * 24 * 3600) {
        seen = seen.filter { now.timeIntervalSince($0.value) <= maxAge }
        tagSeeded = tagSeeded.filter { now.timeIntervalSince($0.value) <= maxAge }
    }

    /// Prunet alleen `seen`- en `tagSeeded`-entries waarvan de key met één van `keyPrefixes` begint.
    public mutating func prune(now: Date, maxAge: TimeInterval = 30 * 24 * 3600, onlyKeyPrefixes keyPrefixes: [String]) {
        let isFresh = { (key: String, date: Date) -> Bool in
            guard keyPrefixes.contains(where: { key.hasPrefix($0) }) else { return true }
            return now.timeIntervalSince(date) <= maxAge
        }
        seen = seen.filter(isFresh)
        tagSeeded = tagSeeded.filter(isFresh)
    }

    /// Verwijdert `seen`- en `tagSeeded`-entries waarvan de key niet met één van `keyPrefixes` begint.
    public mutating func retain(onlyKeyPrefixes keyPrefixes: [String]) {
        seen = seen.filter { key, _ in keyPrefixes.contains(where: { key.hasPrefix($0) }) }
        tagSeeded = tagSeeded.filter { key, _ in keyPrefixes.contains(where: { key.hasPrefix($0) }) }
    }
}

/// Moment en context van de laatste geslaagde geschiedenis-sync van een account. Wijken de
/// filtersettings of de bewaartermijn af, dan is de volgende sync weer een volledige eerste sync.
public struct SyncMark: Codable, Equatable, Sendable {
    public var at: Date
    public var settings: FilterSettings
    public var retention: HistoryRetention

    public init(at: Date, settings: FilterSettings, retention: HistoryRetention) {
        self.at = at
        self.settings = settings
        self.retention = retention
    }
}
