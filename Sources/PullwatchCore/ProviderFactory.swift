import Foundation

public enum ProviderFactory {
    /// `pat` overschrijft de Keychain (gebruikt bij "Test verbinding" vóór opslaan).
    public static func make(
        _ account: Account,
        pat: String? = nil,
        secrets: any SecretStore = KeychainStore(),
        http: any HTTPClient = URLSessionHTTPClient(),
        runner: any ProcessRunner = SystemProcessRunner()
    ) -> any PRProvider {
        let tokens: any TokenSource
        switch account.authMethod {
        case .pat:
            if let pat {
                tokens = StaticTokenSource(token: pat)
            } else {
                tokens = KeychainPATSource(store: secrets, accountId: account.id)
            }
        case .cli:
            switch account.kind {
            case .azureDevOps: tokens = AzCLISource(runner: runner)
            case .gitHub: tokens = GhCLISource(runner: runner, user: account.cliUser)
            }
        }

        switch account.kind {
        case .azureDevOps:
            return AzureDevOpsProvider(
                accountId: account.id,
                organization: account.organization,
                tokenSource: tokens,
                authMethod: account.authMethod,
                http: http
            )
        case .gitHub:
            return GitHubProvider(accountId: account.id, owner: account.organization, tokenSource: tokens, http: http)
        }
    }
}
