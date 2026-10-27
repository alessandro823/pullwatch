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
    case noAccess(String)

    public var userMessage: String {
        switch self {
        case .unauthorized:
            return String(localized: "Token ongeldig of verlopen", bundle: .localizedCore)
        case .rateLimited(let until):
            return String(localized: "Rate limit, opnieuw om \(until.formatted(date: .omitted, time: .shortened))", bundle: .localizedCore)
        case .server(let status):
            return String(localized: "Serverfout (\(status))", bundle: .localizedCore)
        case .network(let message):
            return String(localized: "Netwerkfout: \(message)", bundle: .localizedCore)
        case .decoding(let message):
            return String(localized: "Onverwacht antwoord: \(message)", bundle: .localizedCore)
        case .cliNotFound(let name):
            return String(localized: "\(name) niet gevonden (installeer via Homebrew)", bundle: .localizedCore)
        case .cliNotLoggedIn(let name):
            let command = name == "az" ? "az login" : "gh auth login"
            return String(localized: "Niet ingelogd, voer `\(command)` uit", bundle: .localizedCore)
        case .missingToken:
            return String(localized: "Geen token ingesteld", bundle: .localizedCore)
        case .noAccess(let name):
            return String(localized: "Geen toegang tot \"\(name)\", controleer de naam", bundle: .localizedCore)
        }
    }
}
