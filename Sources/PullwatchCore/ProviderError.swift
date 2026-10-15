import Foundation

public enum ProviderError: Error, Equatable, Sendable {
    case unauthorized
    case rateLimited(until: Date)
    case server(status: Int)
    case network(String)
    case decoding(String)
    case cliNotFound(String)
    case cliNotLoggedIn(String)
    case missingToken

    public var userMessage: String {
        switch self {
        case .unauthorized:
            return "Token ongeldig of verlopen"
        case .rateLimited(let until):
            return "Rate limit, opnieuw om \(until.formatted(date: .omitted, time: .shortened))"
        case .server(let status):
            return "Serverfout (\(status))"
        case .network(let message):
            return "Netwerkfout: \(message)"
        case .decoding(let message):
            return "Onverwacht antwoord: \(message)"
        case .cliNotFound(let name):
            return "\(name) niet gevonden (installeer via Homebrew)"
        case .cliNotLoggedIn(let name):
            return "Niet ingelogd, voer `\(name == "az" ? "az login" : "gh auth login")` uit"
        case .missingToken:
            return "Geen token ingesteld"
        }
    }
}
