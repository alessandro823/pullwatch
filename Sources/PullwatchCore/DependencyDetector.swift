import Foundation

/// Een package met exacte versie uit een lockfile of manifest, in OSV-termen.
public struct Dependency: Codable, Hashable, Sendable {
    /// OSV-ecosysteem: "Go", "npm", "NuGet", "PyPI", "Packagist", "crates.io" of "SwiftURL".
    public let ecosystem: String
    public let name: String
    public let version: String
    public let source: String

    public init(ecosystem: String, name: String, version: String, source: String) {
        self.ecosystem = ecosystem
        self.name = name
        self.version = version
        self.source = source
    }

    /// Zelfde package en versie, ongeacht het bestand; sleutel voor de OSV-query.
    var withoutSource: Dependency {
        Dependency(ecosystem: ecosystem, name: name, version: version, source: "")
    }
}

/// Leest packages met exacte versies voor de CVE-check. Versiebereiken (^1.2, >=3) tellen niet:
/// OSV heeft een exacte versie nodig. yarn.lock en pnpm-lock.yaml worden niet gelezen.
public enum DependencyDetector {
    public static func isRelevant(_ path: String) -> Bool {
        guard let name = path.split(separator: "/").last.map(String.init) else { return false }
        return name == "go.mod" || name == "package-lock.json" || name == "Package.resolved" || name == "composer.lock" || name == "Cargo.lock" || name == "poetry.lock" || name == "uv.lock"
            || name == "Directory.Packages.props" || name == "Directory.Build.props"
            || name.hasSuffix(".csproj") || name.hasSuffix(".fsproj")
            || (name.hasPrefix("requirements") && name.hasSuffix(".txt"))
    }

    public static func detect(path: String, content: String) -> [Dependency] {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        if name == "go.mod" { return goModules(content, path: path) }
        if name == "package-lock.json" { return npmLock(content, path: path) }
        if name == "composer.lock" { return composerLock(content, path: path) }
        if name == "Package.resolved" { return swiftPackages(content, path: path) }
        if name == "poetry.lock" || name == "uv.lock" { return tomlLock(content, path: path, ecosystem: "PyPI") }
        if name == "Cargo.lock" { return tomlLock(content, path: path, ecosystem: "crates.io", registryOnly: true) }
        if name.hasPrefix("requirements") { return requirements(content, path: path) }
        return nugetPackages(content, path: path)
    }

    /// `require x v1.2.3` en regels binnen `require ( … )`; de "v" valt weg zoals OSV verwacht.
    private static func goModules(_ content: String, path: String) -> [Dependency] {
        var result: [Dependency] = []
        var inBlock = false
        for raw in content.split(whereSeparator: \.isNewline) {
            var line = raw.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            line = line.trimmingCharacters(in: .whitespaces)
            if line == "require (" { inBlock = true; continue }
            if inBlock && line == ")" { inBlock = false; continue }
            if line.hasPrefix("require ") { line = String(line.dropFirst("require ".count)) } else if !inBlock { continue }
            let parts = line.split(separator: " ")
            guard parts.count == 2, parts[1].hasPrefix("v") else { continue }
            result.append(Dependency(ecosystem: "Go", name: String(parts[0]), version: String(parts[1].dropFirst()), source: path))
        }
        return result
    }

    /// lockfileVersion 2/3 (`packages`) en 1 (`dependencies`, alleen het hoogste niveau).
    private static func npmLock(_ content: String, path: String) -> [Dependency] {
        struct Entry: Decodable { let version: String? }
        struct Lock: Decodable {
            let packages: [String: Entry]?
            let dependencies: [String: Entry]?
        }
        guard let lock = try? JSONDecoder().decode(Lock.self, from: Data(content.utf8)) else { return [] }
        var seen: Set<String> = []
        var result: [Dependency] = []
        func add(_ name: String, _ version: String?) {
            guard !name.isEmpty, let version, StackDetector.version(from: version) != nil, !version.contains(":"),
                  seen.insert("\(name)@\(version)").inserted else { return }
            result.append(Dependency(ecosystem: "npm", name: name, version: version, source: path))
        }
        if let packages = lock.packages {
            for (key, entry) in packages {
                guard let range = key.range(of: "node_modules/", options: .backwards) else { continue }
                add(String(key[range.upperBound...]), entry.version)
            }
        } else {
            for (name, entry) in lock.dependencies ?? [:] { add(name, entry.version) }
        }
        return result.sorted { ($0.name, $0.version) < ($1.name, $1.version) }
    }

    /// `packages` en `packages-dev`; de "v" van tags valt weg, branches (`dev-main`) tellen niet.
    private static func composerLock(_ content: String, path: String) -> [Dependency] {
        struct Package: Decodable { let name: String; let version: String }
        struct Lock: Decodable {
            let packages: [Package]?
            let packagesDev: [Package]?
            enum CodingKeys: String, CodingKey { case packages, packagesDev = "packages-dev" }
        }
        guard let lock = try? JSONDecoder().decode(Lock.self, from: Data(content.utf8)) else { return [] }
        return ((lock.packages ?? []) + (lock.packagesDev ?? [])).compactMap { package in
            guard !package.version.hasPrefix("dev-") else { return nil }
            let version = package.version.hasPrefix("v") ? String(package.version.dropFirst()) : package.version
            guard StackDetector.version(from: version) != nil else { return nil }
            return Dependency(ecosystem: "Packagist", name: package.name, version: version, source: path)
        }
    }

    /// Package.resolved v1 (`object.pins`, `repositoryURL`) en v2/v3 (`pins`, `location`). OSV kent
    /// Swift-packages als URL zonder schema en ".git": `github.com/apple/swift-nio`. Pins op een
    /// branch of commit (geen `version`) tellen niet.
    private static func swiftPackages(_ content: String, path: String) -> [Dependency] {
        struct Pin: Decodable {
            struct State: Decodable { let version: String? }
            let location: String?
            let repositoryURL: String?
            let state: State
        }
        struct Resolved: Decodable {
            struct Object: Decodable { let pins: [Pin] }
            let pins: [Pin]?
            let object: Object?
        }
        guard let resolved = try? JSONDecoder().decode(Resolved.self, from: Data(content.utf8)) else { return [] }
        return (resolved.pins ?? resolved.object?.pins ?? []).compactMap { pin in
            guard let url = pin.location ?? pin.repositoryURL, let version = pin.state.version else { return nil }
            return Dependency(ecosystem: "SwiftURL", name: swiftPackageName(url), version: version, source: path)
        }
    }

    /// "https://github.com/apple/swift-nio.git" en "git@github.com:apple/swift-nio.git" → "github.com/apple/swift-nio".
    static func swiftPackageName(_ url: String) -> String {
        var name = url
        if let scheme = name.range(of: "://") { name = String(name[scheme.upperBound...]) }
        if name.hasPrefix("git@") { name = String(name.dropFirst(4)).replacingOccurrences(of: ":", with: "/") }
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        if name.hasSuffix("/") { name = String(name.dropLast()) }
        return name
    }

    /// `[[package]]`-blokken met `name = "…"` en `version = "…"` (poetry.lock, uv.lock, Cargo.lock).
    /// `registryOnly`: alleen packages met `source = "registry+…"`; workspace-crates en git-forks
    /// staan niet op crates.io.
    private static func tomlLock(_ content: String, path: String, ecosystem: String, registryOnly: Bool = false) -> [Dependency] {
        var result: [Dependency] = []
        var name: String?
        var version: String?
        var fromRegistry = false
        func flush() {
            if let name, let version, !registryOnly || fromRegistry {
                result.append(Dependency(ecosystem: ecosystem, name: name, version: version, source: path))
            }
            name = nil
            version = nil
            fromRegistry = false
        }
        for raw in content.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                flush()
                continue
            }
            if line.hasPrefix("source = \"registry+") { fromRegistry = true }
            if let m = line.wholeMatch(of: /(name|version)\s*=\s*"([^"]+)"/) {
                if m.output.1 == "name" { name = name ?? String(m.output.2) } else { version = version ?? String(m.output.2) }
            }
        }
        flush()
        return result
    }

    /// Alleen `pakket==versie`; extras (`pakket[x]==1`) en markers (`; python_version…`) worden genegeerd.
    private static func requirements(_ content: String, path: String) -> [Dependency] {
        content.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let spec = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            guard let m = spec.trimmingCharacters(in: .whitespaces).wholeMatch(of: /([A-Za-z0-9._-]+)(\[[^\]]*\])?\s*==\s*([^\s,]+)/) else {
                return nil
            }
            return Dependency(ecosystem: "PyPI", name: String(m.output.1), version: String(m.output.3), source: path)
        }
    }

    /// `<PackageReference Include="X" Version="1.2.3" />` en `<PackageVersion …>`; attributen in elke volgorde.
    private static func nugetPackages(_ content: String, path: String) -> [Dependency] {
        content.matches(of: /<Package(?:Reference|Version)\b([^>]*)>/).compactMap { match in
            let attributes = String(match.output.1)
            guard let include = attributes.firstMatch(of: /Include="([^"]+)"/)?.output.1,
                  let version = attributes.firstMatch(of: /Version="([^"$\[\]()*]+)"/)?.output.1 else { return nil }
            return Dependency(ecosystem: "NuGet", name: String(include), version: String(version), source: path)
        }
    }
}
