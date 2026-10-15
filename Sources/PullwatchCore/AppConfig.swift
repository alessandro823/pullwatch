import Foundation

public struct AppConfig: Codable, Equatable, Sendable {
    public static let intervalRange = 60...900

    public var accounts: [Account]
    public var pollInterval: Int

    public init(accounts: [Account] = [], pollInterval: Int = 120) {
        self.accounts = accounts
        self.pollInterval = pollInterval
    }

    public var clampedInterval: Int {
        min(max(pollInterval, Self.intervalRange.lowerBound), Self.intervalRange.upperBound)
    }

    /// Accounts die net zijn toegevoegd en nog geen organisatie hebben, worden niet gepold.
    public var pollableAccounts: [Account] {
        accounts.filter { !$0.organization.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
