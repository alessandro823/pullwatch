import Foundation

/// Een taal-, runtime- of frameworkversie gevonden in één bestand van een repo.
public struct DetectedVersion: Codable, Hashable, Sendable {
    /// Productnaam bij endoflife.date (bv. "go", "nodejs", "dotnet").
    public let product: String
    /// Weergavenaam; Docker-images krijgen "Docker " ervoor zodat ze los van de taal staan.
    public let label: String
    public let version: String
    public let source: String

    public init(product: String, label: String, version: String, source: String) {
        self.product = product
        self.label = label
        self.version = version
        self.source = source
    }
}

/// Herkent versies in bekende projectbestanden. Alleen tekstverwerking, geen netwerk.
public enum StackDetector {
    /// Maximaal aantal bestanden dat per repo gelezen wordt.
    public static let maxFiles = 50

    private static let ignoredFolders: Set<String> = ["node_modules", "vendor", ".git", "bin", "obj", "dist", "build"]

    private static let packageFrameworks: [(dependency: String, product: String, label: String)] = [
        ("@angular/core", "angular", "Angular"),
        ("react", "react", "React"),
        ("vue", "vue", "Vue"),
        ("next", "nextjs", "Next.js"),
        ("nuxt", "nuxt", "Nuxt"),
    ]

    /// Docker-image (laatste padsegment, of het volledige pad voor mcr.microsoft.com/dotnet/*) → product.
    private static let dockerImages: [String: String] = [
        "node": "nodejs", "golang": "go", "python": "python", "alpine": "alpine-linux",
        "debian": "debian", "ubuntu": "ubuntu", "nginx": "nginx", "postgres": "postgresql",
        "redis": "redis", "eclipse-temurin": "eclipse-temurin", "rust": "rust", "php": "php", "ruby": "ruby",
    ]

    public static func isRelevant(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        guard let name = components.last.map(String.init) else { return false }
        if components.dropLast().contains(where: { ignoredFolders.contains(String($0)) }) { return false }
        return name == "go.mod" || name == "package.json" || name == ".nvmrc" || name == ".node-version"
            || name == "pyproject.toml" || name == ".python-version" || name == "Directory.Build.props"
            || name.hasSuffix(".csproj") || name.hasSuffix(".fsproj") || name.hasPrefix("Dockerfile")
    }

    public static func detect(path: String, content: String) -> [DetectedVersion] {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        func found(_ product: String, _ label: String, _ spec: String) -> DetectedVersion? {
            version(from: spec).map { DetectedVersion(product: product, label: label, version: $0, source: path) }
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
            return spec.flatMap { found("python", "Python", $0) }.map { [$0] } ?? []
        case "package.json":
            return detectPackageJSON(content, path: path)
        default:
            if name.hasSuffix(".csproj") || name.hasSuffix(".fsproj") || name == "Directory.Build.props" {
                return dotnetVersions(in: content).map { DetectedVersion(product: "dotnet", label: ".NET", version: $0, source: path) }
            }
            if name.hasPrefix("Dockerfile") {
                return detectDockerfile(content, path: path)
            }
            return []
        }
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
            result.append(DetectedVersion(product: "nodejs", label: "Node", version: v, source: path))
        }
        let dependencies = (package.devDependencies ?? [:]).merging(package.dependencies ?? [:]) { _, prod in prod }
        for framework in packageFrameworks {
            if let spec = dependencies[framework.dependency], let v = version(from: spec) {
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
        for line in content.split(whereSeparator: \.isNewline) {
            let words = line.split(separator: " ").filter { !$0.hasPrefix("--") }
            guard words.count >= 2, words[0].uppercased() == "FROM" else { continue }
            let reference = words[1]
            guard !reference.contains("$"), let colon = reference.lastIndex(of: ":") else { continue }
            let image = String(reference[..<colon])
            let tag = String(reference[reference.index(after: colon)...])
            let shortName = image.hasPrefix("mcr.microsoft.com/dotnet/") ? "dotnet" : String(image.split(separator: "/").last ?? "")
            let product = shortName == "dotnet" ? "dotnet" : dockerImages[shortName]
            guard let product, let v = version(from: tag) else { continue }
            result.append(DetectedVersion(product: product, label: "Docker \(shortName)", version: v, source: path))
        }
        return result
    }
}
