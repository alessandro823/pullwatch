import Foundation

public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.network("geen HTTP-response")
            }
            return (data, http)
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
    }
}

public enum HTTPStatus {
    public static func check(_ response: HTTPURLResponse, now: Date) throws {
        let status = response.statusCode
        switch status {
        case 203:
            // Azure DevOps antwoordt met 203 + HTML-loginpagina bij een ongeldige PAT.
            throw ProviderError.unauthorized
        case 200..<300:
            return
        case 401:
            throw ProviderError.unauthorized
        case 403, 429:
            if let retryAfter = response.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(retryAfter) {
                throw ProviderError.rateLimited(until: now + seconds)
            }
            if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
               let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
               let epoch = Double(reset) {
                throw ProviderError.rateLimited(until: Date(timeIntervalSince1970: epoch))
            }
            if status == 429 { throw ProviderError.rateLimited(until: now + 60) }
            throw ProviderError.unauthorized
        default:
            throw ProviderError.server(status: status)
        }
    }
}

public enum JSONDecoding {
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data, snakeCase: Bool = false) throws -> T {
        let decoder = JSONDecoder()
        if snakeCase { decoder.keyDecodingStrategy = .convertFromSnakeCase }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw ProviderError.decoding("\(T.self): \(error.localizedDescription)")
        }
    }
}

public enum DateParsing {
    /// ISO-8601; fractionele seconden (ook 7 cijfers zoals Azure DevOps levert) worden genegeerd.
    public static func parse(_ string: String) -> Date? {
        var value = string
        if let dot = value.firstIndex(of: "."),
           let end = value[dot...].firstIndex(where: { "Z+-".contains($0) }) {
            value.removeSubrange(dot..<end)
        }
        return try? Date(value, strategy: .iso8601)
    }
}
