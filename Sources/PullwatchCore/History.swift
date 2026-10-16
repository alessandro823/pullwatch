import Foundation

public enum HistoryEntry: Codable, Hashable, Sendable {
    case pullRequest(PullRequest)
    case tag(Tag)

    public var kind: ItemKind {
        switch self {
        case .pullRequest: return .pullRequest
        case .tag: return .tag
        }
    }

    public var dedupKey: String {
        switch self {
        case .pullRequest(let pr): return pr.dedupKey
        case .tag(let tag): return tag.dedupKey
        }
    }

    public var accountId: UUID {
        switch self {
        case .pullRequest(let pr): return pr.accountId
        case .tag(let tag): return tag.accountId
        }
    }

    public var repo: String {
        switch self {
        case .pullRequest(let pr): return pr.repo
        case .tag(let tag): return tag.repo
        }
    }

    /// PR-titel of tagnaam.
    public var title: String {
        switch self {
        case .pullRequest(let pr): return pr.title
        case .tag(let tag): return tag.name
        }
    }

    public var author: String? {
        switch self {
        case .pullRequest(let pr): return pr.authorName
        case .tag(let tag): return tag.authorName
        }
    }

    public var webURL: URL {
        switch self {
        case .pullRequest(let pr): return pr.webURL
        case .tag(let tag): return tag.webURL
        }
    }
}

public struct HistoryItem: Codable, Identifiable, Hashable, Sendable {
    public var entry: HistoryEntry
    public var detectedAt: Date
    public var isRead: Bool

    public var id: String { entry.dedupKey }

    public init(entry: HistoryEntry, detectedAt: Date, isRead: Bool) {
        self.entry = entry
        self.detectedAt = detectedAt
        self.isRead = isRead
    }
}

public enum HistoryRetention: String, Codable, CaseIterable, Sendable {
    case twoMonths, sixMonths, oneYear, forever

    /// Maximale leeftijd; `nil` betekent dat er nooit iets wordt verwijderd.
    public var maxAge: TimeInterval? {
        let day: TimeInterval = 86_400
        switch self {
        case .twoMonths: return 61 * day
        case .sixMonths: return 183 * day
        case .oneYear: return 365 * day
        case .forever: return nil
        }
    }

    public var label: String {
        switch self {
        case .twoMonths: return "2 maanden"
        case .sixMonths: return "6 maanden"
        case .oneYear: return "1 jaar"
        case .forever: return "Altijd"
        }
    }
}

public struct History: Codable, Equatable, Sendable {
    /// Nieuwste eerst.
    public private(set) var items: [HistoryItem] = []

    public init() {}

    /// Neemt een oude `RecentList` over, met behoud van `detectedAt` en `isRead`.
    public init(migrating list: RecentList) {
        items = list.items.map {
            HistoryItem(entry: .pullRequest($0.pullRequest), detectedAt: $0.detectedAt, isRead: $0.isRead)
        }
    }

    public var unreadCount: Int {
        items.filter { !$0.isRead }.count
    }

    /// Bestaande items worden vervangen en komen bovenaan; tags komen boven de PR's uit dezelfde aanroep.
    public mutating func add(pullRequests: [PullRequest], tags: [Tag], at date: Date) {
        let entries = pullRequests.sorted { $0.createdAt < $1.createdAt }.map(HistoryEntry.pullRequest)
            + tags.map(HistoryEntry.tag)
        for entry in entries {
            items.removeAll { $0.id == entry.dedupKey }
            items.insert(HistoryItem(entry: entry, detectedAt: date, isRead: false), at: 0)
        }
    }

    public mutating func markRead(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isRead = true
    }

    public mutating func markAllRead() {
        for index in items.indices {
            items[index].isRead = true
        }
    }

    public mutating func removeAccount(_ id: UUID) {
        items.removeAll { $0.entry.accountId == id }
    }

    /// Verwijdert items ouder dan de bewaartermijn. Geeft `true` als er iets is verwijderd.
    @discardableResult
    public mutating func prune(now: Date, retention: HistoryRetention) -> Bool {
        guard let maxAge = retention.maxAge else { return false }
        let before = items.count
        items.removeAll { now.timeIntervalSince($0.detectedAt) > maxAge }
        return items.count != before
    }

    public func latest(_ kind: ItemKind, limit: Int) -> [HistoryItem] {
        Array(items.filter { $0.entry.kind == kind }.prefix(max(limit, 0)))
    }

    /// Lege tekst (na trimmen) geeft alles; anders hoofdletterongevoelig zoeken in titel, auteur en repo.
    public func search(_ text: String, kind: ItemKind?) -> [HistoryItem] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            if let kind, item.entry.kind != kind { return false }
            if query.isEmpty { return true }
            return item.entry.title.localizedCaseInsensitiveContains(query)
                || (item.entry.author?.localizedCaseInsensitiveContains(query) ?? false)
                || item.entry.repo.localizedCaseInsensitiveContains(query)
        }
    }
}

extension History {
    /// Kiest de beginstand bij het opstarten: `history.json` wint; anders wordt `recent.json` gemigreerd.
    /// `needsSave` is `true` als de uitkomst nog naar `history.json` moet worden weggeschreven.
    public static func initial(stored: History?, legacy: RecentList?) -> (history: History, needsSave: Bool) {
        if let stored { return (stored, false) }
        if let legacy { return (History(migrating: legacy), true) }
        return (History(), false)
    }
}
