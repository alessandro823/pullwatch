import Foundation

public struct AppConfig: Codable, Equatable, Sendable {
    public static let intervalRange = 60...900

    public var accounts: [Account]
    public var pollInterval: Int
    public var historyRetention: HistoryRetention
    /// Versies en CVE's eens per dag vanzelf checken, met melding bij nieuwe CVE's.
    public var autoVersionCheck: Bool
    /// Eens per dag kijken of er een nieuwere Pullwatch op GitHub staat.
    public var checkForUpdates: Bool

    public init(
        accounts: [Account] = [],
        pollInterval: Int = 120,
        historyRetention: HistoryRetention = .oneYear,
        autoVersionCheck: Bool = true,
        checkForUpdates: Bool = true
    ) {
        self.accounts = accounts
        self.pollInterval = pollInterval
        self.historyRetention = historyRetention
        self.autoVersionCheck = autoVersionCheck
        self.checkForUpdates = checkForUpdates
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try c.decode([Account].self, forKey: .accounts)
        pollInterval = try c.decode(Int.self, forKey: .pollInterval)
        historyRetention = try c.decodeIfPresent(HistoryRetention.self, forKey: .historyRetention) ?? .oneYear
        autoVersionCheck = try c.decodeIfPresent(Bool.self, forKey: .autoVersionCheck) ?? true
        checkForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? true
    }

    public var clampedInterval: Int {
        min(max(pollInterval, Self.intervalRange.lowerBound), Self.intervalRange.upperBound)
    }

    /// Accounts die net zijn toegevoegd en nog geen organisatie hebben, worden niet gepold.
    public var pollableAccounts: [Account] {
        accounts.filter { !$0.organization.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
