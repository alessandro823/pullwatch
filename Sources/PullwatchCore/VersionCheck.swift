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
    /// Ernstigste eerst.
    public let vulnerabilities: [Vulnerability]
    /// Gezet als de CVE-check voor deze repo niet kon draaien (OSV onbereikbaar).
    public let vulnerabilityError: String?

    public var id: String { "\(accountId.uuidString)/\(repo)" }

    /// Slechtste status van de onderdelen; een fout telt als onbekend.
    public var worstStatus: VersionStatus? {
        if error != nil { return .unknown }
        return components.map(\.status).max()
    }

    /// Voor sorteren: een kwetsbaarheid weegt even zwaar als EOL.
    public var severity: Int {
        max(worstStatus?.severity ?? -1, vulnerabilities.isEmpty ? -1 : VersionStatus.eol.severity)
    }

    public init(
        accountId: UUID,
        repo: String,
        components: [ComponentVersion],
        error: String? = nil,
        vulnerabilities: [Vulnerability] = [],
        vulnerabilityError: String? = nil
    ) {
        self.accountId = accountId
        self.repo = repo
        self.components = components
        self.error = error
        self.vulnerabilities = vulnerabilities
        self.vulnerabilityError = vulnerabilityError
    }

    private enum CodingKeys: String, CodingKey {
        case accountId, repo, components, error, vulnerabilities, vulnerabilityError
    }

    /// versions.json van vóór de CVE-check heeft geen `vulnerabilities`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountId = try c.decode(UUID.self, forKey: .accountId)
        repo = try c.decode(String.self, forKey: .repo)
        components = try c.decode([ComponentVersion].self, forKey: .components)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        vulnerabilities = try c.decodeIfPresent([Vulnerability].self, forKey: .vulnerabilities) ?? []
        vulnerabilityError = try c.decodeIfPresent(String.self, forKey: .vulnerabilityError)
    }
}

public struct VersionReport: Codable, Equatable, Sendable {
    public let checkedAt: Date
    /// Slechtste status eerst, dan meeste kwetsbaarheden, dan alfabetisch.
    public let repos: [RepoVersions]

    public init(checkedAt: Date, repos: [RepoVersions]) {
        self.checkedAt = checkedAt
        self.repos = repos.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            if $0.vulnerabilities.count != $1.vulnerabilities.count { return $0.vulnerabilities.count > $1.vulnerabilities.count }
            return $0.repo.localizedCaseInsensitiveCompare($1.repo) == .orderedAscending
        }
    }
}

extension VersionReport {
    /// Automatische check: eens per dag.
    public static let autoInterval: TimeInterval = 24 * 3600
    /// Na een volledig mislukte automatische check (bv. offline) opnieuw na een uur.
    public static let autoRetryInterval: TimeInterval = 3600

    /// Elke repo gaf een fout: geen bruikbaar resultaat (bv. geen netwerk).
    public var failedCompletely: Bool {
        !repos.isEmpty && repos.allSatisfy { $0.error != nil }
    }

    /// Kwetsbaarheden die in `previous` nog niet voor die repo bestonden. Zonder vorige check,
    /// voor een repo die er toen niet bij zat of waarvan de CVE-check toen mislukte, telt
    /// alles als bekend: anders komt er een stortvloed aan meldingen.
    public func newVulnerabilities(since previous: VersionReport?) -> [(repo: String, vulnerability: Vulnerability)] {
        guard let previous else { return [] }
        let before = Dictionary(previous.repos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [(repo: String, vulnerability: Vulnerability)] = []
        for repo in repos {
            guard let old = before[repo.id], old.error == nil, old.vulnerabilityError == nil else { continue }
            let known = Set(old.vulnerabilities.map { "\($0.id)|\($0.package)" })
            for vulnerability in repo.vulnerabilities where !known.contains("\(vulnerability.id)|\(vulnerability.package)") {
                result.append((repo.repo, vulnerability))
            }
        }
        return result
    }
}

/// Leest per gevolgde repo de projectbestanden, vergelijkt de gevonden versies met endoflife.date
/// en zoekt bekende kwetsbaarheden in de packages via OSV.dev.
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
        let scanned = await withTaskGroup(of: [(accountId: UUID, repo: String, found: Result<Scan, Error>)].self) { group in
            for target in targets {
                group.addTask {
                    var out: [(accountId: UUID, repo: String, found: Result<Scan, Error>)] = []
                    for repo in target.repos {
                        let found: Result<Scan, Error>
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
        let products = Set(scanned.flatMap { (try? $0.found.get())?.versions.map(\.product) ?? [] })
        let releases = await withTaskGroup(of: (String, [EndOfLifeRelease]?).self) { group in
            for product in products {
                group.addTask { (product, try? await EndOfLife.fetch(product: product, http: http, now: now())) }
            }
            return await group.reduce(into: [String: [EndOfLifeRelease]]()) { $0[$1.0] = $1.1 }
        }

        // 4. Kwetsbaarheden: één batch voor alle unieke packages, daarna details per id.
        let dependencies = Array(Set(scanned.flatMap { (try? $0.found.get())?.dependencies ?? [] }.map(\.withoutSource)))
        var vulnerabilityIds: [Dependency: [String]] = [:]
        var osvError: String?
        var records: [String: OSVRecord] = [:]
        if !dependencies.isEmpty {
            do {
                let ids = try await OSV.query(dependencies, http: http, now: now())
                vulnerabilityIds = Dictionary(uniqueKeysWithValues: zip(dependencies, ids))
                records = await OSV.records(ids: Set(ids.joined()), http: http, now: now())
            } catch {
                osvError = "CVE-check mislukt: " + Self.message(error)
            }
        }

        // 5. Per repo samenvoegen en beoordelen.
        let date = now()
        for item in scanned {
            switch item.found {
            case .failure(let error):
                results.append(RepoVersions(accountId: item.accountId, repo: item.repo, components: [], error: Self.message(error)))
            case .success(let scan):
                let components = Self.combine(scan.versions).map { detected, sources in
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
                let repoDependencies = scan.dependencies
                let vulnerabilities = OSV.vulnerabilities(
                    dependencies: repoDependencies,
                    ids: repoDependencies.map { vulnerabilityIds[$0.withoutSource] ?? [] },
                    records: records
                )
                results.append(RepoVersions(
                    accountId: item.accountId,
                    repo: item.repo,
                    components: components,
                    vulnerabilities: vulnerabilities,
                    vulnerabilityError: repoDependencies.isEmpty ? nil : osvError
                ))
            }
        }
        return VersionReport(checkedAt: date, repos: results)
    }

    struct Scan: Sendable {
        var versions: [DetectedVersion] = []
        var dependencies: [Dependency] = []
    }

    private static func scan(repo: String, provider: any PRProvider) async throws -> Scan {
        let paths = try await provider.filePaths(in: repo)
            .filter { StackDetector.isRelevant($0) || (DependencyDetector.isRelevant($0) && !StackDetector.isIgnored($0)) }
            .prefix(StackDetector.maxFiles)
        var scan = Scan()
        for path in paths {
            // Eén onleesbaar bestand mag de rest van de repo niet blokkeren.
            guard let content = try? await provider.fileContent(in: repo, path: path) else { continue }
            scan.versions += StackDetector.detect(path: path, content: content)
            if DependencyDetector.isRelevant(path) {
                // Zelfde package uit twee bestanden telt één keer (eerste bron wint).
                for dependency in DependencyDetector.detect(path: path, content: content)
                where !scan.dependencies.contains(where: { $0.withoutSource == dependency.withoutSource }) {
                    scan.dependencies.append(dependency)
                }
            }
        }
        return scan
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
