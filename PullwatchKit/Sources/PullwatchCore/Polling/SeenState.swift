public import Foundation

/// Persistente dedup-state. `seen` bevat dedupKeys van PR's die gemeld of stil geseed zijn,
/// met de laatste keer dat ze open gezien zijn. `lastSettings` bevat per account de
/// filtersettings van de laatste succesvolle poll. `tagSeeded` bevat per tag-repo
/// (`"{accountId}:{repo.lowercased()}"`) dat de eerste, stille tag-poll al gedaan is, met de
/// laatste keer dat de tags van die repo succesvol opgehaald zijn. Het wordt samen met `seen`
/// geprunet, zodat een repo na een lange tag-storing opnieuw stil seedt. `syncMarks` bevat per
/// account (`accountId.uuidString`) de laatste geslaagde geschiedenis-sync. `coAuthors` bevat per
/// PR (dedupKey) de opgehaalde co-auteurs en de `PullRequest.revision` waarbij ze horen, zodat
/// een PR die niet veranderde geen extra verzoek kost; ook geprunet met `seen`. `tagFingerprints`
/// bevat per tag-repo (dezelfde key als `tagSeeded`) de vingerafdruk van zijn nieuwste tag en
/// release (`TagFetch.fingerprints`), zodat een repo die niet veranderde in de volgende poll niet
/// helemaal opgehaald wordt; het verdwijnt samen met de `tagSeeded`-entry. Een repo met een
/// vingerafdruk is ook al eens met releases opgehaald: pas daarna wordt een nieuwe release gemeld.
/// `checks` bevat per PR (dedupKey) de laatst opgehaalde checks met de revisie waarbij ze horen,
/// zodat een PR die niet veranderde en klaar is met zijn checks geen verzoek kost; ook geprunet
/// met `seen`. `queued` bevat per open PR (dedupKey) dat de vorige poll hem in de rij zag
/// (`MergeQueueEntry`), zodat uit de rij gaan ook na een herstart te zien is; ook geprunet met `seen`.
public struct SeenState: Codable, Equatable, Sendable {
    public var seen: [String: Date] = [:]
    var lastSettings: [String: FilterSettings] = [:]
    var tagSeeded: [String: Date] = [:]
    var syncMarks: [String: SyncMark] = [:]
    public var coAuthors: [String: CoAuthorMark] = [:]
    var tagFingerprints: [String: String] = [:]
    public var checks: [String: CheckMark] = [:]
    public var queued: [String: QueueMark] = [:]
    /// Per gevolgde repo (`"{accountId}:{repo.lowercased()}"`) de branches met hun laatste commit
    /// van de vorige poll, zodat een push ook na een herstart te zien is; geprunet op `seenAt`.
    public var branchHeads: [String: BranchHeads] = [:]
    /// Per gevolgde repo (dezelfde key als `branchHeads`) de boom van Branches; geprunet op
    /// `checkedAt`, een verdwenen branch na de bewaartermijn (`PollEngine.pollBranches`).
    public var repoBranches: [String: RepoBranches] = [:]

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seen = try container.decode([String: Date].self, forKey: .seen)
        lastSettings = try container.decode([String: FilterSettings].self, forKey: .lastSettings)
        // Ontbreekt in seen.json van vóór tags.
        tagSeeded = try container.decodeIfPresent([String: Date].self, forKey: .tagSeeded) ?? [:]
        // Ontbreekt in seen.json van vóór de geschiedenis-sync.
        syncMarks = try container.decodeIfPresent([String: SyncMark].self, forKey: .syncMarks) ?? [:]
        // Ontbreekt in seen.json van vóór de co-auteurs.
        coAuthors = try container.decodeIfPresent([String: CoAuthorMark].self, forKey: .coAuthors) ?? [:]
        // Ontbreekt in seen.json van vóór de releases.
        tagFingerprints = try container.decodeIfPresent([String: String].self, forKey: .tagFingerprints) ?? [:]
        // Ontbreekt in seen.json van vóór de checks.
        checks = try container.decodeIfPresent([String: CheckMark].self, forKey: .checks) ?? [:]
        // Ontbreekt in seen.json van vóór de melding "uit de rij": geen PR heeft dan een vorige stand.
        queued = try container.decodeIfPresent([String: QueueMark].self, forKey: .queued) ?? [:]
        // Ontbreekt in seen.json van vóór branches.
        branchHeads = try container.decodeIfPresent([String: BranchHeads].self, forKey: .branchHeads) ?? [:]
        // Ontbreekt in seen.json van vóór de boom in Branches.
        repoBranches = try container.decodeIfPresent([String: RepoBranches].self, forKey: .repoBranches) ?? [:]
    }

    public func contains(_ key: String) -> Bool {
        seen[key] != nil
    }

    mutating func mark(_ key: String, at date: Date) {
        seen[key] = date
    }

    /// Prunet `seen`-, `tagSeeded`- en `coAuthors`-entries ouder dan `maxAge`.
    public mutating func prune(now: Date, maxAge: TimeInterval = 30 * 24 * 3600) {
        seen = seen.filter { now.timeIntervalSince($0.value) <= maxAge }
        tagSeeded = tagSeeded.filter { now.timeIntervalSince($0.value) <= maxAge }
        coAuthors = coAuthors.filter { now.timeIntervalSince($0.value.at) <= maxAge }
        checks = checks.filter { now.timeIntervalSince($0.value.at) <= maxAge }
        queued = queued.filter { now.timeIntervalSince($0.value.at) <= maxAge }
        branchHeads = branchHeads.filter { now.timeIntervalSince($0.value.seenAt) <= maxAge }
        repoBranches = repoBranches.filter { now.timeIntervalSince($0.value.checkedAt) <= maxAge }
        dropOrphanFingerprints()
    }

    /// Prunet alleen `seen`-, `tagSeeded`- en `coAuthors`-entries waarvan de key met één van
    /// `keyPrefixes` begint.
    public mutating func prune(now: Date, maxAge: TimeInterval = 30 * 24 * 3600, onlyKeyPrefixes keyPrefixes: [String]) {
        let isFresh = { (key: String, date: Date) -> Bool in
            guard keyPrefixes.contains(where: { key.hasPrefix($0) }) else { return true }
            return now.timeIntervalSince(date) <= maxAge
        }
        seen = seen.filter(isFresh)
        tagSeeded = tagSeeded.filter(isFresh)
        coAuthors = coAuthors.filter { isFresh($0.key, $0.value.at) }
        checks = checks.filter { isFresh($0.key, $0.value.at) }
        queued = queued.filter { isFresh($0.key, $0.value.at) }
        branchHeads = branchHeads.filter { isFresh($0.key, $0.value.seenAt) }
        repoBranches = repoBranches.filter { isFresh($0.key, $0.value.checkedAt) }
        dropOrphanFingerprints()
    }

    /// Verwijdert `seen`-, `tagSeeded`- en `coAuthors`-entries waarvan de key niet met één van `keyPrefixes` begint.
    mutating func retain(onlyKeyPrefixes keyPrefixes: [String]) {
        seen = seen.filter { key, _ in keyPrefixes.contains(where: { key.hasPrefix($0) }) }
        tagSeeded = tagSeeded.filter { key, _ in keyPrefixes.contains(where: { key.hasPrefix($0) }) }
        coAuthors = coAuthors.filter { key, _ in keyPrefixes.contains(where: { key.hasPrefix($0) }) }
        checks = checks.filter { key, _ in keyPrefixes.contains(where: { key.hasPrefix($0) }) }
        queued = queued.filter { key, _ in keyPrefixes.contains(where: { key.hasPrefix($0) }) }
        branchHeads = branchHeads.filter { key, _ in keyPrefixes.contains(where: { key.hasPrefix($0) }) }
        repoBranches = repoBranches.filter { key, _ in keyPrefixes.contains(where: { key.hasPrefix($0) }) }
        dropOrphanFingerprints()
    }

    /// Vingerafdrukken horen bij een `tagSeeded`-entry: zonder die entry seedt de repo opnieuw.
    mutating func dropOrphanFingerprints() {
        tagFingerprints = tagFingerprints.filter { tagSeeded[$0.key] != nil }
    }

    /// Ververst de `seen`-datum van alle tags (en hun releases) van één tag-repo
    /// (`"{accountId}:{repo.lowercased()}"`), ook die deze poll niet ophaalde: anders zou prune ze
    /// na een maand vergeten en meldt de volgende volledige poll ze als nieuw.
    mutating func refreshTags(ofRepo repoKey: String, at date: Date) {
        let prefix = repoKey + ":tag:"
        for key in seen.keys where key.hasPrefix(prefix) {
            seen[key] = date
        }
    }
}

/// De branches van één repo met hun laatste commit (branchnaam naar sha), de vingerafdruk van de
/// branchlijst en `seenAt`, de laatste keer dat de repo gelezen is (voor het prunen).
public struct BranchHeads: Codable, Equatable, Sendable {
    public var heads: [String: String]
    public var fingerprint: String?
    public var seenAt: Date

    public init(heads: [String: String], fingerprint: String?, seenAt: Date) {
        self.heads = heads
        self.fingerprint = fingerprint
        self.seenAt = seenAt
    }
}

/// De co-auteurs van één PR bij een bepaalde `PullRequest.revision`; `at` is de laatste keer dat
/// de PR in een poll langskwam (voor het prunen).
public struct CoAuthorMark: Codable, Equatable, Sendable {
    public var revision: String?
    public var people: [Person]
    public var at: Date

    public init(revision: String?, people: [Person], at: Date) {
        self.revision = revision
        self.people = people
        self.at = at
    }
}

/// De checks van één PR bij een bepaalde `PullRequest.revision`: `fetchedAt` is wanneer ze
/// opgehaald zijn, `at` de laatste keer dat de PR in een poll langskwam (voor het prunen).
public struct CheckMark: Codable, Equatable, Sendable {
    public var revision: String?
    public var checks: PRChecks
    public var fetchedAt: Date
    public var at: Date

    public init(revision: String?, checks: PRChecks, fetchedAt: Date, at: Date) {
        self.revision = revision
        self.checks = checks
        self.fetchedAt = fetchedAt
        self.at = at
    }
}

/// Een open PR die de vorige poll in de rij zag: uit welke rij, en `at` de laatste keer dat hij
/// zo gezien is (voor het prunen).
public struct QueueMark: Codable, Equatable, Sendable {
    public var kind: MergeQueueEntry.Kind
    public var at: Date

    public init(kind: MergeQueueEntry.Kind, at: Date) {
        self.kind = kind
        self.at = at
    }
}

/// Moment en context van de laatste geslaagde geschiedenis-sync van een account. Wijken de
/// sync-relevante filtersettings (`FilterSettings.sameSyncScope`) of de bewaartermijn af, dan is
/// de volgende sync weer een volledige eerste sync.
struct SyncMark: Codable, Equatable, Sendable {
    public var at: Date
    public var settings: FilterSettings
    public var retention: HistoryRetention

    public init(at: Date, settings: FilterSettings, retention: HistoryRetention) {
        self.at = at
        self.settings = settings
        self.retention = retention
    }
}
