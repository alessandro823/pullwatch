import Foundation

/// Een bekende kwetsbaarheid in een package van een repo.
public struct Vulnerability: Codable, Hashable, Sendable {
    /// OSV-id, bv. "GHSA-29mw-wpgm-hmr9" of "GO-2024-2687".
    public let id: String
    /// CVE-nummer als OSV er een kent.
    public let cve: String?
    public let summary: String?
    /// "LOW", "MODERATE", "HIGH" of "CRITICAL" (GitHub-advisories); nil als OSV geen ernst geeft.
    public let severity: String?
    public let ecosystem: String
    public let package: String
    public let version: String
    /// Laagste versie na `version` waarin het opgelost is.
    public let fixedIn: String?
    public let source: String

    public init(
        id: String, cve: String?, summary: String?, severity: String?, ecosystem: String,
        package: String, version: String, fixedIn: String?, source: String
    ) {
        self.id = id
        self.cve = cve
        self.summary = summary
        self.severity = severity
        self.ecosystem = ecosystem
        self.package = package
        self.version = version
        self.fixedIn = fixedIn
        self.source = source
    }

    public var url: URL { URL(string: "https://osv.dev/vulnerability")!.appending(path: id) }

    /// Hoe erg: critical 4 … low 1, onbekend 0.
    public var severityRank: Int {
        switch severity {
        case "CRITICAL": 4
        case "HIGH": 3
        case "MODERATE", "MEDIUM": 2
        case "LOW": 1
        default: 0
        }
    }
}

/// Details van één OSV-record, voor zover Pullwatch ze toont.
public struct OSVRecord: Equatable, Sendable {
    public let id: String
    public let aliases: [String]
    public let summary: String?
    public let severity: String?
    /// "ecosysteem/naam" → alle "fixed"-versies uit de ranges.
    public let fixed: [String: [String]]
}

public enum OSV {
    /// OSV staat maximaal 1000 queries per batch toe.
    static let batchSize = 1000
    static let detailConcurrency = 8

    /// Ids van kwetsbaarheden per dependency, in dezelfde volgorde als `dependencies`.
    public static func query(_ dependencies: [Dependency], http: any HTTPClient, now: Date = Date()) async throws -> [[String]] {
        struct Query: Encodable {
            struct Package: Encodable { let name: String; let ecosystem: String }
            let package: Package
            let version: String
        }
        struct Response: Decodable {
            struct Result: Decodable {
                struct Vuln: Decodable { let id: String }
                let vulns: [Vuln]?
            }
            let results: [Result]
        }
        var ids: [[String]] = []
        for start in stride(from: 0, to: dependencies.count, by: batchSize) {
            let chunk = dependencies[start..<min(start + batchSize, dependencies.count)]
            var request = URLRequest(url: URL(string: "https://api.osv.dev/v1/querybatch")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["queries": chunk.map {
                Query(package: .init(name: $0.name, ecosystem: $0.ecosystem), version: $0.version)
            }])
            let (data, response) = try await http.send(request)
            try HTTPStatus.check(response, now: now)
            let decoded = try JSONDecoding.decode(Response.self, from: data)
            guard decoded.results.count == chunk.count else { throw ProviderError.decoding("OSV: \(decoded.results.count) resultaten voor \(chunk.count) queries") }
            ids += decoded.results.map { ($0.vulns ?? []).map(\.id) }
        }
        return ids
    }

    public static func decodeRecord(_ data: Data) throws -> OSVRecord {
        struct Record: Decodable {
            struct DatabaseSpecific: Decodable { let severity: String? }
            struct Affected: Decodable {
                struct Package: Decodable { let name: String; let ecosystem: String }
                struct Range: Decodable {
                    struct Event: Decodable { let fixed: String? }
                    let type: String?
                    let events: [Event]
                }
                let package: Package?
                let ranges: [Range]?
            }
            let id: String
            let aliases: [String]?
            let summary: String?
            let databaseSpecific: DatabaseSpecific?
            let affected: [Affected]?
        }
        let record = try JSONDecoding.decode(Record.self, from: data, snakeCase: true)
        var fixed: [String: [String]] = [:]
        for affected in record.affected ?? [] {
            guard let package = affected.package else { continue }
            // GIT-ranges hebben commit-hashes in plaats van versies.
            let versions = (affected.ranges ?? []).filter { $0.type != "GIT" }.flatMap { $0.events.compactMap(\.fixed) }
            fixed["\(package.ecosystem)/\(package.name)", default: []] += versions
        }
        return OSVRecord(
            id: record.id,
            aliases: record.aliases ?? [],
            summary: record.summary,
            severity: record.databaseSpecific?.severity?.uppercased(),
            fixed: fixed
        )
    }

    public static func record(id: String, http: any HTTPClient, now: Date = Date()) async throws -> OSVRecord {
        let (data, response) = try await http.send(URLRequest(url: URL(string: "https://api.osv.dev/v1/vulns")!.appending(path: id)))
        try HTTPStatus.check(response, now: now)
        return try decodeRecord(data)
    }

    /// Haalt de details van alle ids op, maximaal `detailConcurrency` tegelijk. Mislukte ids ontbreken.
    public static func records(ids: Set<String>, http: any HTTPClient, now: Date = Date()) async -> [String: OSVRecord] {
        await withTaskGroup(of: OSVRecord?.self) { group in
            var pending = ids.sorted().makeIterator()
            var result: [String: OSVRecord] = [:]
            for _ in 0..<detailConcurrency {
                guard let id = pending.next() else { break }
                group.addTask { try? await record(id: id, http: http, now: now) }
            }
            for await record in group {
                if let record { result[record.id] = record }
                if let id = pending.next() {
                    group.addTask { try? await OSV.record(id: id, http: http, now: now) }
                }
            }
            return result
        }
    }

    /// Kwetsbaarheden per dependency; een id die alias is van een andere id voor hetzelfde package valt weg
    /// (GitHub en Go melden vaak hetzelfde lek onder twee ids).
    public static func vulnerabilities(
        dependencies: [Dependency],
        ids: [[String]],
        records: [String: OSVRecord]
    ) -> [Vulnerability] {
        var result: [Vulnerability] = []
        for (dependency, found) in zip(dependencies, ids) where !found.isEmpty {
            // Alfabetisch eerst: GHSA-… (met ernst) wint van GO-….
            var kept: [String] = []
            for id in found.sorted() {
                let duplicate = kept.contains { other in
                    records[other]?.aliases.contains(id) == true || records[id]?.aliases.contains(other) == true
                }
                if !duplicate { kept.append(id) }
            }
            for id in kept {
                let record = records[id]
                let fixes = record?.fixed["\(dependency.ecosystem)/\(dependency.name)"] ?? []
                let fixedIn = fixes
                    .filter { VersionChecker.isOlder(dependency.version, than: $0) }
                    .min { VersionChecker.isOlder($0, than: $1) }
                result.append(Vulnerability(
                    id: id,
                    cve: record?.aliases.first { $0.hasPrefix("CVE-") } ?? (id.hasPrefix("CVE-") ? id : nil),
                    summary: record?.summary,
                    severity: record?.severity,
                    ecosystem: dependency.ecosystem,
                    package: dependency.name,
                    version: dependency.version,
                    fixedIn: fixedIn,
                    source: dependency.source
                ))
            }
        }
        return result.sorted {
            if $0.severityRank != $1.severityRank { return $0.severityRank > $1.severityRank }
            return ($0.package, $0.id) < ($1.package, $1.id)
        }
    }
}
