import Foundation

/// Een taal-, runtime- of frameworkversie gevonden in één bestand van een repo.
public struct DetectedVersion: Codable, Hashable, Sendable {
    /// Productnaam bij endoflife.date (bv. "go", "nodejs", "dotnet").
    public let product: String
    /// Weergavenaam; Docker-images krijgen "Docker " ervoor zodat ze los van de taal staan.
    public let label: String
    public let version: String
    public let source: String
    /// Ondergrens uit een versie-eis (`engines.node`, composer `php`, `rust-version`, `requires-python`),
    /// niet wat er echt draait; valt weg als dezelfde taal ergens vastgezet is.
    public let isMinimum: Bool

    public init(product: String, label: String, version: String, source: String, isMinimum: Bool = false) {
        self.product = product
        self.label = label
        self.version = version
        self.source = source
        self.isMinimum = isMinimum
    }
}

/// Herkent versies in bekende projectbestanden. Alleen tekstverwerking, geen netwerk.
public enum StackDetector {
    /// Maximaal aantal bestanden dat per repo gelezen wordt.
    public static let maxFiles = 50

    private static let ignoredFolders: Set<String> = ["node_modules", "vendor", ".git", "bin", "obj", "dist", "build", ".build"]

    private static let packageFrameworks: [(dependency: String, product: String, label: String)] = [
        ("@angular/core", "angular", "Angular"),
        ("react", "react", "React"),
        ("vue", "vue", "Vue"),
        ("next", "nextjs", "Next.js"),
        ("nuxt", "nuxt", "Nuxt"),
    ]

    /// Composer-packages waarvan de versie de frameworkversie volgt; de eerste gevonden telt.
    private static let composerFrameworks: [(dependency: String, product: String, label: String)] = [
        ("laravel/framework", "laravel", "Laravel"),
        ("symfony/framework-bundle", "symfony", "Symfony"),
        ("symfony/http-kernel", "symfony", "Symfony"),
        ("symfony/console", "symfony", "Symfony"),
    ]

    /// Frameworks waarvan de geïnstalleerde versie in een lockfile staat; die gaat voor het
    /// minimum uit de versiespecificatie ("^7.2" kan 7.4 zijn).
    public static let lockedPackages: [String: Set<String>] = [
        "angular": ["@angular/core"], "react": ["react"], "vue": ["vue"], "nextjs": ["next"], "nuxt": ["nuxt"],
        "laravel": ["laravel/framework"],
        "symfony": ["symfony/framework-bundle", "symfony/http-kernel", "symfony/console"],
    ]

    /// Docker-image (laatste padsegment, of het volledige pad voor mcr.microsoft.com/dotnet/*) → product.
    private static let dockerImages: [String: String] = [
        "node": "nodejs", "golang": "go", "python": "python", "alpine": "alpine-linux",
        "debian": "debian", "ubuntu": "ubuntu", "nginx": "nginx", "postgres": "postgresql",
        "redis": "redis", "eclipse-temurin": "eclipse-temurin", "rust": "rust", "php": "php", "ruby": "ruby",
    ]

    /// Pad ligt in een map die nooit gelezen wordt (node_modules, vendor, bin, …).
    public static func isIgnored(_ path: String) -> Bool {
        path.split(separator: "/").dropLast().contains { ignoredFolders.contains(String($0)) }
    }

    public static func isRelevant(_ path: String) -> Bool {
        guard let name = path.split(separator: "/").last.map(String.init) else { return false }
        if isIgnored(path) { return false }
        // Alleen de Cargo.toml in de root: daar staat bij een workspace de rust-version.
        if path == "Cargo.toml" { return true }
        if isWorkflow(path) { return true }
        return name == "go.mod" || name == "package.json" || name == "composer.json" || name == "Package.swift"
            || name == "rust-toolchain" || name == "rust-toolchain.toml" || name == ".nvmrc" || name == ".node-version"
            || name == "pyproject.toml" || name == ".python-version" || name == "Directory.Build.props"
            || name.hasSuffix(".csproj") || name.hasSuffix(".fsproj") || name.hasPrefix("Dockerfile")
    }

    public static func detect(path: String, content: String) -> [DetectedVersion] {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        func found(_ product: String, _ label: String, _ spec: String, isMinimum: Bool = false) -> DetectedVersion? {
            version(from: spec).map { DetectedVersion(product: product, label: label, version: $0, source: path, isMinimum: isMinimum) }
        }

        switch name {
        case "go.mod":
            let line = content.split(whereSeparator: \.isNewline).first { $0.hasPrefix("go ") }
            return line.flatMap { found("go", "Go", String($0.dropFirst(3))) }.map { [$0] } ?? []
        case ".nvmrc", ".node-version":
            return found("nodejs", "Node", content).map { [$0] } ?? []
        case ".python-version":
            return found("python", "Python", content).map { [$0] } ?? []
        case "pyproject.toml":
            let line = content.split(whereSeparator: \.isNewline).first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("requires-python") }
            let spec = line.flatMap { $0.split(separator: "=", maxSplits: 1).last }.map(String.init)
            return spec.flatMap { found("python", "Python", $0, isMinimum: true) }.map { [$0] } ?? []
        case "package.json":
            return detectPackageJSON(content, path: path)
        case "composer.json":
            return detectComposerJSON(content, path: path)
        case "rust-toolchain":
            return found("rust", "Rust", content).map { [$0] } ?? []
        case "rust-toolchain.toml":
            return tomlString("channel", in: content).flatMap { found("rust", "Rust", $0) }.map { [$0] } ?? []
        case "Package.swift":
            // `// swift-tools-version: 6.0` op de eerste regel: de minimaal benodigde Swift.
            let line = content.split(whereSeparator: \.isNewline).first { $0.contains("swift-tools-version") }
            return line.flatMap { $0.split(separator: ":", maxSplits: 1).last }
                .flatMap { found("swift", "Swift", String($0)) }.map { [$0] } ?? []
        case "Cargo.toml":
            return tomlString("rust-version", in: content).flatMap { found("rust", "Rust", $0, isMinimum: true) }.map { [$0] } ?? []
        default:
            if isWorkflow(path) {
                return detectWorkflow(content, path: path)
            }
            if name.hasSuffix(".csproj") || name.hasSuffix(".fsproj") || name == "Directory.Build.props" {
                return dotnetVersions(in: content).map { DetectedVersion(product: "dotnet", label: ".NET", version: $0, source: path) }
            }
            if name.hasPrefix("Dockerfile") {
                return detectDockerfile(content, path: path)
            }
            return []
        }
    }

    /// GitHub Actions-workflow (`.github/workflows/*.yml`).
    static func isWorkflow(_ path: String) -> Bool {
        path.hasPrefix(".github/workflows/") && (path.hasSuffix(".yml") || path.hasSuffix(".yaml"))
    }

    /// `python-version`, `node-version`, `go-version` en `dotnet-version` van de setup-acties,
    /// ook als matrixlijst (`['3.9', '3.x']` of regels met `- "3.9"`). Wat CI test is een
    /// ondergrens, geen vastgezette versie. Variabelen (`${{ … }}`) en Python `3.x` tellen niet.
    private static func detectWorkflow(_ content: String, path: String) -> [DetectedVersion] {
        let products = ["python": ("python", "Python"), "node": ("nodejs", "Node"), "go": ("go", "Go"), "dotnet": ("dotnet", ".NET")]
        var result: [DetectedVersion] = []
        func add(_ key: String, _ value: Substring) {
            guard let (product, label) = products[key] else { return }
            for item in value.split(whereSeparator: { ",[]".contains($0) }) {
                var spec = item.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "'\"-")))
                // "20.x" → 20, "8.0.x" → 8.0; "3.x" (Python 3) zegt niets.
                if spec.hasSuffix(".x") || spec.hasSuffix(".*") { spec = String(spec.dropLast(2)) }
                guard !spec.isEmpty, !spec.contains("$"), !(product == "python" && !spec.contains(".")),
                      let version = version(from: spec), spec == version else { continue }
                result.append(DetectedVersion(product: product, label: label, version: version, source: path, isMinimum: true))
            }
        }
        let lines = content.split(whereSeparator: \.isNewline)
        var listKey: String?
        for raw in lines {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let key = listKey, trimmed.hasPrefix("-") {
                add(key, Substring(trimmed.dropFirst()))
                continue
            }
            listKey = nil
            guard let m = trimmed.wholeMatch(of: /(python|node|go|dotnet)-version\s*:\s*(.*)/) else { continue }
            if m.output.2.isEmpty {
                listKey = String(m.output.1)
            } else {
                add(String(m.output.1), m.output.2)
            }
        }
        return result
    }

    /// Eerste `getal(.getal)*` uit een versiespecificatie: "^17.2.0" → "17.2.0", "20-alpine" → "20".
    public static func version(from spec: String) -> String? {
        guard let match = spec.firstMatch(of: /\d+(\.\d+)*/) else { return nil }
        return String(match.output.0)
    }

    private static func detectPackageJSON(_ content: String, path: String) -> [DetectedVersion] {
        struct PackageJSON: Decodable {
            let engines: [String: String]?
            let dependencies: [String: String]?
            let devDependencies: [String: String]?
        }
        guard let package = try? JSONDecoder().decode(PackageJSON.self, from: Data(content.utf8)) else { return [] }
        var result: [DetectedVersion] = []
        if let node = package.engines?["node"], let v = version(from: node) {
            result.append(DetectedVersion(product: "nodejs", label: "Node", version: v, source: path, isMinimum: true))
        }
        let dependencies = (package.devDependencies ?? [:]).merging(package.dependencies ?? [:]) { _, prod in prod }
        for framework in packageFrameworks {
            if let spec = dependencies[framework.dependency], let v = version(from: spec) {
                result.append(DetectedVersion(product: framework.product, label: framework.label, version: v, source: path))
            }
        }
        return result
    }

    /// Mappen (vanaf de repo-root) van lokale modules uit `replace x => ./pad` in een go.mod.
    /// Zo'n module is een gevendorde dependency; zijn `go`-regel is een minimum, niet de buildversie.
    public static func localGoReplacements(path: String, content: String) -> [String] {
        let base = path.split(separator: "/").dropLast().map(String.init)
        return content.split(whereSeparator: \.isNewline).compactMap { line in
            guard let arrow = line.range(of: "=>") else { return nil }
            let target = line[arrow.upperBound...].split(separator: " ").first.map(String.init) ?? ""
            guard target.hasPrefix("./") || target.hasPrefix("../") else { return nil }
            var parts = base
            for component in target.split(separator: "/") {
                if component == ".." { _ = parts.popLast() } else if component != "." { parts.append(String(component)) }
            }
            return parts.joined(separator: "/")
        }
    }

    /// Waarde van de eerste regel `key = "waarde"`, ongeacht de sectie.
    private static func tomlString(_ key: String, in content: String) -> String? {
        for line in content.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == key else { continue }
            return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    private static func detectComposerJSON(_ content: String, path: String) -> [DetectedVersion] {
        struct ComposerJSON: Decodable {
            let require: [String: String]?
        }
        guard let composer = try? JSONDecoder().decode(ComposerJSON.self, from: Data(content.utf8)) else { return [] }
        let require = composer.require ?? [:]
        var result: [DetectedVersion] = []
        if let php = require["php"], let v = version(from: php) {
            result.append(DetectedVersion(product: "php", label: "PHP", version: v, source: path, isMinimum: true))
        }
        var products: Set<String> = []
        for framework in composerFrameworks where !products.contains(framework.product) {
            if let spec = require[framework.dependency], let v = version(from: spec) {
                products.insert(framework.product)
                result.append(DetectedVersion(product: framework.product, label: framework.label, version: v, source: path))
            }
        }
        return result
    }

    /// "net8.0" en "net9.0-windows" tellen; netstandard, netcoreapp en .NET Framework (net48) niet.
    private static func dotnetVersions(in content: String) -> [String] {
        var versions: [String] = []
        for match in content.matches(of: /<TargetFrameworks?>([^<]*)<\/TargetFrameworks?>/) {
            for framework in match.output.1.split(separator: ";") {
                let value = framework.trimmingCharacters(in: .whitespaces)
                if let m = value.wholeMatch(of: /net(\d+\.\d+)(-.*)?/), !versions.contains(String(m.output.1)) {
                    versions.append(String(m.output.1))
                }
            }
        }
        return versions
    }

    private static func detectDockerfile(_ content: String, path: String) -> [DetectedVersion] {
        var result: [DetectedVersion] = []
        var args: [String: String] = [:]
        for line in content.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ").filter { !$0.hasPrefix("--") }
            if words.count >= 2, words[0].uppercased() == "ARG" {
                let parts = words[1].split(separator: "=", maxSplits: 1)
                if parts.count == 2 { args[String(parts[0])] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
                continue
            }
            guard words.count >= 2, words[0].uppercased() == "FROM" else { continue }
            // ARG-standaardwaarden invullen en een digest (@sha256:…) weghalen.
            var reference = String(words[1])
            for (name, value) in args {
                reference = reference.replacingOccurrences(of: "${\(name)}", with: value)
                reference = reference.replacingOccurrences(of: "$\(name)", with: value)
            }
            if let at = reference.firstIndex(of: "@") { reference = String(reference[..<at]) }
            guard !reference.contains("$"), let colon = reference.lastIndex(of: ":") else { continue }
            let image = String(reference[..<colon])
            let tag = String(reference[reference.index(after: colon)...])
            let imageName = String(image.split(separator: "/").last ?? "")
            // Eigen images als "php-fpm-alpine-custom" herkennen aan een bekende naam vóór het eerste "-".
            let knownPrefix = imageName.split(separator: "-").first.map(String.init).flatMap { dockerImages[$0] == nil ? nil : $0 }
            let shortName = image.hasPrefix("mcr.microsoft.com/dotnet/") ? "dotnet"
                : dockerImages[imageName] != nil ? imageName : (knownPrefix ?? imageName)
            let product = shortName == "dotnet" ? "dotnet" : dockerImages[shortName]
            guard let product, let v = version(from: tag) else { continue }
            result.append(DetectedVersion(product: product, label: "Docker \(shortName)", version: v, source: path))
        }
        return result
    }
}
