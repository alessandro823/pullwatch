import Foundation

public struct AppConfig: Codable, Equatable, Sendable {
    public static let intervalRange = 60...900

    public var accounts: [Account]
    public var pollInterval: Int
    public var historyRetention: HistoryRetention

    public init(accounts: [Account] = [], pollInterval: Int = 120, historyRetention: HistoryRetention = .oneYear) {
        self.accounts = accounts
        self.pollInterval = pollInterval
        self.historyRetention = historyRetention
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try c.decode([Account].self, forKey: .accounts)
        pollInterval = try c.decode(Int.self, forKey: .pollInterval)
        historyRetention = try c.decodeIfPresent(HistoryRetention.self, forKey: .historyRetention) ?? .oneYear
    }

    public var clampedInterval: Int {
        min(max(pollInterval, Self.intervalRange.lowerBound), Self.intervalRange.upperBound)
    }

    /// Accounts die net zijn toegevoegd en nog geen organisatie hebben, worden niet gepold.
    public var pollableAccounts: [Account] {
        accounts.filter { !$0.organization.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
