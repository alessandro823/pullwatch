import Foundation

/// Eén onderdeel (taal, runtime, framework of Docker-image) van een repo met zijn status.
public struct ComponentVersion: Codable, Hashable, Sendable {
    public let product: String
    public let label: String
    /// Oudste gevonden versie als het onderdeel in meerdere bestanden staat.
    public let version: String
    public let latest: String?
    public let status: VersionStatus
    public let sources: [String]

    public init(product: String, label: String, version: String, latest: String?, status: VersionStatus, sources: [String]) {
        self.product = product
        self.label = label
        self.version = version
        self.latest = latest
        self.status = status
        self.sources = sources
    }
}

public struct RepoVersions: Codable, Hashable, Sendable, Identifiable {
    public let accountId: UUID
    public let repo: String
    public let components: [ComponentVersion]
    public let error: String?

    public var id: String { "\(accountId.uuidString)/\(repo)" }

    /// Slechtste status van de onderdelen; een fout telt als onbekend.
    public var worstStatus: VersionStatus? {
        if error != nil { return .unknown }
        return components.map(\.status).max()
    }

    public init(accountId: UUID, repo: String, components: [ComponentVersion], error: String? = nil) {
        self.accountId = accountId
        self.repo = repo
        self.components = components
        self.error = error
    }
}

public struct VersionReport: Codable, Equatable, Sendable {
    public let checkedAt: Date
    /// Slechtste status eerst, dan alfabetisch.
    public let repos: [RepoVersions]

    public init(checkedAt: Date, repos: [RepoVersions]) {
        self.checkedAt = checkedAt
        self.repos = repos.sorted {
            let (l, r) = ($0.worstStatus?.severity ?? -1, $1.worstStatus?.severity ?? -1)
            if l != r { return l > r }
            return $0.repo.localizedCaseInsensitiveCompare($1.repo) == .orderedAscending
        }
    }
}

/// Leest per gevolgde repo de projectbestanden en vergelijkt de gevonden versies met endoflife.date.
public struct VersionChecker: Sendable {
    private let makeProvider: @Sendable (Account) -> any PRProvider
    private let http: any HTTPClient
    private let now: @Sendable () -> Date

    public init(
        makeProvider: @escaping @Sendable (Account) -> any PRProvider,
        http: any HTTPClient = URLSessionHTTPClient(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.makeProvider = makeProvider
        self.http = http
        self.now = now
    }

    /// `progress(done, total)` na het bepalen van de repo's en na elke gescande repo.
    public func run(accounts: [Account], progress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in }) async -> VersionReport {
        // 1. Gevolgde repo's per account.
        var targets: [(account: Account, provider: any PRProvider, repos: [String])] = []
        var results: [RepoVersions] = []
        for account in accounts {
            let provider = makeProvider(account)
            do {
                let repos = try await provider.listRepos().filter {
                    let watch = account.watch(for: $0)
                    return watch.prs || watch.tags || watch.completed
                }
                targets.append((account, provider, repos))
            } catch {
                results.append(RepoVersions(accountId: account.id, repo: account.displayName, components: [], error: Self.message(error)))
            }
        }

        // 2. Bestanden scannen; accounts parallel, repo's per account na elkaar.
        let total = targets.reduce(0) { $0 + $1.repos.count }
        let counter = Counter()
        await progress(0, total)
        let scanned = await withTaskGroup(of: [(accountId: UUID, repo: String, found: Result<[DetectedVersion], Error>)].self) { group in
            for target in targets {
                group.addTask {
                    var out: [(accountId: UUID, repo: String, found: Result<[DetectedVersion], Error>)] = []
                    for repo in target.repos {
                        let found: Result<[DetectedVersion], Error>
                        do {
                            found = .success(try await Self.scan(repo: repo, provider: target.provider))
                        } catch {
                            found = .failure(error)
                        }
                        out.append((target.account.id, repo, found))
                        await progress(await counter.increment(), total)
                    }
                    return out
                }
            }
            return await group.reduce(into: []) { $0 += $1 }
        }

        // 3. Releases per product, één keer per check.
        let products = Set(scanned.flatMap { (try? $0.found.get())?.map(\.product) ?? [] })
        let releases = await withTaskGroup(of: (String, [EndOfLifeRelease]?).self) { group in
            for product in products {
                group.addTask { (product, try? await EndOfLife.fetch(product: product, http: http, now: now())) }
            }
            return await group.reduce(into: [String: [EndOfLifeRelease]]()) { $0[$1.0] = $1.1 }
        }

        // 4. Per repo samenvoegen en beoordelen.
        let date = now()
        for item in scanned {
            switch item.found {
            case .failure(let error):
                results.append(RepoVersions(accountId: item.accountId, repo: item.repo, components: [], error: Self.message(error)))
            case .success(let found):
                let components = Self.combine(found).map { detected, sources in
                    let evaluation = releases[detected.product].flatMap { $0 }
                        .map { EndOfLife.evaluate(version: detected.version, releases: $0, now: date) }
                        ?? (status: .unknown, latest: nil)
                    return ComponentVersion(
                        product: detected.product,
                        label: detected.label,
                        version: detected.version,
                        latest: evaluation.latest,
                        status: evaluation.status,
                        sources: sources
                    )
                }
                results.append(RepoVersions(accountId: item.accountId, repo: item.repo, components: components))
            }
        }
        return VersionReport(checkedAt: date, repos: results)
    }

    private static func scan(repo: String, provider: any PRProvider) async throws -> [DetectedVersion] {
        let paths = try await provider.filePaths(in: repo).filter(StackDetector.isRelevant).prefix(StackDetector.maxFiles)
        var found: [DetectedVersion] = []
        for path in paths {
            // Eén onleesbaar bestand mag de rest van de repo niet blokkeren.
            guard let content = try? await provider.fileContent(in: repo, path: path) else { continue }
            found += StackDetector.detect(path: path, content: content)
        }
        return found
    }

    /// Eén onderdeel per label met de oudste versie; bronnen ontdubbeld, op volgorde van vinden.
    static func combine(_ found: [DetectedVersion]) -> [(DetectedVersion, [String])] {
        var order: [String] = []
        var oldest: [String: DetectedVersion] = [:]
        var sources: [String: [String]] = [:]
        for item in found {
            if oldest[item.label] == nil { order.append(item.label) }
            if let current = oldest[item.label] {
                if isOlder(item.version, than: current.version) { oldest[item.label] = item }
            } else {
                oldest[item.label] = item
            }
            if !(sources[item.label] ?? []).contains(item.source) { sources[item.label, default: []].append(item.source) }
        }
        return order.map { (oldest[$0]!, sources[$0] ?? []) }
    }

    static func isOlder(_ a: String, than b: String) -> Bool {
        let (x, y) = (a.split(separator: ".").map { Int($0) ?? 0 }, b.split(separator: ".").map { Int($0) ?? 0 })
        for i in 0..<max(x.count, y.count) {
            let (l, r) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if l != r { return l < r }
        }
        return false
    }

    private static func message(_ error: any Error) -> String {
        (error as? ProviderError)?.userMessage ?? error.localizedDescription
    }
}

private actor Counter {
    private var value = 0
    func increment() -> Int {
        value += 1
        return value
    }
}
