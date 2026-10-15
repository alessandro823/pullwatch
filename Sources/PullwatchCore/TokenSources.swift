import Foundation

public protocol TokenSource: Sendable {
    func token() async throws -> String
    func invalidate() async
}

extension TokenSource {
    public func invalidate() async {}
}

public struct StaticTokenSource: TokenSource {
    private let value: String

    public init(token: String) {
        self.value = token
    }

    public func token() async throws -> String { value }
}

public actor AzCLISource: TokenSource {
    private static let devOpsResource = "499b84ac-1321-427f-aa17-267ca6975798"

    private let runner: any ProcessRunner
    private let locator: CLILocator
    private let now: @Sendable () -> Date
    private var cached: (token: String, expiresAt: Date)?

    public init(runner: any ProcessRunner, locator: CLILocator = CLILocator(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.runner = runner
        self.locator = locator
        self.now = now
    }

    public func token() async throws -> String {
        if let cached, cached.expiresAt.addingTimeInterval(-300) > now() {
            return cached.token
        }
        guard let az = locator.locate("az") else { throw ProviderError.cliNotFound("az") }
        let output = try await runner.run(az, ["account", "get-access-token", "--resource", Self.devOpsResource, "--output", "json"])
        guard output.status == 0 else { throw ProviderError.cliNotLoggedIn("az") }

        struct Response: Decodable {
            let accessToken: String
            let expires_on: Int?
        }
        let response = try JSONDecoding.decode(Response.self, from: Data(output.stdout.utf8))
        let expiresAt = response.expires_on.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            ?? now().addingTimeInterval(3000)
        cached = (response.accessToken, expiresAt)
        return response.accessToken
    }

    public func invalidate() async {
        cached = nil
    }
}

public actor GhCLISource: TokenSource {
    private let runner: any ProcessRunner
    private let locator: CLILocator
    private let now: @Sendable () -> Date
    private var cached: (token: String, fetchedAt: Date)?

    public init(runner: any ProcessRunner, locator: CLILocator = CLILocator(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.runner = runner
        self.locator = locator
        self.now = now
    }

    public func token() async throws -> String {
        if let cached, now().timeIntervalSince(cached.fetchedAt) < 15 * 60 {
            return cached.token
        }
        guard let gh = locator.locate("gh") else { throw ProviderError.cliNotFound("gh") }
        let output = try await runner.run(gh, ["auth", "token"])
        let token = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.status == 0, !token.isEmpty else { throw ProviderError.cliNotLoggedIn("gh") }
        cached = (token, now())
        return token
    }

    public func invalidate() async {
        cached = nil
    }
}
